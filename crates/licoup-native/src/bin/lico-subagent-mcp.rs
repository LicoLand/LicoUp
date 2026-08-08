use licoup_native::{
    domain::{
        agent_intelligence_catalog::AgentIntelligenceCatalog,
        agent_workflow_loop::{AgentTarget, MainResume, WorkflowRole, subordinate_role_prompt},
        conversations, provider_model_pricing,
        subagent_handoff::{self, HandoffRecord, HandoffState, SessionMode},
        targets,
    },
    ffi::generated::client_state::{ClientStateCollection, ClientStateGetRequest},
    platform::{agent_workflow_runtime, client_state, dispatch_lane_operation, paths},
};
use serde_json::{Map, Value, json};
use std::{
    collections::{HashMap, HashSet},
    io::{self, BufRead, Write},
    process::ExitCode,
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender, TrySendError},
    },
    thread,
    time::{Duration, Instant},
};

const MCP_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "lico-up-subagents";
const SERVER_VERSION: &str = "0.10.0";
const MAX_MCP_FRAME_BYTES: usize = 64 * 1024;
const MAX_PENDING_TOOL_CALLS: usize = 32;
const MAX_TOOL_WORKERS: usize = 8;
const MAX_PROMPT_BYTES: usize = 48 * 1024;
const MAX_ID_BYTES: usize = 256;
const MAX_CONVERSATION_PATH_BYTES: usize = 4096;
const MAX_WORKING_DIRECTORY_BYTES: usize = 4096;
const MAX_FALLBACK_CANDIDATES: usize = 8;
const MIN_SUBAGENT_TIMEOUT_MS: u64 = 1_000;
const MAX_SUBAGENT_TIMEOUT_MS: u64 = 30 * 60 * 1_000;
const MIN_SUBAGENT_STDOUT_BYTES: u64 = 64 * 1024;
const MAX_SUBAGENT_STDOUT_BYTES: u64 = 64 * 1024 * 1024;
const MIN_SUBAGENT_STDERR_BYTES: u64 = 16 * 1024;
const MAX_SUBAGENT_STDERR_BYTES: u64 = 4 * 1024 * 1024;
const MAX_QUOTA_COOLDOWNS: usize = 64;
const QUOTA_COOLDOWN: Duration = Duration::from_secs(15 * 60);
const CONVERSATION_PATH_POLL_ATTEMPTS: usize = 100;
const DIAGNOSTIC_PROBE_PROMPT_PREFIX: &str = "LicoUp diagnostic probe";
const DIAGNOSTIC_PROBE_RESPONSE: &str = "READY";
const DIAGNOSTIC_PROBE_SESSION_LIMIT: u64 = 500;

static QUOTA_COOLDOWNS: LazyLock<Mutex<HashMap<String, Instant>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Clone, Debug, Eq, PartialEq)]
struct DispatchCandidate {
    agent_id: String,
    model: Option<String>,
    reasoning_effort: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CodeEngineeringLane {
    Backend,
    Frontend,
}

impl CodeEngineeringLane {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "backend" => Some(Self::Backend),
            "frontend" => Some(Self::Frontend),
            _ => None,
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Backend => "backend",
            Self::Frontend => "frontend",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ConfiguredCodeEngineeringRole {
    role: WorkflowRole,
    lane: Option<CodeEngineeringLane>,
    candidate: DispatchCandidate,
}

#[derive(Clone, Debug, PartialEq)]
struct ProbeSelection {
    runtime_model: String,
    reasoning_effort: Option<String>,
    routing_cost: Option<f64>,
    cost_unit: Option<String>,
    included: bool,
    pricing_provider: Option<String>,
    selection_mode: &'static str,
}

fn main() -> ExitCode {
    let _ = provider_model_pricing::refresh_official_sources();
    if targets::scan_targets().is_err() {
        return ExitCode::FAILURE;
    }
    let shared = Arc::new(ServerState::new());
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    loop {
        match read_line_bounded(&mut reader) {
            InputFrame::Eof => break,
            InputFrame::Oversized(prefix) => {
                write_json(&shared.output, rpc_error(extract_id(&prefix), -32600));
            }
            InputFrame::Line(line) => process_line(&shared, &line),
        }
    }
    shared.shutdown();
    ExitCode::SUCCESS
}

struct ServerState {
    initialized: AtomicBool,
    manager_agent_id: Arc<Mutex<String>>,
    output: Arc<Mutex<io::Stdout>>,
    cancellations: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
    jobs: Mutex<Option<SyncSender<ToolJob>>>,
    workers: Mutex<Vec<thread::JoinHandle<()>>>,
}

impl ServerState {
    fn new() -> Self {
        let output = Arc::new(Mutex::new(io::stdout()));
        let cancellations = Arc::new(Mutex::new(HashMap::new()));
        let manager_agent_id = Arc::new(Mutex::new(
            std::env::var("LICOUP_MAIN_AGENT_ID")
                .ok()
                .and_then(|value| canonical_agent_id(&value).map(str::to_owned))
                .unwrap_or_default(),
        ));
        let (sender, receiver) = mpsc::sync_channel::<ToolJob>(MAX_PENDING_TOOL_CALLS);
        let receiver = Arc::new(Mutex::new(receiver));
        let mut workers = Vec::with_capacity(MAX_TOOL_WORKERS);
        for _ in 0..MAX_TOOL_WORKERS {
            let receiver = Arc::clone(&receiver);
            let output = Arc::clone(&output);
            let cancellations = Arc::clone(&cancellations);
            let manager_agent_id = Arc::clone(&manager_agent_id);
            workers.push(thread::spawn(move || {
                loop {
                    let Ok(job) = receiver
                        .lock()
                        .unwrap_or_else(|error| error.into_inner())
                        .recv()
                    else {
                        break;
                    };
                    let response = if job.cancelled.load(Ordering::Acquire) {
                        rpc_error(job.id.clone(), -32800)
                    } else {
                        let manager = manager_agent_id
                            .lock()
                            .unwrap_or_else(|error| error.into_inner())
                            .clone();
                        execute_tool(
                            job.id.clone(),
                            &manager,
                            &job.name,
                            &job.arguments,
                            Arc::clone(&job.cancelled),
                        )
                    };
                    cancellations
                        .lock()
                        .unwrap_or_else(|error| error.into_inner())
                        .remove(&job.key);
                    write_json(&output, response);
                }
            }));
        }
        Self {
            initialized: AtomicBool::new(false),
            manager_agent_id,
            output,
            cancellations,
            jobs: Mutex::new(Some(sender)),
            workers: Mutex::new(workers),
        }
    }

    fn shutdown(&self) {
        self.jobs
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take();
        for worker in std::mem::take(
            &mut *self
                .workers
                .lock()
                .unwrap_or_else(|error| error.into_inner()),
        ) {
            let _ = worker.join();
        }
    }
}

struct ToolJob {
    id: Value,
    name: String,
    arguments: Value,
    key: String,
    cancelled: Arc<AtomicBool>,
}

enum InputFrame {
    Eof,
    Line(Vec<u8>),
    Oversized(Vec<u8>),
}

fn read_line_bounded(reader: &mut impl BufRead) -> InputFrame {
    let mut bytes = Vec::with_capacity(1024);
    let mut oversized = false;
    loop {
        let available = match reader.fill_buf() {
            Ok(value) => value,
            Err(_) => return InputFrame::Eof,
        };
        if available.is_empty() {
            if bytes.is_empty() && !oversized {
                return InputFrame::Eof;
            }
            return if oversized {
                InputFrame::Oversized(bytes)
            } else {
                InputFrame::Line(bytes)
            };
        }
        let consumed = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        let slice = &available[..consumed];
        if !oversized {
            let remaining = MAX_MCP_FRAME_BYTES
                .saturating_add(1)
                .saturating_sub(bytes.len());
            bytes.extend_from_slice(&slice[..slice.len().min(remaining)]);
            oversized = bytes.len() > MAX_MCP_FRAME_BYTES || slice.len() > remaining;
        }
        let reached_newline = slice.last() == Some(&b'\n');
        reader.consume(consumed);
        if reached_newline {
            if bytes.last() == Some(&b'\n') {
                bytes.pop();
            }
            return if oversized {
                InputFrame::Oversized(bytes)
            } else {
                InputFrame::Line(bytes)
            };
        }
    }
}

fn process_line(shared: &Arc<ServerState>, line: &[u8]) {
    let value: Value = match serde_json::from_slice(line) {
        Ok(value) => value,
        Err(_) => {
            write_json(&shared.output, rpc_error(Value::Null, -32700));
            return;
        }
    };
    let Some(object) = value.as_object() else {
        write_json(&shared.output, rpc_error(Value::Null, -32600));
        return;
    };
    let id = object.get("id").cloned();
    let method = object.get("method").and_then(Value::as_str);
    if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") || method.is_none() {
        write_json(&shared.output, rpc_error(id.unwrap_or(Value::Null), -32600));
        return;
    }
    let method = method.unwrap_or_default();
    if id.is_none() {
        process_notification(shared, method, object.get("params"));
        return;
    }
    let id = id.unwrap_or(Value::Null);
    match method {
        "initialize" => initialize(shared, id, object.get("params")),
        "ping" => write_json(&shared.output, rpc_success(id, json!({}))),
        "tools/list" => {
            if !shared.initialized.load(Ordering::Acquire) {
                write_json(&shared.output, rpc_error(id, -32002));
            } else if !empty_object(object.get("params")) {
                write_json(&shared.output, rpc_error(id, -32602));
            } else {
                write_json(
                    &shared.output,
                    rpc_success(id, json!({"tools": tool_catalog()})),
                );
            }
        }
        "tools/call" => start_tool_call(shared, id, object.get("params")),
        _ => write_json(&shared.output, rpc_error(id, -32601)),
    }
}

fn initialize(shared: &ServerState, id: Value, params: Option<&Value>) {
    let Some(object) = params.and_then(Value::as_object) else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    let Some(negotiated_version) = object
        .get("protocolVersion")
        .and_then(Value::as_str)
        .filter(|version| supported_protocol_version(version))
    else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    if !object.get("capabilities").is_some_and(Value::is_object)
        || !object.get("clientInfo").is_some_and(Value::is_object)
    {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    }
    if shared
        .manager_agent_id
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .is_empty()
        && let Some(client_name) = object
            .get("clientInfo")
            .and_then(|value| value.get("name"))
            .and_then(Value::as_str)
        && let Some(agent_id) = canonical_agent_id(client_name)
    {
        *shared
            .manager_agent_id
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = agent_id.to_owned();
    }
    shared.initialized.store(true, Ordering::Release);
    write_json(
        &shared.output,
        rpc_success(
            id,
            json!({
                "protocolVersion": negotiated_version,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}
            }),
        ),
    );
}

fn process_notification(shared: &ServerState, method: &str, params: Option<&Value>) {
    if method != "notifications/cancelled" {
        return;
    }
    let Some(request_id) = params
        .and_then(Value::as_object)
        .and_then(|object| object.get("requestId"))
    else {
        return;
    };
    if let Some(cancelled) = shared
        .cancellations
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .get(&id_key(request_id))
    {
        cancelled.store(true, Ordering::Release);
    }
}

fn start_tool_call(shared: &Arc<ServerState>, id: Value, params: Option<&Value>) {
    if !shared.initialized.load(Ordering::Acquire) {
        write_json(&shared.output, rpc_error(id, -32002));
        return;
    }
    let Some((name, arguments)) = parse_tool_call(params) else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    if !tool_names().contains(&name.as_str()) {
        write_json(&shared.output, rpc_error(id, -32601));
        return;
    }
    if !validate_tool_arguments(&name, &arguments) {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    }
    let key = id_key(&id);
    let cancelled = Arc::new(AtomicBool::new(false));
    shared
        .cancellations
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .insert(key.clone(), Arc::clone(&cancelled));
    let job = ToolJob {
        id: id.clone(),
        name,
        arguments,
        key: key.clone(),
        cancelled,
    };
    let jobs = shared
        .jobs
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let send_result = match jobs.as_ref() {
        Some(sender) => sender.try_send(job),
        None => Err(TrySendError::Disconnected(job)),
    };
    drop(jobs);
    if let Err(error) = send_result {
        let job = match error {
            TrySendError::Full(job) | TrySendError::Disconnected(job) => job,
        };
        shared
            .cancellations
            .lock()
            .unwrap_or_else(|state_error| state_error.into_inner())
            .remove(&job.key);
        write_json(
            &shared.output,
            rpc_success(job.id, tool_error(&ToolFailure::new("server_busy", true))),
        );
    }
}

fn execute_tool(
    id: Value,
    manager_agent_id: &str,
    name: &str,
    arguments: &Value,
    cancelled: Arc<AtomicBool>,
) -> Value {
    let result = match name {
        "lico_subagents_list" => list_subagents(manager_agent_id),
        "lico_subagent_probe" => probe_subagent(manager_agent_id, arguments),
        "lico_subagent_delegate" => dispatch_subagent(manager_agent_id, arguments, false),
        "lico_subagent_continue" => dispatch_subagent(manager_agent_id, arguments, true),
        "lico_subagent_cancel" => cancel_subagent(manager_agent_id, arguments),
        _ => Err(ToolFailure::new("invalid_request", false)),
    };
    if cancelled.load(Ordering::Acquire) {
        return rpc_error(id, -32800);
    }
    match result {
        Ok(value) => rpc_success(id, tool_success(value)),
        Err(error) => rpc_success(id, tool_error(&error)),
    }
}

fn probe_subagent(manager_agent_id: &str, arguments: &Value) -> Result<Value, ToolFailure> {
    ensure_manager_bound(manager_agent_id)?;
    let agent_id = required_text(arguments, "agentId", MAX_ID_BYTES)?;
    let working_directory = optional_working_directory(arguments)?
        .ok_or(ToolFailure::new("invalid_working_directory", false))?;
    let exact_model = optional_text(arguments, "exactModel", MAX_ID_BYTES)?;
    let exact_effort = optional_text(arguments, "exactReasoningEffort", 32)?;
    if exact_effort.is_some() && exact_model.is_none() {
        return Err(ToolFailure::new("invalid_request", false));
    }
    let inspected = targets::inspect_target(&agent_id)
        .map_err(|_| ToolFailure::new("subagent_unavailable", false))?;
    let target = inspected
        .get("target")
        .ok_or(ToolFailure::new("subagent_unavailable", false))?;
    if !subordinate_is_available(target) {
        return Err(ToolFailure::new("subagent_unavailable", false));
    }
    let selection = select_probe_model(
        target,
        &agent_id,
        exact_model.as_deref(),
        exact_effort.as_deref(),
    )?;
    let timeout_ms = optional_timeout_ms(arguments)?.unwrap_or(120_000);
    let before = if probe_has_native_cleanup(&agent_id) {
        HashSet::new()
    } else {
        probe_conversation_paths(&agent_id)?
    };
    let canary = format!("{DIAGNOSTIC_PROBE_PROMPT_PREFIX} {}", uuid::Uuid::new_v4());
    let prompt = format!("{canary}. Reply with exactly {DIAGNOSTIC_PROBE_RESPONSE}.");
    let mut params = json!({
        "agentId": agent_id,
        "text": prompt,
        "model": selection.runtime_model,
        "workingDirectory": working_directory,
        "streamEvents": false,
        "timeoutMs": timeout_ms,
    });
    if let Some(reasoning_effort) = &selection.reasoning_effort {
        params["reasoningEffort"] = json!(reasoning_effort);
    }
    let execution = dispatch_lane_operation("send", &params);
    let session_id = execution
        .as_ref()
        .ok()
        .and_then(|value| {
            value
                .get("nativeSessionId")
                .or_else(|| value.get("sessionId"))
        })
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let successful_execution = execution
        .as_ref()
        .ok()
        .and_then(|value| value.get("ok"))
        .and_then(Value::as_bool)
        == Some(true);
    let native_cleanup_state = session_id
        .as_deref()
        .map(|session_id| cleanup_probe_native_session(&agent_id, session_id))
        .transpose()?
        .flatten();
    let cleanup_state = if let Some(native_cleanup_state) = native_cleanup_state {
        native_cleanup_state
    } else {
        cleanup_probe_conversations(
            &agent_id,
            &before,
            &canary,
            session_id.as_deref(),
            (session_id.is_some() || successful_execution)
                && !probe_history_may_be_ephemeral(&agent_id),
            false,
        )?
    };
    let execution =
        execution.map_err(|_| ToolFailure::new("diagnostic_probe_transport_failed", true))?;
    if execution.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(ToolFailure::new("diagnostic_probe_execution_failed", false));
    }
    if !probe_response_is_ready(&execution) {
        return Err(ToolFailure::new("diagnostic_probe_response_invalid", false));
    }
    Ok(json!({
        "schemaVersion": "licoup.subagent.probe-receipt.v1",
        "operation": "subagent.probe",
        "agentId": agent_id,
        "state": "ready",
        "model": selection.runtime_model,
        "reasoningEffort": selection.reasoning_effort,
        "selectionMode": selection.selection_mode,
        "estimatedProbeCost": selection.routing_cost,
        "costUnit": selection.cost_unit,
        "includedByHarness": selection.included,
        "pricingProvider": selection.pricing_provider,
        "cleanupState": cleanup_state
    }))
}

fn probe_response_is_ready(execution: &Value) -> bool {
    execution
        .get("output")
        .and_then(Value::as_str)
        .is_some_and(|output| !output.trim().is_empty())
}

fn select_probe_model(
    target: &Value,
    agent_id: &str,
    exact_model: Option<&str>,
    exact_effort: Option<&str>,
) -> Result<ProbeSelection, ToolFailure> {
    let models = target
        .pointer("/modelCatalog/models")
        .and_then(Value::as_array)
        .ok_or(ToolFailure::new(
            "diagnostic_probe_model_catalog_unavailable",
            false,
        ))?;
    if let Some(exact_model) = exact_model {
        let model = models
            .iter()
            .find(|model| model.get("name").and_then(Value::as_str) == Some(exact_model))
            .ok_or(ToolFailure::new(
                "diagnostic_probe_exact_model_unavailable",
                false,
            ))?;
        if let Some(exact_effort) = exact_effort
            && !model
                .get("reasoningEfforts")
                .and_then(Value::as_array)
                .is_some_and(|efforts| {
                    efforts
                        .iter()
                        .any(|effort| effort.as_str() == Some(exact_effort))
                })
        {
            return Err(ToolFailure::new(
                "diagnostic_probe_exact_effort_unavailable",
                false,
            ));
        }
        let quote = probe_model_quote(agent_id, exact_model, exact_effort);
        return Ok(ProbeSelection {
            runtime_model: exact_model.to_owned(),
            reasoning_effort: exact_effort.map(str::to_owned),
            routing_cost: quote.as_ref().map(|quote| quote.amount),
            cost_unit: quote.as_ref().map(|quote| quote.unit.clone()),
            included: quote.as_ref().is_some_and(|quote| quote.included),
            pricing_provider: quote.map(|quote| quote.provider),
            selection_mode: "exact-model",
        });
    }
    let mut candidates = Vec::new();
    for model in models {
        let Some(runtime_model) = model.get("name").and_then(Value::as_str) else {
            continue;
        };
        let mut efforts = vec![None];
        efforts.extend(
            model
                .get("reasoningEfforts")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(Some),
        );
        for effort in efforts {
            let Some(quote) = probe_model_quote(agent_id, runtime_model, effort) else {
                continue;
            };
            candidates.push(ProbeSelection {
                runtime_model: runtime_model.to_owned(),
                reasoning_effort: effort.map(str::to_owned),
                routing_cost: Some(quote.amount),
                cost_unit: Some(quote.unit),
                included: quote.included,
                pricing_provider: Some(quote.provider),
                selection_mode: "lowest-measured-cost",
            });
        }
    }
    candidates.sort_by(|left, right| {
        left.routing_cost
            .unwrap_or(f64::INFINITY)
            .total_cmp(&right.routing_cost.unwrap_or(f64::INFINITY))
            .then_with(|| left.runtime_model.cmp(&right.runtime_model))
    });
    candidates.into_iter().next().ok_or(ToolFailure::new(
        "diagnostic_probe_price_unavailable",
        false,
    ))
}

struct ModelCostQuote {
    amount: f64,
    unit: String,
    included: bool,
    provider: String,
}

fn probe_model_quote(
    agent_id: &str,
    runtime_model: &str,
    effort: Option<&str>,
) -> Option<ModelCostQuote> {
    let price_keys = probe_price_keys(agent_id, runtime_model, effort);
    if let Some(quote) = provider_model_pricing::quote_probe(agent_id, &price_keys) {
        return Some(ModelCostQuote {
            amount: quote.amount,
            unit: quote.unit,
            included: quote.included,
            provider: quote.provider,
        });
    }
    let catalog = AgentIntelligenceCatalog::embedded().ok()?;
    let harness = probe_harness_id(agent_id);
    if let Some(cost) = price_keys.iter().find_map(|key| {
        catalog
            .coding_variants()
            .iter()
            .find(|variant| {
                variant.harness == harness
                    && variant.model == *key
                    && (effort.is_none()
                        || variant.reasoning_effort == effort.unwrap_or_default()
                        || variant.reasoning_effort == "none")
            })
            .map(|variant| variant.cost_per_task_usd)
    }) {
        return Some(ModelCostQuote {
            amount: cost,
            unit: "usd_per_benchmark_task".into(),
            included: false,
            provider: "artificial-analysis".into(),
        });
    }
    price_keys.into_iter().find_map(|key| {
        catalog
            .intelligence_models()
            .iter()
            .find(|model| model.model_id == key)
            .and_then(|model| model.cost_per_task_usd)
            .map(|amount| ModelCostQuote {
                amount,
                unit: "usd_per_benchmark_task".into(),
                included: false,
                provider: "artificial-analysis".into(),
            })
    })
}

fn probe_harness_id(agent_id: &str) -> &str {
    match agent_id {
        "cursor" => "cursor-cli",
        "kimi-code" => "kimi-code-cli",
        "antigravity" => "gemini-cli",
        value => value,
    }
}

fn probe_price_keys(agent_id: &str, runtime_model: &str, effort: Option<&str>) -> Vec<String> {
    let mut normalized = runtime_model.trim().to_ascii_lowercase();
    if agent_id == "kilo-code"
        && (normalized == "kilo-auto/free"
            || normalized.ends_with("/kilo-auto/free")
            || normalized.ends_with(":free"))
    {
        return vec!["free".into()];
    }
    if let Some((_, suffix)) = normalized.rsplit_once('/') {
        normalized = suffix.to_owned();
    }
    normalized = normalized
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '-'
            }
        })
        .collect::<String>();
    while normalized.contains("--") {
        normalized = normalized.replace("--", "-");
    }
    normalized = normalized.trim_matches('-').to_owned();
    if agent_id == "kimi-code" {
        return vec![match normalized.as_str() {
            "kimi-for-coding" | "kimi-for-coding-highspeed" => "kimi-k2-7-code".into(),
            "k3" | "k3-256k" if effort == Some("low") => "kimi-k3-low".into(),
            "k3" | "k3-256k" => "kimi-k3".into(),
            value if value.starts_with("kimi-") => value.into(),
            value => format!("kimi-{value}"),
        }];
    }
    let display_base = ["-xhigh", "-max", "-high", "-medium", "-low"]
        .into_iter()
        .find_map(|suffix| normalized.strip_suffix(suffix))
        .unwrap_or(&normalized)
        .to_owned();
    let suffix = effort.map(|value| match value {
        "max" => "xhigh",
        value => value,
    });
    let mut keys = Vec::new();
    if let Some(suffix) = suffix {
        keys.push(format!("{display_base}-{suffix}"));
    }
    keys.push(normalized);
    keys.push(display_base);
    let mut unique = HashSet::new();
    keys.retain(|key| unique.insert(key.clone()));
    keys
}

fn probe_conversation_paths(agent_id: &str) -> Result<HashSet<String>, ToolFailure> {
    let response = conversations::conversation_list(&json!({
        "agent": agent_id,
        "limit": DIAGNOSTIC_PROBE_SESSION_LIMIT
    }))
    .map_err(|_| ToolFailure::new("diagnostic_probe_history_unavailable", true))?;
    Ok(response
        .get("sessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|session| session.get("sourcePath").and_then(Value::as_str))
        .map(str::to_owned)
        .collect())
}

fn cleanup_probe_conversations(
    agent_id: &str,
    before: &HashSet<String>,
    canary: &str,
    session_id: Option<&str>,
    require_persisted_history: bool,
    native_cleanup_verified: bool,
) -> Result<&'static str, ToolFailure> {
    let mut targets = Vec::new();
    let mut canary_seen = false;
    let poll_attempts = if native_cleanup_verified {
        1
    } else {
        CONVERSATION_PATH_POLL_ATTEMPTS
    };
    for attempt in 0..poll_attempts {
        let mut query = json!({
            "agent": agent_id,
            "limit": DIAGNOSTIC_PROBE_SESSION_LIMIT
        });
        if let Some(session_id) = session_id {
            query["sessionId"] = json!(session_id);
        }
        let response = conversations::conversation_list(&query)
            .map_err(|_| ToolFailure::new("diagnostic_probe_cleanup_failed", false))?;
        canary_seen |= response.to_string().contains(canary);
        for session in response
            .get("sessions")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let Some(source_path) = session.get("sourcePath").and_then(Value::as_str) else {
                continue;
            };
            let matches_id = session_id.is_some_and(|expected| {
                session
                    .get("nativeSessionId")
                    .or_else(|| session.get("sessionId"))
                    .and_then(Value::as_str)
                    == Some(expected)
            });
            if !before.contains(source_path) && (matches_id || session.to_string().contains(canary))
            {
                targets.push(probe_cleanup_target(agent_id, source_path)?);
            }
        }
        if !targets.is_empty() {
            break;
        }
        if attempt + 1 < poll_attempts {
            thread::sleep(Duration::from_millis(50));
        }
    }
    targets.sort();
    targets.dedup();
    if targets.is_empty() {
        if native_cleanup_verified {
            return if canary_seen {
                Err(ToolFailure::new(
                    "diagnostic_probe_cleanup_unverified",
                    false,
                ))
            } else {
                Ok("not-persisted-and-verified")
            };
        }
        return if require_persisted_history {
            Err(ToolFailure::new(
                "diagnostic_probe_cleanup_unverified",
                false,
            ))
        } else {
            let remaining = conversations::conversation_list(&json!({
                "agent": agent_id,
                "limit": DIAGNOSTIC_PROBE_SESSION_LIMIT
            }))
            .map_err(|_| ToolFailure::new("diagnostic_probe_cleanup_unverified", false))?;
            if remaining.to_string().contains(canary) {
                Err(ToolFailure::new(
                    "diagnostic_probe_cleanup_unverified",
                    false,
                ))
            } else {
                Ok("not-persisted-and-verified")
            }
        };
    }
    for target in &targets {
        trash::delete(target)
            .map_err(|_| ToolFailure::new("diagnostic_probe_cleanup_failed", false))?;
    }
    if targets.iter().any(|target| target.exists()) {
        return Err(ToolFailure::new(
            "diagnostic_probe_cleanup_unverified",
            false,
        ));
    }
    let remaining = conversations::conversation_list(&json!({
        "agent": agent_id,
        "limit": DIAGNOSTIC_PROBE_SESSION_LIMIT
    }))
    .map_err(|_| ToolFailure::new("diagnostic_probe_cleanup_unverified", false))?;
    if remaining.to_string().contains(canary) {
        return Err(ToolFailure::new(
            "diagnostic_probe_cleanup_unverified",
            false,
        ));
    }
    Ok("moved-to-trash-and-verified")
}

fn probe_has_native_cleanup(agent_id: &str) -> bool {
    matches!(agent_id, "cursor" | "antigravity")
}

fn probe_history_may_be_ephemeral(agent_id: &str) -> bool {
    matches!(agent_id, "claude-code" | "cursor" | "antigravity")
}

fn cleanup_probe_native_session(
    agent_id: &str,
    session_id: &str,
) -> Result<Option<&'static str>, ToolFailure> {
    match agent_id {
        "cursor" | "antigravity" => {}
        _ => return Ok(None),
    }
    let response = dispatch_lane_operation(
        "cleanup",
        &json!({"agentId": agent_id, "sessionId": session_id}),
    )
    .map_err(|_| ToolFailure::new("diagnostic_probe_cleanup_failed", false))?;
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(ToolFailure::new("diagnostic_probe_cleanup_failed", false));
    }
    match response.get("status").and_then(Value::as_str) {
        Some("cleaned") => Ok(Some("moved-to-trash-and-verified")),
        Some("not_persisted") => Ok(Some("not-persisted-and-verified")),
        _ => Err(ToolFailure::new("diagnostic_probe_cleanup_failed", false)),
    }
}

fn probe_cleanup_target(
    agent_id: &str,
    source_path: &str,
) -> Result<std::path::PathBuf, ToolFailure> {
    let path = std::fs::canonicalize(source_path)
        .map_err(|_| ToolFailure::new("diagnostic_probe_cleanup_target_invalid", false))?;
    if agent_id == "kimi-code" {
        let root = path
            .parent()
            .and_then(std::path::Path::parent)
            .and_then(std::path::Path::parent)
            .ok_or(ToolFailure::new(
                "diagnostic_probe_cleanup_target_invalid",
                false,
            ))?;
        if path.file_name().and_then(|value| value.to_str()) != Some("wire.jsonl")
            || root
                .file_name()
                .and_then(|value| value.to_str())
                .is_none_or(|name| !name.starts_with("session_"))
            || !root.join("state.json").is_file()
        {
            return Err(ToolFailure::new(
                "diagnostic_probe_cleanup_target_invalid",
                false,
            ));
        }
        return Ok(root.to_path_buf());
    }
    if path.is_file()
        && matches!(
            path.extension().and_then(|value| value.to_str()),
            Some("json" | "jsonl")
        )
    {
        return Ok(path);
    }
    Err(ToolFailure::new(
        "diagnostic_probe_cleanup_unsupported",
        false,
    ))
}

#[derive(Clone, Debug)]
struct ToolFailure {
    code: &'static str,
    retryable: bool,
    conversation_path: Option<String>,
}

impl ToolFailure {
    const fn new(code: &'static str, retryable: bool) -> Self {
        Self {
            code,
            retryable,
            conversation_path: None,
        }
    }

    fn with_conversation_path(mut self, conversation_path: Option<String>) -> Self {
        self.conversation_path = conversation_path;
        self
    }
}

fn list_subagents(manager_agent_id: &str) -> Result<Value, ToolFailure> {
    ensure_manager_bound(manager_agent_id)?;
    let scan = targets::scan_targets().map_err(|_| ToolFailure::new("scan_failed", true))?;
    let candidates = scan
        .get("candidates")
        .and_then(Value::as_array)
        .ok_or(ToolFailure::new("scan_failed", true))?;
    let subagents = candidates
        .iter()
        .filter(|candidate| subordinate_is_available(candidate))
        .map(|candidate| project_subagent(candidate, manager_agent_id))
        .collect::<Vec<_>>();
    let strategy = configured_code_engineering_strategy()
        .map(project_code_engineering_strategy)
        .unwrap_or_else(unconfigured_code_engineering_strategy);
    Ok(json!({
        "schemaVersion": "licoup.subagents.v1",
        "managerAgentId": manager_agent_id,
        "subagents": subagents,
        "count": subagents.len(),
        "codeEngineeringStrategy": strategy
    }))
}

fn dispatch_subagent(
    manager_agent_id: &str,
    arguments: &Value,
    continuing: bool,
) -> Result<Value, ToolFailure> {
    ensure_manager_bound(manager_agent_id)?;
    let prompt = required_text(arguments, "prompt", MAX_PROMPT_BYTES)?;
    let role = required_workflow_role(arguments)?;
    let lane = optional_workflow_lane(arguments, role)?;
    let prompt = subordinate_role_prompt(role, &prompt);
    let mut candidates = dispatch_candidates(arguments, continuing)?;
    if !continuing && let Some(configured) = configured_code_engineering_assignment(role, lane) {
        candidates.retain(|candidate| candidate != &configured);
        candidates.insert(0, configured);
    }
    let mut working_directory = optional_working_directory(arguments)?;
    let timeout_ms = optional_timeout_ms(arguments)?;
    let max_stdout_bytes = optional_bounded_u64(
        arguments,
        "maxStdoutBytes",
        MIN_SUBAGENT_STDOUT_BYTES,
        MAX_SUBAGENT_STDOUT_BYTES,
    )?;
    let max_stderr_bytes = optional_bounded_u64(
        arguments,
        "maxStderrBytes",
        MIN_SUBAGENT_STDERR_BYTES,
        MAX_SUBAGENT_STDERR_BYTES,
    )?;
    let allow_all = optional_bool(arguments, "allowAll")?;
    let permission_mode = optional_permission_mode(arguments)?;
    let session_mode = resolve_session_mode(arguments, continuing)?;
    let mut continuation = None;
    if session_mode == SessionMode::Resume {
        let conversation_path =
            required_text(arguments, "conversationPath", MAX_CONVERSATION_PATH_BYTES)?;
        let resume_target = resume_target_for_path(&candidates[0].agent_id, &conversation_path)?;
        working_directory = Some(continuation_working_directory(
            working_directory,
            resume_target.working_directory.as_deref(),
        )?);
        continuation = Some((resume_target.session_id, conversation_path));
    } else if arguments
        .get("conversationPath")
        .and_then(Value::as_str)
        .is_some_and(|value| !value.trim().is_empty())
    {
        // New sessions must not carry a resume handle.
        return Err(ToolFailure::new("invalid_request", false));
    }
    // Validate at least the first candidate before ACK so invalid requests fail closed.
    let first = candidates
        .first()
        .ok_or(ToolFailure::new("invalid_request", false))?;
    let inspected = ensure_subordinate_available(&first.agent_id)?;
    validate_dispatch_selection(first, &inspected)?;

    let operation = if session_mode == SessionMode::Resume {
        "subagent.continue"
    } else {
        "subagent.delegate"
    };
    let main_conversation_path = optional_text(
        arguments,
        "mainConversationPath",
        MAX_CONVERSATION_PATH_BYTES,
    )?
    .or_else(|| resolve_manager_conversation_path(manager_agent_id));
    let portable = paths::portable_data_dir()
        .map_err(|_| ToolFailure::new("handoff_store_unavailable", true))?;
    let dispatch_id = subagent_handoff::new_dispatch_id();
    let record = HandoffRecord::new(
        dispatch_id.clone(),
        operation,
        manager_agent_id,
        first.agent_id.clone(),
        session_mode,
        main_conversation_path.clone(),
    );
    subagent_handoff::persist_handoff(&portable, &record)
        .map_err(|_| ToolFailure::new("handoff_store_unavailable", true))?;

    let manager_agent_id = manager_agent_id.to_owned();
    let portable_for_worker = portable.clone();
    thread::spawn(move || {
        run_accepted_handoff(
            portable_for_worker,
            dispatch_id,
            manager_agent_id,
            operation.to_owned(),
            candidates,
            prompt,
            working_directory,
            timeout_ms,
            max_stdout_bytes,
            max_stderr_bytes,
            allow_all,
            permission_mode,
            continuation,
            main_conversation_path,
        );
    });

    Ok(record.ack_receipt())
}

fn run_accepted_handoff(
    portable: std::path::PathBuf,
    dispatch_id: String,
    manager_agent_id: String,
    operation: String,
    candidates: Vec<DispatchCandidate>,
    prompt: String,
    working_directory: Option<String>,
    timeout_ms: Option<u64>,
    max_stdout_bytes: Option<u64>,
    max_stderr_bytes: Option<u64>,
    allow_all: Option<bool>,
    permission_mode: Option<String>,
    continuation: Option<(String, String)>,
    main_conversation_path: Option<String>,
) {
    let mut record = match subagent_handoff::load_handoff(&portable, &dispatch_id) {
        Ok(record) => record,
        Err(_) => return,
    };
    record.state = HandoffState::Running;
    record.updated_at_unix_ms = subagent_handoff::unix_ms_now();
    let _ = subagent_handoff::persist_handoff(&portable, &record);

    match execute_subagent_send(
        &candidates,
        &prompt,
        working_directory.as_deref(),
        timeout_ms,
        max_stdout_bytes,
        max_stderr_bytes,
        allow_all,
        permission_mode.as_deref(),
        continuation.as_ref(),
    ) {
        Ok((agent_id, conversation_path)) => {
            record.agent_id = agent_id.clone();
            record.conversation_path = Some(conversation_path.clone());
            record.state = HandoffState::Completed;
            record.error_code = None;
            record.updated_at_unix_ms = subagent_handoff::unix_ms_now();
            let _ = subagent_handoff::persist_handoff(&portable, &record);
            if let Some(main_path) = main_conversation_path
                .as_deref()
                .filter(|path| !path.is_empty())
            {
                let resume = MainResume {
                    workflow_id: dispatch_id.clone(),
                    target: AgentTarget {
                        adapter_id: manager_agent_id,
                        display_name: record.manager_agent_id.clone(),
                        model: None,
                        reasoning_effort: None,
                        working_directory: None,
                    },
                    conversation_path: main_path.to_owned(),
                    prompt: format!(
                        "LicoUp handoff {dispatch_id} for subordinate `{agent_id}` finished ({operation}). Decide the next step. Do not probe the subordinate; request another handoff if more work is needed."
                    ),
                };
                let _ = agent_workflow_runtime::resume_main(&resume);
            }
        }
        Err(code) => {
            record.state = HandoffState::Failed;
            record.error_code = Some(code);
            record.updated_at_unix_ms = subagent_handoff::unix_ms_now();
            let _ = subagent_handoff::persist_handoff(&portable, &record);
            if let Some(main_path) = main_conversation_path
                .as_deref()
                .filter(|path| !path.is_empty())
            {
                let resume = MainResume {
                    workflow_id: dispatch_id.clone(),
                    target: AgentTarget {
                        adapter_id: manager_agent_id.clone(),
                        display_name: manager_agent_id,
                        model: None,
                        reasoning_effort: None,
                        working_directory: None,
                    },
                    conversation_path: main_path.to_owned(),
                    prompt: format!(
                        "LicoUp handoff {dispatch_id} failed ({operation}). Decide the next step. Do not probe the subordinate; request another handoff if retrying."
                    ),
                };
                let _ = agent_workflow_runtime::resume_main(&resume);
            }
        }
    }
}

fn execute_subagent_send(
    candidates: &[DispatchCandidate],
    prompt: &str,
    working_directory: Option<&str>,
    timeout_ms: Option<u64>,
    max_stdout_bytes: Option<u64>,
    max_stderr_bytes: Option<u64>,
    allow_all: Option<bool>,
    permission_mode: Option<&str>,
    continuation: Option<&(String, String)>,
) -> Result<(String, String), String> {
    for (index, candidate) in candidates.iter().enumerate() {
        let inspected = ensure_subordinate_available(&candidate.agent_id)
            .map_err(|failure| failure.code.to_owned())?;
        validate_dispatch_selection(candidate, &inspected)
            .map_err(|failure| failure.code.to_owned())?;
        let quota_key = quota_key(candidate);
        if quota_is_cooling_down(&quota_key) {
            if index + 1 < candidates.len() {
                continue;
            }
            return Err("subagent_quota_exhausted".to_owned());
        }
        let mut params = json!({
            "agentId": candidate.agent_id,
            "text": prompt,
            "streamEvents": false,
        });
        if let Some(model) = &candidate.model {
            params["model"] = json!(model);
        }
        if let Some(reasoning) = &candidate.reasoning_effort {
            params["reasoningEffort"] = json!(reasoning);
        }
        if let Some(working_directory) = working_directory {
            params["workingDirectory"] = json!(working_directory);
        }
        if let Some(timeout_ms) = timeout_ms {
            params["timeoutMs"] = json!(timeout_ms);
        }
        if let Some(max_stdout_bytes) = max_stdout_bytes {
            params["maxStdoutBytes"] = json!(max_stdout_bytes);
        }
        if let Some(max_stderr_bytes) = max_stderr_bytes {
            params["maxStderrBytes"] = json!(max_stderr_bytes);
        }
        if let Some(allow_all) = allow_all {
            params["allowAll"] = json!(allow_all);
        }
        if let Some(permission_mode) = permission_mode {
            params["permissionMode"] = json!(permission_mode);
        }
        if let Some((session_id, source_path)) = continuation {
            params["sessionId"] = json!(session_id);
            params["sourcePath"] = json!(source_path);
        }
        let value = dispatch_lane_operation("send", &params)
            .map_err(|_| "subagent_transport_failed".to_owned())?;
        if value.get("ok").and_then(Value::as_bool) == Some(true) {
            clear_quota_cooldown(&quota_key);
            let projected =
                project_dispatch_result("subagent.delegate", &candidate.agent_id, &value)
                    .map_err(|failure| failure.code.to_owned())?;
            let conversation_path = projected
                .get("conversationPath")
                .and_then(Value::as_str)
                .filter(|path| !path.is_empty())
                .ok_or_else(|| "conversation_location_unavailable".to_owned())?
                .to_owned();
            return Ok((candidate.agent_id.clone(), conversation_path));
        }
        if quota_or_capacity_failure(&value) {
            record_quota_cooldown(quota_key);
            if index + 1 < candidates.len() {
                continue;
            }
            return Err("subagent_quota_exhausted".to_owned());
        }
        return Err(project_dispatch_failure(&candidate.agent_id, &value)
            .code
            .to_owned());
    }
    Err("subagent_quota_exhausted".to_owned())
}

fn resolve_manager_conversation_path(manager_agent_id: &str) -> Option<String> {
    let response = conversations::conversation_list(&json!({
        "agent": manager_agent_id,
        "limit": 8
    }))
    .ok()?;
    response
        .get("sessions")
        .and_then(Value::as_array)?
        .iter()
        .find_map(|session| {
            session
                .get("sourcePath")
                .and_then(Value::as_str)
                .filter(|path| std::path::Path::new(path).is_absolute())
                .map(str::to_owned)
        })
}

fn resolve_session_mode(arguments: &Value, continuing: bool) -> Result<SessionMode, ToolFailure> {
    if continuing {
        // lico_subagent_continue is always resume.
        return Ok(SessionMode::Resume);
    }
    match optional_text(arguments, "sessionMode", 16)? {
        None => Ok(SessionMode::New),
        Some(value) => SessionMode::parse(&value).ok_or(ToolFailure::new("invalid_request", false)),
    }
}

fn dispatch_candidates(
    arguments: &Value,
    continuing: bool,
) -> Result<Vec<DispatchCandidate>, ToolFailure> {
    let mut candidates = vec![DispatchCandidate {
        agent_id: required_text(arguments, "agentId", MAX_ID_BYTES)?,
        model: optional_text(arguments, "model", MAX_ID_BYTES)?,
        reasoning_effort: optional_text(arguments, "reasoningEffort", 32)?,
    }];
    if let Some(fallbacks) = arguments.get("fallbackCandidates") {
        if continuing {
            return Err(ToolFailure::new("invalid_request", false));
        }
        let rows = fallbacks
            .as_array()
            .filter(|rows| !rows.is_empty() && rows.len() <= MAX_FALLBACK_CANDIDATES)
            .ok_or(ToolFailure::new("invalid_request", false))?;
        for row in rows {
            let object = row
                .as_object()
                .filter(|object| {
                    object
                        .keys()
                        .all(|key| matches!(key.as_str(), "agentId" | "model" | "reasoningEffort"))
                })
                .ok_or(ToolFailure::new("invalid_request", false))?;
            if object.is_empty() {
                return Err(ToolFailure::new("invalid_request", false));
            }
            candidates.push(DispatchCandidate {
                agent_id: required_text(row, "agentId", MAX_ID_BYTES)?,
                model: optional_text(row, "model", MAX_ID_BYTES)?,
                reasoning_effort: optional_text(row, "reasoningEffort", 32)?,
            });
        }
    }
    let mut unique = HashSet::with_capacity(candidates.len());
    if candidates.iter().any(|candidate| {
        !unique.insert((
            candidate.agent_id.clone(),
            candidate.model.clone().unwrap_or_default(),
        ))
    }) {
        return Err(ToolFailure::new("invalid_request", false));
    }
    Ok(candidates)
}

fn quota_key(candidate: &DispatchCandidate) -> String {
    format!(
        "{}\0{}",
        candidate.agent_id,
        candidate.model.as_deref().unwrap_or_default()
    )
}

fn quota_is_cooling_down(key: &str) -> bool {
    let now = Instant::now();
    let mut state = QUOTA_COOLDOWNS
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    state.retain(|_, until| *until > now);
    state.get(key).is_some_and(|until| *until > now)
}

fn record_quota_cooldown(key: String) {
    let now = Instant::now();
    let mut state = QUOTA_COOLDOWNS
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    state.retain(|_, until| *until > now);
    if state.len() >= MAX_QUOTA_COOLDOWNS
        && !state.contains_key(&key)
        && let Some(oldest) = state
            .iter()
            .min_by_key(|(_, until)| **until)
            .map(|(candidate, _)| candidate.clone())
    {
        state.remove(&oldest);
    }
    state.insert(key, now + QUOTA_COOLDOWN);
}

fn clear_quota_cooldown(key: &str) {
    QUOTA_COOLDOWNS
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .remove(key);
}

fn quota_or_capacity_failure(source: &Value) -> bool {
    let code = source
        .pointer("/error/code")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    [
        "quota",
        "credit",
        "rate_limit",
        "rate-limit",
        "capacity",
        "exhaust",
    ]
    .iter()
    .any(|marker| code.contains(marker))
}

fn cancel_subagent(manager_agent_id: &str, arguments: &Value) -> Result<Value, ToolFailure> {
    ensure_manager_bound(manager_agent_id)?;
    let agent_id = required_text(arguments, "agentId", MAX_ID_BYTES)?;
    let _ = ensure_subordinate_available(&agent_id)?;
    let conversation_path =
        required_text(arguments, "conversationPath", MAX_CONVERSATION_PATH_BYTES)?;
    let session_id = session_id_for_path(&agent_id, &conversation_path)?;
    let value = dispatch_lane_operation(
        "cancel",
        &json!({"agentId": agent_id, "sessionId": session_id}),
    )
    .map_err(|_| ToolFailure::new("subagent_transport_failed", true))?;
    if value.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(project_dispatch_failure(&agent_id, &value));
    }
    Ok(json!({
        "schemaVersion": "licoup.subagent.receipt.v1",
        "operation": "subagent.cancel",
        "agentId": agent_id,
        "state": value.get("status").and_then(Value::as_str).unwrap_or("cancel_requested")
    }))
}

fn ensure_manager_bound(manager_agent_id: &str) -> Result<(), ToolFailure> {
    if manager_agent_id.is_empty() {
        Err(ToolFailure::new("main_agent_unbound", false))
    } else {
        Ok(())
    }
}

fn ensure_subordinate_available(agent_id: &str) -> Result<Value, ToolFailure> {
    let inspected = targets::inspect_target(agent_id)
        .map_err(|_| ToolFailure::new("subagent_unavailable", false))?;
    let candidate = inspected
        .get("target")
        .ok_or(ToolFailure::new("subagent_unavailable", false))?;
    if subordinate_is_available(candidate) {
        Ok(candidate.clone())
    } else {
        Err(ToolFailure::new("subagent_unavailable", false))
    }
}

fn validate_dispatch_selection(
    selection: &DispatchCandidate,
    target: &Value,
) -> Result<(), ToolFailure> {
    let Some(requested_model) = selection.model.as_deref() else {
        return if selection.reasoning_effort.is_none() {
            Ok(())
        } else {
            Err(ToolFailure::new(
                "subagent_model_required_for_effort",
                false,
            ))
        };
    };
    let model = target
        .pointer("/modelCatalog/models")
        .and_then(Value::as_array)
        .and_then(|models| {
            models
                .iter()
                .find(|model| model.get("name").and_then(Value::as_str) == Some(requested_model))
        })
        .ok_or(ToolFailure::new("subagent_model_unavailable", false))?;
    if let Some(reasoning_effort) = selection.reasoning_effort.as_deref()
        && !model
            .get("reasoningEfforts")
            .and_then(Value::as_array)
            .is_some_and(|efforts| {
                efforts
                    .iter()
                    .any(|effort| effort.as_str() == Some(reasoning_effort))
            })
    {
        return Err(ToolFailure::new(
            "subagent_reasoning_effort_unavailable",
            false,
        ));
    }
    Ok(())
}

fn subordinate_is_available(candidate: &Value) -> bool {
    let Some(agent_id) = candidate.get("target").and_then(Value::as_str) else {
        return false;
    };
    agent_id != "code"
        && candidate.get("status").and_then(Value::as_str) != Some("not-detected")
        && candidate
            .get("supportedActions")
            .and_then(Value::as_array)
            .is_some_and(|actions| {
                actions
                    .iter()
                    .any(|action| action.as_str() == Some("runtime.message.send"))
            })
}

fn project_subagent(candidate: &Value, manager_agent_id: &str) -> Value {
    let matrix = candidate
        .pointer("/adapterCapabilities/conversationCapabilityMatrix")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let models = candidate
        .pointer("/modelCatalog/models")
        .and_then(Value::as_array)
        .map(|models| {
            models
                .iter()
                .filter_map(|model| {
                    let name = model.get("name").and_then(Value::as_str)?;
                    let mut projected = Map::new();
                    projected.insert("name".into(), json!(name));
                    if let Some(display_name) = model.get("displayName").and_then(Value::as_str) {
                        projected.insert("displayName".into(), json!(display_name));
                    }
                    if let Some(efforts) = model.get("reasoningEfforts").and_then(Value::as_array) {
                        projected.insert("reasoningEfforts".into(), json!(efforts));
                    }
                    Some(Value::Object(projected))
                })
                .take(128)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    json!({
        "agentId": candidate.get("target").and_then(Value::as_str).unwrap_or_default(),
        "label": candidate.get("label").and_then(Value::as_str).unwrap_or_default(),
        "sameFramework": candidate.get("target").and_then(Value::as_str) == Some(manager_agent_id),
        "capabilities": matrix,
        "models": models,
    })
}

fn project_dispatch_result(
    operation: &str,
    agent_id: &str,
    source: &Value,
) -> Result<Value, ToolFailure> {
    let session_id = source
        .get("nativeSessionId")
        .or_else(|| source.get("sessionId"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(ToolFailure::new("conversation_location_unavailable", true))?;
    let conversation_path = conversation_path_for_session(agent_id, session_id)?;
    Ok(json!({
        "schemaVersion": "licoup.subagent.receipt.v1",
        "operation": operation,
        "agentId": agent_id,
        "state": "completed",
        "conversationPath": conversation_path
    }))
}

fn conversation_path_for_session(agent_id: &str, session_id: &str) -> Result<String, ToolFailure> {
    for attempt in 0..CONVERSATION_PATH_POLL_ATTEMPTS {
        let response = conversations::conversation_list(&json!({
            "agent": agent_id,
            "sessionId": session_id,
            "limit": 2
        }))
        .map_err(|_| ToolFailure::new("conversation_location_unavailable", true))?;
        let sessions = response
            .get("sessions")
            .and_then(Value::as_array)
            .ok_or(ToolFailure::new("conversation_location_unavailable", true))?;
        if sessions.len() > 1 {
            return Err(ToolFailure::new("conversation_location_ambiguous", false));
        }
        if let Some(path) = sessions
            .first()
            .and_then(|session| session.get("sourcePath"))
            .and_then(Value::as_str)
            .filter(|path| std::path::Path::new(path).is_absolute())
        {
            return Ok(path.to_owned());
        }
        if attempt + 1 < CONVERSATION_PATH_POLL_ATTEMPTS {
            thread::sleep(std::time::Duration::from_millis(50));
        }
    }
    Err(ToolFailure::new("conversation_location_unavailable", true))
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ConversationResumeTarget {
    session_id: String,
    working_directory: Option<String>,
}

fn session_id_for_path(agent_id: &str, path: &str) -> Result<String, ToolFailure> {
    resume_target_for_path(agent_id, path).map(|target| target.session_id)
}

fn resume_target_for_path(
    agent_id: &str,
    path: &str,
) -> Result<ConversationResumeTarget, ToolFailure> {
    let path_ref = std::path::Path::new(path);
    if !path_ref.is_absolute() {
        return Err(ToolFailure::new("invalid_conversation_location", false));
    }
    for candidate in session_id_candidates(path_ref) {
        let Ok(response) = conversations::conversation_list(&json!({
            "agent": agent_id,
            "sessionId": candidate,
            "limit": 2
        })) else {
            continue;
        };
        if let Some(target) = exact_resume_target_for_path(&response, path)? {
            return Ok(target);
        }
    }
    let response = conversations::conversation_list(&json!({
        "agent": agent_id,
        "matchProjectPath": path,
        "limit": 2
    }))
    .map_err(|_| ToolFailure::new("conversation_location_unavailable", true))?;
    exact_resume_target_for_path(&response, path)?
        .ok_or(ToolFailure::new("conversation_location_unavailable", true))
}

#[cfg(test)]
fn exact_session_id_for_path(response: &Value, path: &str) -> Result<Option<String>, ToolFailure> {
    Ok(exact_resume_target_for_path(response, path)?.map(|target| target.session_id))
}

fn exact_resume_target_for_path(
    response: &Value,
    path: &str,
) -> Result<Option<ConversationResumeTarget>, ToolFailure> {
    let exact = response
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or(ToolFailure::new("conversation_location_unavailable", true))?
        .iter()
        .filter(|session| session.get("sourcePath").and_then(Value::as_str) == Some(path))
        .collect::<Vec<_>>();
    if exact.len() != 1 {
        return if exact.is_empty() {
            Ok(None)
        } else {
            Err(ToolFailure::new("conversation_location_ambiguous", false))
        };
    }
    let session_id = exact[0]
        .get("nativeSessionId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .or_else(|| {
            exact[0]
                .get("sessionId")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        });
    Ok(session_id.map(|session_id| ConversationResumeTarget {
        session_id,
        working_directory: exact[0]
            .get("workingDirectory")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_owned),
    }))
}

fn session_id_candidates(path: &std::path::Path) -> Vec<String> {
    const MAX_CANDIDATES: usize = 16;
    let mut candidates = Vec::new();
    let mut unique = HashSet::new();
    let mut push = |candidate: &str| {
        if candidates.len() < MAX_CANDIDATES
            && !candidate.is_empty()
            && candidate.len() <= MAX_ID_BYTES
            && unique.insert(candidate.to_owned())
        {
            candidates.push(candidate.to_owned());
        }
    };
    for component in path
        .components()
        .rev()
        .take(8)
        .filter_map(|component| component.as_os_str().to_str())
    {
        let stem = std::path::Path::new(component)
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or(component);
        if stem.starts_with("session_") {
            push(stem);
        }
        let bytes = stem.as_bytes();
        if bytes.len() >= 36 {
            for start in (0..=bytes.len() - 36).rev() {
                let Ok(value) = std::str::from_utf8(&bytes[start..start + 36]) else {
                    continue;
                };
                if uuid::Uuid::parse_str(value).is_ok() {
                    push(value);
                }
            }
        }
        push(stem);
    }
    candidates
}

fn project_dispatch_failure(agent_id: &str, source: &Value) -> ToolFailure {
    let code = source
        .pointer("/error/code")
        .and_then(Value::as_str)
        .unwrap_or("subagent_failed");
    let retryable = matches!(code, "temporary_unavailable" | "rate_limited" | "busy")
        || code.contains("timeout")
        || code.contains("output_limit");
    let projected_code = if code.contains("output_limit") {
        "subagent_output_limit"
    } else if retryable {
        "subagent_temporarily_unavailable"
    } else {
        "subagent_failed"
    };
    let conversation_path = source
        .get("nativeSessionId")
        .or_else(|| source.get("sessionId"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .and_then(|session_id| conversation_path_for_session(agent_id, session_id).ok());
    ToolFailure::new(projected_code, retryable).with_conversation_path(conversation_path)
}

/// Accept the client's proposed protocol revision when it is at least the
/// server's supported baseline (`MCP_VERSION`, a `YYYY-MM-DD` revision).
/// Newer clients propose later revisions; the negotiated response echoes the
/// client's proposal so clients never observe a downgrade.
fn supported_protocol_version(version: &str) -> bool {
    let bytes = version.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return false;
    }
    if !bytes
        .iter()
        .enumerate()
        .all(|(index, byte)| index == 4 || index == 7 || byte.is_ascii_digit())
    {
        return false;
    }
    version >= MCP_VERSION
}

fn canonical_agent_id(value: &str) -> Option<&'static str> {
    let normalized = value.trim().to_ascii_lowercase();
    [
        ("claude", "claude-code"),
        ("antigravity", "antigravity"),
        ("openclaw", "openclaw"),
        ("opencode", "opencode"),
        ("kilo", "kilo-code"),
        ("copilot", "copilot"),
        ("cursor", "cursor"),
        ("hermes", "hermes"),
        ("kimi", "kimi-code"),
        ("codex", "codex"),
        ("pi", "pi"),
    ]
    .into_iter()
    .find_map(|(needle, agent_id)| normalized.contains(needle).then_some(agent_id))
}

fn required_text(value: &Value, key: &str, max: usize) -> Result<String, ToolFailure> {
    optional_text(value, key, max)?.ok_or(ToolFailure::new("invalid_request", false))
}

fn optional_text(value: &Value, key: &str, max: usize) -> Result<Option<String>, ToolFailure> {
    let Some(raw) = value.get(key) else {
        return Ok(None);
    };
    let Some(text) = raw.as_str() else {
        return Err(ToolFailure::new("invalid_request", false));
    };
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed.len() > max || trimmed.contains('\0') {
        return Err(ToolFailure::new("invalid_request", false));
    }
    Ok(Some(trimmed.to_owned()))
}

fn optional_working_directory(value: &Value) -> Result<Option<String>, ToolFailure> {
    let Some(raw) = optional_text(value, "workingDirectory", MAX_WORKING_DIRECTORY_BYTES)? else {
        return Ok(None);
    };
    canonical_working_directory(&raw).map(Some)
}

fn canonical_working_directory(raw: &str) -> Result<String, ToolFailure> {
    let path = std::path::Path::new(raw);
    if !path.is_absolute() {
        return Err(ToolFailure::new("invalid_working_directory", false));
    }
    let canonical = std::fs::canonicalize(path)
        .map_err(|_| ToolFailure::new("invalid_working_directory", false))?;
    if !canonical.is_dir() {
        return Err(ToolFailure::new("invalid_working_directory", false));
    }
    canonical
        .to_str()
        .map(str::to_owned)
        .ok_or(ToolFailure::new("invalid_working_directory", false))
}

fn continuation_working_directory(
    requested: Option<String>,
    recorded: Option<&str>,
) -> Result<String, ToolFailure> {
    let recorded = recorded.map(canonical_working_directory).transpose()?;
    match (requested, recorded) {
        (Some(requested), Some(recorded)) if requested != recorded => Err(ToolFailure::new(
            "conversation_working_directory_mismatch",
            false,
        )),
        (Some(requested), _) => Ok(requested),
        (None, Some(recorded)) => Ok(recorded),
        (None, None) => Err(ToolFailure::new(
            "conversation_working_directory_unavailable",
            true,
        )),
    }
}

fn optional_timeout_ms(value: &Value) -> Result<Option<u64>, ToolFailure> {
    let Some(timeout_ms) = value.get("timeoutMs") else {
        return Ok(None);
    };
    // timeoutMs 0 opts out of any turn deadline: the subordinate runs until
    // the turn completes, however long that takes. This is a developer-mandated
    // rule; sending to an agent is never time-limited.
    timeout_ms
        .as_u64()
        .filter(|value| {
            *value == 0 || (MIN_SUBAGENT_TIMEOUT_MS..=MAX_SUBAGENT_TIMEOUT_MS).contains(value)
        })
        .map(Some)
        .ok_or(ToolFailure::new("invalid_request", false))
}

fn optional_bounded_u64(
    value: &Value,
    key: &str,
    min: u64,
    max: u64,
) -> Result<Option<u64>, ToolFailure> {
    let Some(raw) = value.get(key) else {
        return Ok(None);
    };
    raw.as_u64()
        .filter(|value| (min..=max).contains(value))
        .map(Some)
        .ok_or(ToolFailure::new("invalid_request", false))
}

fn optional_bool(value: &Value, key: &str) -> Result<Option<bool>, ToolFailure> {
    match value.get(key) {
        None => Ok(None),
        Some(value) => value
            .as_bool()
            .map(Some)
            .ok_or(ToolFailure::new("invalid_request", false)),
    }
}

fn optional_permission_mode(value: &Value) -> Result<Option<String>, ToolFailure> {
    let mode = optional_text(value, "permissionMode", 32)?;
    if mode.as_deref().is_some_and(|mode| {
        !matches!(
            mode,
            "default"
                | "manual"
                | "acceptEdits"
                | "plan"
                | "auto"
                | "dontAsk"
                | "bypassPermissions"
        )
    }) {
        return Err(ToolFailure::new("invalid_request", false));
    }
    Ok(mode)
}

fn required_workflow_role(value: &Value) -> Result<WorkflowRole, ToolFailure> {
    optional_text(value, "role", 16)?
        .as_deref()
        .and_then(WorkflowRole::parse)
        .ok_or(ToolFailure::new("invalid_request", false))
}

fn optional_workflow_lane(
    value: &Value,
    role: WorkflowRole,
) -> Result<Option<CodeEngineeringLane>, ToolFailure> {
    let lane = match optional_text(value, "lane", 16)? {
        Some(value) => Some(
            CodeEngineeringLane::parse(&value).ok_or(ToolFailure::new("invalid_request", false))?,
        ),
        None => None,
    };
    if role == WorkflowRole::Designer && lane.is_some() {
        return Err(ToolFailure::new("invalid_request", false));
    }
    Ok(lane)
}

fn configured_code_engineering_assignment(
    role: WorkflowRole,
    lane: Option<CodeEngineeringLane>,
) -> Option<DispatchCandidate> {
    configured_code_engineering_strategy()?
        .into_iter()
        .find(|assignment| assignment.role == role && assignment.lane == lane)
        .map(|assignment| assignment.candidate)
}

fn configured_code_engineering_strategy() -> Option<Vec<ConfiguredCodeEngineeringRole>> {
    let state = client_state::state_get(ClientStateGetRequest {
        collection: ClientStateCollection::AdaptiveFlywheel,
    })
    .ok()?;
    parse_code_engineering_strategy(&Value::Object(state.document.content.into_iter().collect()))
}

fn parse_code_engineering_strategy(policy: &Value) -> Option<Vec<ConfiguredCodeEngineeringRole>> {
    let code_engineering = policy.get("code_engineering")?;
    if code_engineering.get("strategy").and_then(Value::as_str) != Some("frontend_backend_roles") {
        return None;
    }
    let slots = [
        (&["designer"][..], WorkflowRole::Designer, None),
        (
            &["worker", "backend"][..],
            WorkflowRole::Worker,
            Some(CodeEngineeringLane::Backend),
        ),
        (
            &["worker", "frontend"][..],
            WorkflowRole::Worker,
            Some(CodeEngineeringLane::Frontend),
        ),
        (
            &["reviewer", "backend"][..],
            WorkflowRole::Reviewer,
            Some(CodeEngineeringLane::Backend),
        ),
        (
            &["reviewer", "frontend"][..],
            WorkflowRole::Reviewer,
            Some(CodeEngineeringLane::Frontend),
        ),
    ];
    slots
        .into_iter()
        .map(|(path, role, lane)| {
            let assignment = path
                .iter()
                .try_fold(code_engineering, |value, key| value.get(key))?
                .as_object()?;
            let agent_id = assignment.get("agent")?.as_str()?.trim();
            if agent_id.is_empty() || agent_id.len() > MAX_ID_BYTES {
                return None;
            }
            Some(ConfiguredCodeEngineeringRole {
                role,
                lane,
                candidate: DispatchCandidate {
                    agent_id: agent_id.to_owned(),
                    model: assignment
                        .get("model")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(str::to_owned),
                    reasoning_effort: assignment
                        .get("reasoning_effort")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(str::to_owned),
                },
            })
        })
        .collect()
}

fn project_code_engineering_strategy(assignments: Vec<ConfiguredCodeEngineeringRole>) -> Value {
    json!({
        "strategy": "frontend_backend_roles",
        "configured": true,
        "lanes": ["backend", "frontend"],
        "assignments": assignments.into_iter().map(|assignment| json!({
            "role": match assignment.role {
                WorkflowRole::Designer => "designer",
                WorkflowRole::Worker => "worker",
                WorkflowRole::Reviewer => "reviewer",
            },
            "lane": assignment.lane.map(CodeEngineeringLane::as_str),
            "agentId": assignment.candidate.agent_id,
            "model": assignment.candidate.model,
            "reasoningEffort": assignment.candidate.reasoning_effort,
        })).collect::<Vec<_>>()
    })
}

fn unconfigured_code_engineering_strategy() -> Value {
    json!({
        "strategy": "frontend_backend_roles",
        "configured": false,
        "lanes": ["backend", "frontend"],
        "assignments": []
    })
}

fn tool_catalog() -> Vec<Value> {
    vec![
        json!({
            "name": "lico_subagents_list",
            "description": "List every scanned, runnable LicoUp agent and the configured code-engineering strategy: one shared Designer plus separate frontend/backend Worker and Reviewer assignments.",
            "inputSchema": closed_object(&[], json!({}))
        }),
        json!({
            "name": "lico_subagent_probe",
            "description": "LicoUp-owned disposable readiness probe. Main agents must not use this to drive subordinates; LicoUp runs readiness during handoff accept. By default LicoUp selects the cheapest locally available model using the provider-owned billing table, including harness-included routes; an exact model may be requested only when that route is itself under acceptance. Any created probe conversation is moved to Trash and its disappearance is verified before success is returned.",
            "inputSchema": closed_object(
                &["agentId", "workingDirectory"],
                json!({
                    "agentId": bounded_string(MAX_ID_BYTES),
                    "workingDirectory": bounded_string(MAX_WORKING_DIRECTORY_BYTES),
                    "exactModel": bounded_string(MAX_ID_BYTES),
                    "exactReasoningEffort": bounded_string(32),
                    "timeoutMs": bounded_integer(0, MAX_SUBAGENT_TIMEOUT_MS)
                })
            )
        }),
        json!({
            "name": "lico_subagent_delegate",
            "description": "Request a LicoUp-owned subordinate handoff. Choose sessionMode=new (default, fresh session) or sessionMode=resume with conversationPath. Returns immediately with accepted+dispatchId; the main turn should stop. LicoUp runs the subordinate, then resumes the original main conversation. Worker and Reviewer calls may name the frontend or backend lane; the saved role assignment is authoritative when configured. Optional reviewed fallbacks are tried only for quota, rate-limit, or capacity failures.",
            "inputSchema": closed_object(
                &["agentId", "role", "prompt"],
                json!({
                    "agentId": bounded_string(MAX_ID_BYTES),
                    "role": workflow_role_schema(),
                    "lane": code_engineering_lane_schema(),
                    "prompt": bounded_string(MAX_PROMPT_BYTES),
                    "sessionMode": session_mode_schema(),
                    "conversationPath": bounded_string(MAX_CONVERSATION_PATH_BYTES),
                    "model": bounded_string(MAX_ID_BYTES),
                    "reasoningEffort": bounded_string(32),
                    "workingDirectory": bounded_string(MAX_WORKING_DIRECTORY_BYTES),
                    "mainConversationPath": bounded_string(MAX_CONVERSATION_PATH_BYTES),
                    "timeoutMs": bounded_integer(0, MAX_SUBAGENT_TIMEOUT_MS),
                    "maxStdoutBytes": bounded_integer(MIN_SUBAGENT_STDOUT_BYTES, MAX_SUBAGENT_STDOUT_BYTES),
                    "maxStderrBytes": bounded_integer(MIN_SUBAGENT_STDERR_BYTES, MAX_SUBAGENT_STDERR_BYTES),
                    "allowAll": {"type": "boolean"},
                    "permissionMode": permission_mode_schema(),
                    "fallbackCandidates": {
                        "type": "array",
                        "minItems": 1,
                        "maxItems": MAX_FALLBACK_CANDIDATES,
                        "items": closed_object(
                            &["agentId"],
                            json!({
                                "agentId": bounded_string(MAX_ID_BYTES),
                                "model": bounded_string(MAX_ID_BYTES),
                                "reasoningEffort": bounded_string(32)
                            })
                        )
                    }
                })
            )
        }),
        json!({
            "name": "lico_subagent_continue",
            "description": "Request LicoUp to resume an exact subordinate conversation (sessionMode=resume). Equivalent to lico_subagent_delegate with sessionMode=resume and conversationPath. Returns immediately with accepted+dispatchId; the main turn should stop.",
            "inputSchema": closed_object(
                &["agentId", "conversationPath", "role", "prompt"],
                json!({
                    "agentId": bounded_string(MAX_ID_BYTES),
                    "conversationPath": bounded_string(MAX_CONVERSATION_PATH_BYTES),
                    "sessionMode": session_mode_schema(),
                    "role": workflow_role_schema(),
                    "lane": code_engineering_lane_schema(),
                    "prompt": bounded_string(MAX_PROMPT_BYTES),
                    "model": bounded_string(MAX_ID_BYTES),
                    "reasoningEffort": bounded_string(32),
                    "workingDirectory": bounded_string(MAX_WORKING_DIRECTORY_BYTES),
                    "mainConversationPath": bounded_string(MAX_CONVERSATION_PATH_BYTES),
                    "timeoutMs": bounded_integer(0, MAX_SUBAGENT_TIMEOUT_MS),
                    "maxStdoutBytes": bounded_integer(MIN_SUBAGENT_STDOUT_BYTES, MAX_SUBAGENT_STDOUT_BYTES),
                    "maxStderrBytes": bounded_integer(MIN_SUBAGENT_STDERR_BYTES, MAX_SUBAGENT_STDERR_BYTES),
                    "allowAll": {"type": "boolean"},
                    "permissionMode": permission_mode_schema()
                })
            )
        }),
        json!({
            "name": "lico_subagent_cancel",
            "description": "Request cancellation of the subordinate conversation at the exact local file location.",
            "inputSchema": closed_object(
                &["agentId", "conversationPath"],
                json!({
                    "agentId": bounded_string(MAX_ID_BYTES),
                    "conversationPath": bounded_string(MAX_CONVERSATION_PATH_BYTES)
                })
            )
        }),
    ]
}

fn closed_object(required: &[&str], properties: Value) -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": required,
        "properties": properties
    })
}

fn bounded_string(max: usize) -> Value {
    json!({"type": "string", "minLength": 1, "maxLength": max})
}

fn bounded_integer(min: u64, max: u64) -> Value {
    json!({"type": "integer", "minimum": min, "maximum": max})
}

fn permission_mode_schema() -> Value {
    json!({
        "type": "string",
        "enum": [
            "default",
            "manual",
            "acceptEdits",
            "plan",
            "auto",
            "dontAsk",
            "bypassPermissions"
        ]
    })
}

fn workflow_role_schema() -> Value {
    json!({
        "type": "string",
        "enum": ["designer", "worker", "reviewer"]
    })
}

fn session_mode_schema() -> Value {
    json!({
        "type": "string",
        "enum": ["new", "resume"]
    })
}

fn code_engineering_lane_schema() -> Value {
    json!({
        "type": "string",
        "enum": ["backend", "frontend"]
    })
}

fn tool_names() -> &'static [&'static str] {
    &[
        "lico_subagents_list",
        "lico_subagent_probe",
        "lico_subagent_delegate",
        "lico_subagent_continue",
        "lico_subagent_cancel",
    ]
}

fn validate_tool_arguments(name: &str, value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    let allowed: &[&str] = match name {
        "lico_subagents_list" => &[],
        "lico_subagent_probe" => &[
            "agentId",
            "workingDirectory",
            "exactModel",
            "exactReasoningEffort",
            "timeoutMs",
        ],
        "lico_subagent_delegate" => &[
            "agentId",
            "role",
            "lane",
            "prompt",
            "sessionMode",
            "conversationPath",
            "model",
            "reasoningEffort",
            "workingDirectory",
            "mainConversationPath",
            "timeoutMs",
            "maxStdoutBytes",
            "maxStderrBytes",
            "allowAll",
            "permissionMode",
            "fallbackCandidates",
        ],
        "lico_subagent_continue" => &[
            "agentId",
            "conversationPath",
            "sessionMode",
            "role",
            "lane",
            "prompt",
            "model",
            "reasoningEffort",
            "workingDirectory",
            "mainConversationPath",
            "timeoutMs",
            "maxStdoutBytes",
            "maxStderrBytes",
            "allowAll",
            "permissionMode",
        ],
        "lico_subagent_cancel" => &["agentId", "conversationPath"],
        _ => return false,
    };
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return false;
    }
    match name {
        "lico_subagents_list" => object.is_empty(),
        "lico_subagent_probe" => {
            valid_required(object, "agentId", MAX_ID_BYTES)
                && valid_required(object, "workingDirectory", MAX_WORKING_DIRECTORY_BYTES)
                && valid_optional(object, "exactModel", MAX_ID_BYTES)
                && valid_optional(object, "exactReasoningEffort", 32)
                && (!object.contains_key("exactReasoningEffort")
                    || object.contains_key("exactModel"))
                && valid_optional_timeout(object, "timeoutMs")
        }
        "lico_subagent_delegate" => {
            valid_required(object, "agentId", MAX_ID_BYTES)
                && valid_workflow_role_and_lane(object)
                && valid_required(object, "prompt", MAX_PROMPT_BYTES)
                && valid_optional_session_mode(object)
                && valid_delegate_conversation_path(object)
                && valid_optional(object, "model", MAX_ID_BYTES)
                && valid_optional(object, "reasoningEffort", 32)
                && valid_optional(object, "workingDirectory", MAX_WORKING_DIRECTORY_BYTES)
                && valid_optional(object, "mainConversationPath", MAX_CONVERSATION_PATH_BYTES)
                && valid_optional_timeout(object, "timeoutMs")
                && valid_optional_bounded_u64(
                    object,
                    "maxStdoutBytes",
                    MIN_SUBAGENT_STDOUT_BYTES,
                    MAX_SUBAGENT_STDOUT_BYTES,
                )
                && valid_optional_bounded_u64(
                    object,
                    "maxStderrBytes",
                    MIN_SUBAGENT_STDERR_BYTES,
                    MAX_SUBAGENT_STDERR_BYTES,
                )
                && valid_optional_bool(object, "allowAll")
                && valid_optional_permission_mode(object)
                && valid_fallback_candidates(object.get("fallbackCandidates"))
        }
        "lico_subagent_continue" => {
            valid_required(object, "agentId", MAX_ID_BYTES)
                && valid_required(object, "conversationPath", MAX_CONVERSATION_PATH_BYTES)
                && valid_optional_session_mode_resume_only(object)
                && valid_workflow_role_and_lane(object)
                && valid_required(object, "prompt", MAX_PROMPT_BYTES)
                && valid_optional(object, "model", MAX_ID_BYTES)
                && valid_optional(object, "reasoningEffort", 32)
                && valid_optional(object, "workingDirectory", MAX_WORKING_DIRECTORY_BYTES)
                && valid_optional(object, "mainConversationPath", MAX_CONVERSATION_PATH_BYTES)
                && valid_optional_timeout(object, "timeoutMs")
                && valid_optional_bounded_u64(
                    object,
                    "maxStdoutBytes",
                    MIN_SUBAGENT_STDOUT_BYTES,
                    MAX_SUBAGENT_STDOUT_BYTES,
                )
                && valid_optional_bounded_u64(
                    object,
                    "maxStderrBytes",
                    MIN_SUBAGENT_STDERR_BYTES,
                    MAX_SUBAGENT_STDERR_BYTES,
                )
                && valid_optional_bool(object, "allowAll")
                && valid_optional_permission_mode(object)
        }
        "lico_subagent_cancel" => {
            valid_required(object, "agentId", MAX_ID_BYTES)
                && valid_required(object, "conversationPath", MAX_CONVERSATION_PATH_BYTES)
        }
        _ => false,
    }
}

fn valid_required(object: &Map<String, Value>, key: &str, max: usize) -> bool {
    object
        .get(key)
        .and_then(Value::as_str)
        .is_some_and(|value| {
            !value.trim().is_empty() && value.len() <= max && !value.contains('\0')
        })
}

fn valid_optional(object: &Map<String, Value>, key: &str, max: usize) -> bool {
    !object.contains_key(key) || valid_required(object, key, max)
}

fn valid_workflow_role_and_lane(object: &Map<String, Value>) -> bool {
    let Some(role) = object
        .get("role")
        .and_then(Value::as_str)
        .and_then(WorkflowRole::parse)
    else {
        return false;
    };
    let lane = object
        .get("lane")
        .and_then(Value::as_str)
        .and_then(CodeEngineeringLane::parse);
    if object.contains_key("lane") && lane.is_none() {
        return false;
    }
    role != WorkflowRole::Designer || lane.is_none()
}

fn valid_optional_timeout(object: &Map<String, Value>, key: &str) -> bool {
    !object.contains_key(key)
        || object
            .get(key)
            .and_then(Value::as_u64)
            .is_some_and(|value| {
                value == 0 || (MIN_SUBAGENT_TIMEOUT_MS..=MAX_SUBAGENT_TIMEOUT_MS).contains(&value)
            })
}

fn valid_optional_bounded_u64(object: &Map<String, Value>, key: &str, min: u64, max: u64) -> bool {
    !object.contains_key(key)
        || object
            .get(key)
            .and_then(Value::as_u64)
            .is_some_and(|value| (min..=max).contains(&value))
}

fn valid_optional_bool(object: &Map<String, Value>, key: &str) -> bool {
    !object.contains_key(key) || object.get(key).is_some_and(Value::is_boolean)
}

fn valid_optional_session_mode(object: &Map<String, Value>) -> bool {
    !object.contains_key("sessionMode")
        || object
            .get("sessionMode")
            .and_then(Value::as_str)
            .and_then(SessionMode::parse)
            .is_some()
}

fn valid_optional_session_mode_resume_only(object: &Map<String, Value>) -> bool {
    !object.contains_key("sessionMode")
        || object
            .get("sessionMode")
            .and_then(Value::as_str)
            .and_then(SessionMode::parse)
            == Some(SessionMode::Resume)
}

fn valid_delegate_conversation_path(object: &Map<String, Value>) -> bool {
    let mode = object
        .get("sessionMode")
        .and_then(Value::as_str)
        .and_then(SessionMode::parse)
        .unwrap_or(SessionMode::New);
    match mode {
        SessionMode::New => {
            !object.contains_key("conversationPath")
                || object
                    .get("conversationPath")
                    .and_then(Value::as_str)
                    .is_none_or(|value| value.trim().is_empty())
        }
        SessionMode::Resume => {
            valid_required(object, "conversationPath", MAX_CONVERSATION_PATH_BYTES)
        }
    }
}

fn valid_optional_permission_mode(object: &Map<String, Value>) -> bool {
    !object.contains_key("permissionMode")
        || object
            .get("permissionMode")
            .and_then(Value::as_str)
            .is_some_and(|mode| {
                matches!(
                    mode,
                    "default"
                        | "manual"
                        | "acceptEdits"
                        | "plan"
                        | "auto"
                        | "dontAsk"
                        | "bypassPermissions"
                )
            })
}

fn valid_fallback_candidates(value: Option<&Value>) -> bool {
    let Some(value) = value else {
        return true;
    };
    value.as_array().is_some_and(|rows| {
        !rows.is_empty()
            && rows.len() <= MAX_FALLBACK_CANDIDATES
            && rows.iter().all(|row| {
                row.as_object().is_some_and(|object| {
                    !object.is_empty()
                        && object.keys().all(|key| {
                            matches!(key.as_str(), "agentId" | "model" | "reasoningEffort")
                        })
                        && valid_required(object, "agentId", MAX_ID_BYTES)
                        && valid_optional(object, "model", MAX_ID_BYTES)
                        && valid_optional(object, "reasoningEffort", 32)
                })
            })
    })
}

fn parse_tool_call(params: Option<&Value>) -> Option<(String, Value)> {
    let object = params?.as_object()?;
    if object.len() != 2 || !object.contains_key("name") || !object.contains_key("arguments") {
        return None;
    }
    Some((
        object.get("name")?.as_str()?.to_owned(),
        object.get("arguments")?.clone(),
    ))
}

fn empty_object(value: Option<&Value>) -> bool {
    value.is_none_or(|value| value.as_object().is_some_and(Map::is_empty))
}

fn tool_success(value: Value) -> Value {
    let text = serde_json::to_string(&value).unwrap_or_else(|_| "{}".into());
    json!({
        "content": [{"type": "text", "text": text}],
        "isError": false,
        "structuredContent": value
    })
}

fn tool_error(error: &ToolFailure) -> Value {
    let mut value = json!({
        "schemaVersion": "licoup.subagent.error.v1",
        "reasonCode": error.code,
        "retryable": error.retryable
    });
    if let Some(conversation_path) = error.conversation_path.as_ref() {
        value["conversationPath"] = json!(conversation_path);
    }
    let text = serde_json::to_string(&value).unwrap_or_else(|_| "{}".into());
    json!({
        "content": [{"type": "text", "text": text}],
        "isError": true,
        "structuredContent": value
    })
}

fn rpc_success(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn rpc_error(id: Value, code: i64) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": rpc_message(code)}})
}

fn rpc_message(code: i64) -> &'static str {
    match code {
        -32700 => "Parse error",
        -32600 => "Invalid Request",
        -32601 => "Method not found",
        -32602 => "Invalid params",
        -32002 => "Server not initialized",
        -32800 => "Request cancelled",
        _ => "Internal error",
    }
}

fn write_json(output: &Mutex<io::Stdout>, value: Value) {
    let mut output = output.lock().unwrap_or_else(|error| error.into_inner());
    let _ = serde_json::to_writer(&mut *output, &value);
    let _ = output.write_all(b"\n");
    let _ = output.flush();
}

fn id_key(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".into())
}

fn extract_id(prefix: &[u8]) -> Value {
    serde_json::from_slice::<Value>(prefix)
        .ok()
        .and_then(|value| value.get("id").cloned())
        .unwrap_or(Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[test]
    fn protocol_version_negotiation_accepts_newer_clients() {
        assert!(supported_protocol_version("2025-06-18"));
        assert!(supported_protocol_version("2025-11-25"));
        assert!(supported_protocol_version("2026-03-26"));
        assert!(!supported_protocol_version("2025-03-26"));
        assert!(!supported_protocol_version("2025-6-18"));
        assert!(!supported_protocol_version("2025-06-18-extra"));
        assert!(!supported_protocol_version(""));
    }

    fn client_name_selects_the_main_agent() {
        assert_eq!(canonical_agent_id("Codex Desktop"), Some("codex"));
        assert_eq!(canonical_agent_id("Claude Code"), Some("claude-code"));
        assert_eq!(canonical_agent_id("unknown"), None);
        assert_eq!(
            ensure_manager_bound("").unwrap_err().code,
            "main_agent_unbound"
        );
    }

    #[test]
    fn tool_surface_is_closed_and_contains_only_subagent_operations() {
        assert_eq!(
            tool_names(),
            &[
                "lico_subagents_list",
                "lico_subagent_probe",
                "lico_subagent_delegate",
                "lico_subagent_continue",
                "lico_subagent_cancel",
            ]
        );
        assert!(validate_tool_arguments(
            "lico_subagent_probe",
            &json!({"agentId": "worker", "workingDirectory": "/fixture/location/project"})
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_probe",
            &json!({
                "agentId": "worker",
                "workingDirectory": "/fixture/location/project",
                "exactReasoningEffort": "low"
            })
        ));
        assert!(validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({"agentId": "worker", "role": "worker", "lane": "backend", "prompt": "do the task"})
        ));
        assert_eq!(
            workflow_role_schema()["enum"],
            json!(["designer", "worker", "reviewer"])
        );
        assert!(!validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({"agentId": "designer", "role": "designer", "lane": "frontend", "prompt": "design"})
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({"agentId": "worker", "role": "worker", "prompt": "do the task", "unexpected": true})
        ));
        assert!(validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({
                "agentId": "primary",
                "role": "worker",
                "prompt": "do the task",
                "fallbackCandidates": [{"agentId": "peer", "model": "same-band"}]
            })
        ));
    }

    #[test]
    fn code_engineering_strategy_has_one_designer_and_split_delivery_lanes() {
        let strategy = parse_code_engineering_strategy(&json!({
            "code_engineering": {
                "strategy": "frontend_backend_roles",
                "designer": {"agent": "codex", "model": "design-model", "reasoning_effort": "high"},
                "worker": {
                    "backend": {"agent": "claude-code", "model": "backend-model"},
                    "frontend": {"agent": "cursor", "model": "frontend-model"}
                },
                "reviewer": {
                    "backend": {"agent": "opencode", "reasoning_effort": "high"},
                    "frontend": {"agent": "kimi-code", "reasoning_effort": "medium"}
                }
            }
        }))
        .unwrap();

        assert_eq!(strategy.len(), 5);
        assert_eq!(strategy[0].role, WorkflowRole::Designer);
        assert_eq!(strategy[0].lane, None);
        assert_eq!(strategy[1].role, WorkflowRole::Worker);
        assert_eq!(strategy[1].lane, Some(CodeEngineeringLane::Backend));
        assert_eq!(strategy[2].role, WorkflowRole::Worker);
        assert_eq!(strategy[2].lane, Some(CodeEngineeringLane::Frontend));
        assert_eq!(strategy[3].role, WorkflowRole::Reviewer);
        assert_eq!(strategy[3].lane, Some(CodeEngineeringLane::Backend));
        assert_eq!(strategy[4].role, WorkflowRole::Reviewer);
        assert_eq!(strategy[4].lane, Some(CodeEngineeringLane::Frontend));
    }

    #[test]
    fn diagnostic_probe_prefers_free_harness_models_before_paid_models() {
        let target = json!({
            "modelCatalog": {
                "models": [
                    {"name": "kimi-code/k3", "reasoningEfforts": ["low", "high", "max"]},
                    {"name": "kimi-code/kimi-for-coding"},
                    {"name": "unpriced-local-model"}
                ]
            }
        });
        let selected = select_probe_model(&target, "kimi-code", None, None).unwrap();
        assert_eq!(selected.runtime_model, "kimi-code/kimi-for-coding");
        assert_eq!(selected.reasoning_effort, None);
        assert!(selected.routing_cost.is_some_and(|cost| cost > 0.0));
        assert!(!selected.included);
        assert_eq!(selected.selection_mode, "lowest-measured-cost");

        let exact =
            select_probe_model(&target, "kimi-code", Some("kimi-code/k3"), Some("max")).unwrap();
        assert_eq!(exact.runtime_model, "kimi-code/k3");
        assert_eq!(exact.reasoning_effort.as_deref(), Some("max"));
        assert_eq!(exact.selection_mode, "exact-model");

        let cursor = select_probe_model(
            &json!({"modelCatalog": {"models": [
                {"name": "gpt-5.6-luna-low"},
                {"name": "composer-2.5-fast"},
                {"name": "composer-2.5"},
                {"name": "grok-4.5"}
            ]}}),
            "cursor",
            None,
            None,
        )
        .unwrap();
        assert_eq!(cursor.runtime_model, "composer-2.5");
        assert_eq!(cursor.routing_cost, Some(0.0));
        assert!(cursor.included);
        assert_eq!(cursor.pricing_provider.as_deref(), Some("cursor"));

        let kilo = select_probe_model(
            &json!({"modelCatalog": {"models": [
                {"name": "anthropic/claude-opus-4.7"},
                {"name": "nvidia/nemotron-3-super-120b-a12b:free"},
                {"name": "kilo-auto/free"}
            ]}}),
            "kilo-code",
            None,
            None,
        )
        .unwrap();
        assert_eq!(kilo.runtime_model, "kilo-auto/free");
        assert_eq!(kilo.routing_cost, Some(0.0));
        assert!(kilo.included);
        assert_eq!(kilo.pricing_provider.as_deref(), Some("kilo"));

        let antigravity = select_probe_model(
            &json!({"modelCatalog": {"models": [
                {"name": "Gemini 3.5 Flash (High)"},
                {"name": "gemini-3.1-pro-preview"}
            ]}}),
            "antigravity",
            None,
            None,
        )
        .unwrap();
        assert_eq!(antigravity.runtime_model, "gemini-3.1-pro-preview");
        assert!(antigravity.routing_cost.is_some());
        assert_eq!(antigravity.pricing_provider.as_deref(), Some("google"));

        let claude = select_probe_model(
            &json!({"modelCatalog": {"models": [
                {"name": "deepseek-v4-flash"},
                {"name": "deepseek-v4-pro"}
            ]}}),
            "claude-code",
            None,
            None,
        )
        .unwrap();
        assert_eq!(claude.runtime_model, "deepseek-v4-flash");
        assert!(claude.routing_cost.is_some());
        assert_eq!(claude.pricing_provider.as_deref(), Some("deepseek"));
    }

    #[test]
    fn diagnostic_probe_accepts_any_non_empty_assistant_response() {
        assert!(probe_response_is_ready(&json!({"output": "READY"})));
        assert!(probe_response_is_ready(&json!({
            "output": "Ready to accept work."
        })));
        assert!(!probe_response_is_ready(&json!({"output": "  \n"})));
        assert!(!probe_response_is_ready(&json!({})));
    }

    #[test]
    fn dispatch_reasoning_effort_must_be_declared_by_the_exact_model() {
        let target = json!({"modelCatalog": {"models": [
            {"name": "anthropic/claude-opus-4.7", "reasoningEfforts": ["max"]},
            {"name": "kilo-auto/free", "reasoningEfforts": []}
        ]}});
        let supported = DispatchCandidate {
            agent_id: "kilo-code".into(),
            model: Some("anthropic/claude-opus-4.7".into()),
            reasoning_effort: Some("max".into()),
        };
        assert!(validate_dispatch_selection(&supported, &target).is_ok());

        let unsupported = DispatchCandidate {
            agent_id: "kilo-code".into(),
            model: Some("kilo-auto/free".into()),
            reasoning_effort: Some("high".into()),
        };
        assert_eq!(
            validate_dispatch_selection(&unsupported, &target)
                .unwrap_err()
                .code,
            "subagent_reasoning_effort_unavailable"
        );
    }

    #[test]
    fn diagnostic_probe_cleanup_targets_the_complete_kimi_session() {
        let session_root = std::env::temp_dir().join(format!("session_{}", uuid::Uuid::new_v4()));
        let wire = session_root.join("agents/main/wire.jsonl");
        std::fs::create_dir_all(wire.parent().unwrap()).unwrap();
        std::fs::write(&wire, b"{}\n").unwrap();
        std::fs::write(session_root.join("state.json"), b"{}").unwrap();
        assert_eq!(
            probe_cleanup_target("kimi-code", wire.to_str().unwrap()).unwrap(),
            std::fs::canonicalize(&session_root).unwrap()
        );
        std::fs::remove_dir_all(session_root).unwrap();
    }

    #[test]
    fn subagent_projection_never_exposes_local_locations() {
        let projected = project_subagent(
            &json!({
                "target": "worker",
                "label": "Worker",
                "location": "<local-path>",
                "adapterCapabilities": {"conversationCapabilityMatrix": {"send": true}},
                "modelCatalog": {"models": []}
            }),
            "codex",
        );
        assert_eq!(
            projected.get("agentId").and_then(Value::as_str),
            Some("worker")
        );
        assert!(projected.get("location").is_none());
        assert_eq!(projected["sameFramework"], false);
        assert!(!projected.to_string().contains("<local-path>"));
    }

    #[test]
    fn same_framework_is_a_distinct_valid_subordinate_conversation() {
        let projected = project_subagent(
            &json!({
                "target": "codex",
                "label": "Codex",
                "status": "detected",
                "supportedActions": ["runtime.message.send"],
                "adapterCapabilities": {"conversationCapabilityMatrix": {"send": true}},
                "modelCatalog": {"models": []}
            }),
            "codex",
        );
        assert_eq!(projected["sameFramework"], true);
        assert!(subordinate_is_available(&json!({
            "target": "codex",
            "status": "detected",
            "supportedActions": ["runtime.message.send"]
        })));
    }

    #[test]
    fn conversation_locations_must_be_absolute() {
        assert_eq!(
            session_id_for_path("codex", "relative.jsonl")
                .unwrap_err()
                .code,
            "invalid_conversation_location"
        );
        let codex = session_id_candidates(std::path::Path::new(
            "/fixture/location/sessions/rollout-2026-08-02T03-23-02-019fbec7-a57b-7612-b817-9c990936846d.jsonl",
        ));
        assert_eq!(
            codex.first().map(String::as_str),
            Some("019fbec7-a57b-7612-b817-9c990936846d")
        );
        let kimi = session_id_candidates(std::path::Path::new(
            "/fixture/location/sessions/session_5ba759f6-100a-4d23-ac3a-adbe0b66ed59/agents/main/wire.jsonl",
        ));
        assert!(
            kimi.iter()
                .any(|value| value == "session_5ba759f6-100a-4d23-ac3a-adbe0b66ed59")
        );
        assert!(session_id_candidates(std::path::Path::new("/fixture/location/opaque.jsonl")).len() <= 16);
    }

    #[test]
    fn exact_conversation_lookup_revalidates_the_full_source_path() {
        let expected = "/fixture/location/conversations/exact.jsonl";
        let response = json!({
            "sessions": [{
                "sourcePath": expected,
                "nativeSessionId": "native-exact",
                "workingDirectory": "/fixture/location/project"
            }]
        });
        assert_eq!(
            exact_session_id_for_path(&response, expected).unwrap(),
            Some("native-exact".into())
        );
        assert_eq!(
            exact_resume_target_for_path(&response, expected).unwrap(),
            Some(ConversationResumeTarget {
                session_id: "native-exact".into(),
                working_directory: Some("/fixture/location/project".into()),
            })
        );
        assert_eq!(
            exact_session_id_for_path(&response, "/fixture/location/conversations/other.jsonl").unwrap(),
            None
        );
    }

    #[test]
    fn working_directories_are_absolute_existing_directories() {
        let root = std::env::temp_dir();
        let accepted = optional_working_directory(&json!({
            "workingDirectory": root.to_string_lossy()
        }))
        .unwrap();
        assert!(accepted.is_some_and(|path| std::path::Path::new(&path).is_absolute()));
        assert_eq!(
            optional_working_directory(&json!({"workingDirectory": "relative"}))
                .unwrap_err()
                .code,
            "invalid_working_directory"
        );
    }

    #[test]
    fn continuation_recovers_and_binds_the_recorded_working_directory() {
        let root = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let root = root.to_string_lossy().to_string();
        assert_eq!(
            continuation_working_directory(None, Some(&root)).unwrap(),
            root
        );
        assert_eq!(
            continuation_working_directory(Some(root.clone()), Some(&root)).unwrap(),
            root
        );
        assert_eq!(
            continuation_working_directory(Some("/".into()), Some(&root))
                .unwrap_err()
                .code,
            "conversation_working_directory_mismatch"
        );
        assert_eq!(
            continuation_working_directory(None, None).unwrap_err().code,
            "conversation_working_directory_unavailable"
        );
    }

    #[test]
    fn subagent_timeouts_are_optional_and_unbounded_by_zero() {
        assert_eq!(optional_timeout_ms(&json!({})).unwrap(), None);
        assert_eq!(
            optional_timeout_ms(&json!({"timeoutMs": MAX_SUBAGENT_TIMEOUT_MS})).unwrap(),
            Some(MAX_SUBAGENT_TIMEOUT_MS)
        );
        // timeoutMs 0 opts out of any turn deadline (developer-mandated rule).
        assert_eq!(
            optional_timeout_ms(&json!({"timeoutMs": 0})).unwrap(),
            Some(0)
        );
        for timeout_ms in [MIN_SUBAGENT_TIMEOUT_MS - 1, MAX_SUBAGENT_TIMEOUT_MS + 1] {
            assert_eq!(
                optional_timeout_ms(&json!({"timeoutMs": timeout_ms}))
                    .unwrap_err()
                    .code,
                "invalid_request"
            );
        }
        assert!(validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({
                "agentId": "worker",
                "role": "worker",
                "prompt": "do the task",
                "timeoutMs": 15 * 60 * 1_000
            })
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_continue",
            &json!({
                "agentId": "worker",
                "conversationPath": "/fixture/location/conversation.jsonl",
                "role": "worker",
                "prompt": "continue",
                "timeoutMs": MAX_SUBAGENT_TIMEOUT_MS + 1
            })
        ));
    }

    #[test]
    fn internal_agent_event_budgets_are_explicit_and_bounded() {
        assert_eq!(
            optional_bounded_u64(
                &json!({"maxStdoutBytes": MAX_SUBAGENT_STDOUT_BYTES}),
                "maxStdoutBytes",
                MIN_SUBAGENT_STDOUT_BYTES,
                MAX_SUBAGENT_STDOUT_BYTES,
            )
            .unwrap(),
            Some(MAX_SUBAGENT_STDOUT_BYTES)
        );
        assert!(
            optional_bounded_u64(
                &json!({"maxStdoutBytes": MAX_SUBAGENT_STDOUT_BYTES + 1}),
                "maxStdoutBytes",
                MIN_SUBAGENT_STDOUT_BYTES,
                MAX_SUBAGENT_STDOUT_BYTES,
            )
            .is_err()
        );
        assert!(validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({
                "agentId": "worker",
                "role": "worker",
                "prompt": "do the task",
                "maxStdoutBytes": 8 * 1024 * 1024,
                "maxStderrBytes": 1024 * 1024
            })
        ));
    }

    #[test]
    fn recoverable_failures_can_return_only_the_private_handoff_location() {
        let error = ToolFailure::new("subagent_output_limit", true)
            .with_conversation_path(Some("/fixture/location/conversation.jsonl".into()));
        let projected = tool_error(&error);
        assert_eq!(
            projected["structuredContent"]["reasonCode"],
            "subagent_output_limit"
        );
        assert_eq!(projected["structuredContent"]["retryable"], true);
        assert_eq!(
            projected["structuredContent"]["conversationPath"],
            "/fixture/location/conversation.jsonl"
        );
        assert!(projected.get("sessionId").is_none());
        assert!(projected.get("output").is_none());
    }

    #[test]
    fn native_approval_posture_is_explicit_and_closed() {
        assert_eq!(optional_bool(&json!({}), "allowAll").unwrap(), None);
        assert_eq!(
            optional_bool(&json!({"allowAll": true}), "allowAll").unwrap(),
            Some(true)
        );
        assert_eq!(
            optional_permission_mode(&json!({"permissionMode": "bypassPermissions"})).unwrap(),
            Some("bypassPermissions".into())
        );
        assert_eq!(
            optional_permission_mode(&json!({"permissionMode": "unbounded"}))
                .unwrap_err()
                .code,
            "invalid_request"
        );
        assert!(validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({
                "agentId": "worker",
                "role": "worker",
                "prompt": "do the task",
                "allowAll": true,
                "permissionMode": "acceptEdits"
            })
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({"agentId": "worker", "role": "worker", "prompt": "do the task", "allowAll": "true"})
        ));
    }

    #[test]
    fn fallback_candidates_are_bounded_unique_and_new_turn_only() {
        let arguments = json!({
            "agentId": "claude-code",
            "model": "primary",
            "fallbackCandidates": [
                {"agentId": "cursor", "model": "peer"},
                {"agentId": "antigravity", "model": "peer"}
            ]
        });
        assert_eq!(dispatch_candidates(&arguments, false).unwrap().len(), 3);
        assert_eq!(
            dispatch_candidates(&arguments, true).unwrap_err().code,
            "invalid_request"
        );
        let duplicate = json!({
            "agentId": "cursor",
            "model": "peer",
            "fallbackCandidates": [{"agentId": "cursor", "model": "peer"}]
        });
        assert_eq!(
            dispatch_candidates(&duplicate, false).unwrap_err().code,
            "invalid_request"
        );
    }

    #[test]
    fn only_quota_rate_limit_and_capacity_codes_trigger_fallback() {
        for code in [
            "quota_exhausted",
            "insufficient_credits",
            "rate_limited",
            "provider_capacity_exhausted",
        ] {
            assert!(quota_or_capacity_failure(&json!({"error": {"code": code}})));
        }
        for code in [
            "authorization_denied",
            "invalid_config",
            "model_not_found",
            "ordinary_failure",
        ] {
            assert!(!quota_or_capacity_failure(
                &json!({"error": {"code": code}})
            ));
        }
    }
}
