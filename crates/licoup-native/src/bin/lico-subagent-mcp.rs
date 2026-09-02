use interprocess::local_socket::{Stream, traits::Stream as _};
use licoup_native::{
    domain::{
        adaptive_flywheel::{WorkflowDiagnosticCode, WorkflowDiagnosticRecovery},
        client_conversation::{
            ConversationService, DispatchSessionMode, MembershipStatus,
            PERSISTENT_TRANSPORT_REQUIRED, PrincipalKind,
        },
        conversations, targets,
    },
    platform::{conversation_host_transport, paths},
};
use serde_json::{Map, Value, json};
use std::{
    collections::{HashMap, HashSet},
    io::{self, BufRead, Read, Write},
    process::ExitCode,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender, TrySendError},
    },
    thread,
    time::{Duration, Instant},
};

const MCP_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "lico-up-subagents";
const SERVER_VERSION: &str = "0.11.0";
const MAX_MCP_FRAME_BYTES: usize = 64 * 1024;
const MAX_PENDING_TOOL_CALLS: usize = 32;
const MAX_TOOL_WORKERS: usize = 8;
const MAX_PROMPT_BYTES: usize = 48 * 1024;
const MAX_ID_BYTES: usize = 256;
const MAX_WORKING_DIRECTORY_BYTES: usize = 4096;
const MIN_SUBAGENT_TIMEOUT_MS: u64 = 1_000;
const MAX_SUBAGENT_TIMEOUT_MS: u64 = 30 * 60 * 1_000;
const MIN_SUBAGENT_STDOUT_BYTES: u64 = 64 * 1024;
const MAX_SUBAGENT_STDOUT_BYTES: u64 = 64 * 1024 * 1024;
const MIN_SUBAGENT_STDERR_BYTES: u64 = 16 * 1024;
const MAX_SUBAGENT_STDERR_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
struct DispatchCandidate {
    agent_id: String,
    model: Option<String>,
    reasoning_effort: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ConversationDispatchContext {
    conversation_id: String,
    membership_id: String,
    candidate: DispatchCandidate,
}

fn main() -> ExitCode {
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
        let conversation_service = Arc::new(Mutex::new(None));
        let mut workers = Vec::with_capacity(MAX_TOOL_WORKERS);
        for _ in 0..MAX_TOOL_WORKERS {
            let receiver = Arc::clone(&receiver);
            let output = Arc::clone(&output);
            let cancellations = Arc::clone(&cancellations);
            let manager_agent_id = Arc::clone(&manager_agent_id);
            let conversation_service = Arc::clone(&conversation_service);
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
                            Arc::clone(&conversation_service),
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
    conversation_service: Arc<Mutex<Option<ConversationService>>>,
) -> Value {
    let result = execute_tool_inner(manager_agent_id, name, arguments, &conversation_service);
    if cancelled.load(Ordering::Acquire) {
        return rpc_error(id, -32800);
    }
    match result {
        Ok(value) => rpc_success(id, tool_success(value)),
        Err(error) => rpc_success(id, tool_error(&error)),
    }
}

fn execute_tool_inner(
    manager_agent_id: &str,
    name: &str,
    arguments: &Value,
    conversation_service: &Mutex<Option<ConversationService>>,
) -> Result<Value, ToolFailure> {
    match name {
        "lico_assistant_profiles" => {
            ensure_manager_bound(manager_agent_id)?;
            let service = shared_conversation_service(conversation_service)?;
            assistant_profiles(&service, manager_agent_id, arguments)
        }
        "lico_assistant_workflow_execute" => {
            ensure_manager_bound(manager_agent_id)?;
            let service = shared_conversation_service(conversation_service)?;
            assistant_workflow_execute(&service, manager_agent_id, arguments)
        }
        "lico_assistant_workflow_inspect" => {
            ensure_manager_bound(manager_agent_id)?;
            let service = shared_conversation_service(conversation_service)?;
            assistant_workflow_inspect(&service, manager_agent_id, arguments)
        }
        "lico_assistant_workflow_cancel" => {
            ensure_manager_bound(manager_agent_id)?;
            let service = shared_conversation_service(conversation_service)?;
            assistant_workflow_cancel(&service, manager_agent_id, arguments)
        }
        "lico_subagents_list" => list_subagents(manager_agent_id),
        "lico_subagent_probe" => probe_subagent(manager_agent_id, arguments),
        "lico_subagent_delegate" => {
            let service = shared_conversation_service(conversation_service)?;
            dispatch_subagent(&service, manager_agent_id, arguments, false)
        }
        "lico_subagent_continue" => {
            let service = shared_conversation_service(conversation_service)?;
            dispatch_subagent(&service, manager_agent_id, arguments, true)
        }
        "lico_subagent_cancel" => {
            let service = shared_conversation_service(conversation_service)?;
            cancel_subagent(&service, manager_agent_id, arguments)
        }
        _ => Err(ToolFailure::new("invalid_request", false)),
    }
}

/// Open the single process-owned Conversation service once and clone it for
/// every call, so all tool workers and spawned dispatch threads reuse one
/// bounded SQLite pool instead of opening per-call connections.
fn shared_conversation_service(
    slot: &Mutex<Option<ConversationService>>,
) -> Result<ConversationService, ToolFailure> {
    let mut guard = slot.lock().unwrap_or_else(|poison| poison.into_inner());
    match guard.as_ref() {
        Some(service) => Ok(service.clone()),
        None => {
            let portable = paths::portable_data_dir()
                .map_err(|_| ToolFailure::new("conversation_state_unavailable", true))?;
            let service = ConversationService::open(&portable)
                .map_err(|_| ToolFailure::new("conversation_state_unavailable", true))?;
            *guard = Some(service.clone());
            Ok(service)
        }
    }
}

/// Read-only readiness observation for one admitted local Agent integration.
/// The receipt is derived only from target facts, host reachability, and the
/// host turn snapshot: no Agent input is sent, no third-party Agent binary is
/// started, and no Conversation is created or mutated on this path.
fn probe_subagent(manager_agent_id: &str, arguments: &Value) -> Result<Value, ToolFailure> {
    ensure_manager_bound(manager_agent_id)?;
    let requested_agent_id = required_text(arguments, "agentId", MAX_ID_BYTES)?;
    let inspected = targets::inspect_target_read_only(&requested_agent_id)
        .map_err(|_| ToolFailure::new("subagent_unavailable", false))?;
    let target = inspected
        .get("target")
        .ok_or(ToolFailure::new("subagent_unavailable", false))?;
    if !subordinate_is_available(target) {
        return Err(ToolFailure::new("subagent_unavailable", false));
    }
    let agent_id = exact_readiness_agent_id(&requested_agent_id, target)?;
    let snapshot = execute_read_only_persistent_conversation_method(
        "agent.conversation.active",
        &readiness_observation_request(agent_id),
    )?;
    let active_turns = snapshot
        .get("turns")
        .and_then(Value::as_array)
        .map(Vec::len)
        .ok_or(ToolFailure::new("subagent_transport_failed", true))?;
    Ok(readiness_receipt(agent_id, target, active_turns))
}

fn exact_readiness_agent_id<'a>(
    requested_agent_id: &str,
    target: &'a Value,
) -> Result<&'a str, ToolFailure> {
    let agent_id = target
        .get("target")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(ToolFailure::new("subagent_unavailable", false))?;
    if agent_id != requested_agent_id {
        return Err(ToolFailure::new("invalid_request", false));
    }
    Ok(agent_id)
}

/// Build the single bounded read-only host observation for one Agent: the
/// active-turn snapshot filtered by that Agent with zero change-wait. The
/// request carries only the Agent filter and the change-wait bound; it never
/// dispatches a turn.
fn readiness_observation_request(agent_id: &str) -> Value {
    json!({
        "agent": agent_id,
        "waitForChangeMs": 0,
    })
}

/// An occupied Agent is a successful observation, never a failure: one or
/// more non-terminal host turns classify as busy, an empty snapshot as ready.
fn readiness_state(active_turns: usize) -> &'static str {
    if active_turns == 0 { "ready" } else { "busy" }
}

/// Project the readiness receipt from already-read target facts and the host
/// turn count. The receipt carries no path, session identifier, turn handle,
/// process identifier, port, model, price, or cleanup verdict. The host
/// snapshot covers only LicoUp-owned turns, so `ready` means admitted,
/// reachable, and idle inside LicoUp; it makes no claim about the Agent's own
/// external activity.
fn readiness_receipt(agent_id: &str, target: &Value, active_turns: usize) -> Value {
    json!({
        "schemaVersion": "licoup.subagent.readiness.v1",
        "operation": "subagent.readiness",
        "agentId": agent_id,
        "state": readiness_state(active_turns),
        "integrationStatus": target
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
        "conversationDriver": target
            .pointer("/adapterCapabilities/conversationDriver")
            .and_then(Value::as_str)
            .unwrap_or("unsupported"),
        "conversationReadiness": target
            .pointer("/adapterCapabilities/conversationReadiness")
            .and_then(Value::as_str)
            .unwrap_or("unverified"),
        "blockerCode": target
            .pointer("/adapterCapabilities/conversationBlocker")
            .and_then(Value::as_str),
        "hostTransport": conversation_host_transport::STDIO_RPC_PROTOCOL,
        "hostActiveTurns": active_turns,
    })
}

/// Rank active Agent Membership Profile candidates for one canonical
/// Conversation under the submitted filters. Only allowlisted candidate
/// facts and the route receipt leave this boundary.
fn assistant_profiles(
    service: &ConversationService,
    manager_agent_id: &str,
    arguments: &Value,
) -> Result<Value, ToolFailure> {
    let conversation_id = required_text(arguments, "conversationId", MAX_ID_BYTES)?;
    ensure_designated_assistant_manager(service, manager_agent_id, &conversation_id, None)?;
    let filters = arguments
        .get("filters")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let value = service
        .execute(json!({
            "action": "conversation.profile.candidates",
            "conversationId": conversation_id,
            "filters": filters,
        }))
        .map_err(project_conversation_service_failure)?;
    Ok(value)
}

/// Project one bounded Conversation service failure into a stable MCP code.
/// Raw database messages, paths and adapter details never cross the owner.
fn project_conversation_service_failure(error: anyhow::Error) -> ToolFailure {
    let code = error.to_string();
    let code = code.split(':').next().unwrap_or("").trim();
    let code = match code {
        "conversation_not_found"
        | "membership_not_found"
        | "profile_intent_invalid"
        | "profile_revision_stale"
        | "profile_candidate_rejected"
        | "invalid_request" => code,
        _ => "conversation_state_unavailable",
    };
    ToolFailure::new(code, code == "conversation_state_unavailable")
}

/// Build the bounded strategy request for one Assistant Graph tool from the
/// already-validated MCP arguments. No field outside the tool schema is
/// forwarded to the persistent host.
fn assistant_workflow_request(action: &str, arguments: &Value) -> Value {
    let mut request = json!({ "action": action });
    for key in [
        "conversationId",
        "membershipId",
        "workflow",
        "bindings",
        "filters",
        "input",
        "idempotencyKey",
        "runId",
    ] {
        if let Some(value) = arguments.get(key) {
            request[key] = value.clone();
        }
    }
    request
}

/// Project one rejected Assistant Graph into a stable MCP code. The host
/// rejection already carries only stable codes and membership identifiers.
fn project_graph_rejection(source: &Value) -> ToolFailure {
    let code = source
        .pointer("/error/code")
        .and_then(Value::as_str)
        .filter(|code| {
            matches!(
                *code,
                "graph_invalid" | "graph_preflight_rejected" | "graph_identity_rejected"
            )
        })
        .unwrap_or("graph_preflight_rejected");
    let diagnostics = source
        .pointer("/error/diagnostics")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|diagnostic| {
            let code = diagnostic.get("code").and_then(Value::as_str)?;
            let stage = diagnostic.get("stage").and_then(Value::as_str)?;
            if !workflow_diagnostic_code_allowed(code) {
                return None;
            }
            if !matches!(
                stage,
                "workflow/parse"
                    | "workflow/compile"
                    | "package/validate"
                    | "assistant-workflow/preflight"
                    | "assistant-workflow/revalidate"
            ) {
                return None;
            }
            if code == WorkflowDiagnosticCode::WorkflowSyntaxInvalid.wire() {
                if stage != "workflow/parse" {
                    return None;
                }
                let mut projected = json!({"code": code, "stage": stage});
                for key in ["line", "column"] {
                    if let Some(value) = diagnostic.get(key).and_then(Value::as_u64) {
                        projected[key] = json!(value);
                    }
                }
                return Some(projected);
            }
            let recovery = diagnostic
                .get("recovery")
                .and_then(Value::as_str)
                .filter(|value| workflow_diagnostic_recovery_allowed(value))?;
            let mut projected = json!({
                "code": code,
                "stage": stage,
                "recovery": recovery,
            });
            if let Some(pointer) = diagnostic
                .get("path")
                .and_then(Value::as_str)
                .filter(|pointer| valid_workflow_json_pointer(pointer))
            {
                projected["path"] = json!(pointer);
            }
            if let Some(paths) = diagnostic.get("relatedPaths").and_then(Value::as_array) {
                let paths = paths
                    .iter()
                    .filter_map(Value::as_str)
                    .filter(|pointer| valid_workflow_json_pointer(pointer))
                    .take(8)
                    .collect::<Vec<_>>();
                if !paths.is_empty() {
                    projected["relatedPaths"] = json!(paths);
                }
            }
            if stage.starts_with("assistant-workflow/")
                && let Some(membership_id) = diagnostic
                    .get("membershipId")
                    .and_then(Value::as_str)
                    .filter(|value| valid_diagnostic_identifier(value))
            {
                projected["membershipId"] = json!(membership_id);
            }
            for key in ["actual", "limit"] {
                if let Some(value) = diagnostic.get(key).and_then(Value::as_u64) {
                    projected[key] = json!(value);
                }
            }
            for (key, allowed) in [
                (
                    "expected",
                    &[
                        "object",
                        "array",
                        "string",
                        "integer",
                        "boolean",
                        "enum_value",
                        "identifier",
                        "non_empty_text",
                        "unique_id",
                        "existing_reference",
                        "supported_schema",
                        "valid_routing",
                        "valid_topology",
                    ][..],
                ),
                (
                    "actualKind",
                    &[
                        "missing", "null", "object", "array", "string", "number", "boolean",
                    ][..],
                ),
            ] {
                if let Some(value) = diagnostic
                    .get(key)
                    .and_then(Value::as_str)
                    .filter(|value| allowed.contains(value))
                {
                    projected[key] = json!(value);
                }
            }
            Some(projected)
        })
        .take(128)
        .collect();
    ToolFailure {
        code: code.to_owned(),
        stage: "assistant-workflow/preflight".to_owned(),
        retryable: true,
        recovery: "correct_graph_or_bindings_and_retry".to_owned(),
        diagnostics,
    }
}

fn workflow_diagnostic_code_allowed(code: &str) -> bool {
    WorkflowDiagnosticCode::from_wire(code).is_some()
}

fn workflow_diagnostic_recovery_allowed(value: &str) -> bool {
    serde_json::from_value::<WorkflowDiagnosticRecovery>(json!(value)).is_ok()
}

fn valid_workflow_json_pointer(pointer: &str) -> bool {
    if pointer.is_empty() {
        return true;
    }
    if pointer.len() > 256 || !pointer.starts_with('/') {
        return false;
    }
    let bytes = pointer.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'~' {
            index += 1;
            if index == bytes.len() || !matches!(bytes[index], b'0' | b'1') {
                return false;
            }
        }
        index += 1;
    }
    true
}

fn valid_diagnostic_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_ID_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'.' | b'_' | b'-'))
}

/// Compile, preflight, durably admit and execute one Assistant-temporary Graph
/// under exact Membership bindings. Replay of an existing idempotency key
/// returns the same durable run without duplicating effects.
fn assistant_workflow_execute(
    service: &ConversationService,
    manager_agent_id: &str,
    arguments: &Value,
) -> Result<Value, ToolFailure> {
    let conversation_id = required_text(arguments, "conversationId", MAX_ID_BYTES)?;
    let membership_id = required_text(arguments, "membershipId", MAX_ID_BYTES)?;
    ensure_designated_assistant_manager(
        service,
        manager_agent_id,
        &conversation_id,
        Some(&membership_id),
    )?;
    let request = assistant_workflow_request("strategy.assistant.workflow.execute", arguments);
    let value = execute_persistent_conversation_method("strategy.execute", &request)?;
    if value.get("accepted").and_then(Value::as_bool) == Some(false) {
        return Err(project_graph_rejection(&value));
    }
    Ok(value)
}

/// Read the projected state of one Assistant-temporary Graph run.
fn assistant_workflow_inspect(
    service: &ConversationService,
    manager_agent_id: &str,
    arguments: &Value,
) -> Result<Value, ToolFailure> {
    let request = assistant_workflow_request("strategy.assistant.workflow.inspect", arguments);
    let value = execute_persistent_conversation_method("strategy.execute", &request)?;
    ensure_assistant_run_manager(service, manager_agent_id, &value)?;
    Ok(value)
}

/// Request cancellation of one Assistant-temporary Graph run.
fn assistant_workflow_cancel(
    service: &ConversationService,
    manager_agent_id: &str,
    arguments: &Value,
) -> Result<Value, ToolFailure> {
    let inspect = assistant_workflow_request("strategy.assistant.workflow.inspect", arguments);
    let current = execute_persistent_conversation_method("strategy.execute", &inspect)?;
    ensure_assistant_run_manager(service, manager_agent_id, &current)?;
    let request = assistant_workflow_request("strategy.assistant.workflow.cancel", arguments);
    execute_persistent_conversation_method("strategy.execute", &request)
}

/// Bind every Assistant facade operation to the exact active designated
/// Membership owned by this MCP process. Opaque identifiers are checked
/// locally and no Conversation content crosses this boundary.
fn ensure_designated_assistant_manager(
    service: &ConversationService,
    manager_agent_id: &str,
    conversation_id: &str,
    expected_membership_id: Option<&str>,
) -> Result<String, ToolFailure> {
    let conversation = service
        .store()
        .get(conversation_id)
        .map_err(|_| ToolFailure::new("assistant_membership_not_authorized", false))?;
    let assistant_membership_id = conversation
        .assistant_membership_id
        .as_deref()
        .filter(|membership_id| {
            expected_membership_id.is_none_or(|expected| expected == *membership_id)
        })
        .ok_or(ToolFailure::new(
            "assistant_membership_not_authorized",
            false,
        ))?;
    let authorized = conversation.memberships.iter().any(|membership| {
        membership.id == assistant_membership_id
            && membership.status == MembershipStatus::Active
            && membership.principal.kind == PrincipalKind::Agent
            && membership.principal.agent_id.as_deref() == Some(manager_agent_id)
    });
    if !authorized {
        return Err(ToolFailure::new(
            "assistant_membership_not_authorized",
            false,
        ));
    }
    Ok(assistant_membership_id.to_owned())
}

fn ensure_assistant_run_manager(
    service: &ConversationService,
    manager_agent_id: &str,
    projection: &Value,
) -> Result<(), ToolFailure> {
    let conversation_id = projection
        .get("conversationId")
        .and_then(Value::as_str)
        .ok_or(ToolFailure::new(
            "assistant_membership_not_authorized",
            false,
        ))?;
    let membership_id = projection
        .get("assistantMembershipId")
        .and_then(Value::as_str)
        .ok_or(ToolFailure::new(
            "assistant_membership_not_authorized",
            false,
        ))?;
    ensure_designated_assistant_manager(
        service,
        manager_agent_id,
        conversation_id,
        Some(membership_id),
    )?;
    Ok(())
}

#[derive(Clone, Debug)]
struct ToolFailure {
    code: String,
    stage: String,
    retryable: bool,
    recovery: String,
    diagnostics: Vec<Value>,
}

impl ToolFailure {
    fn new(code: impl Into<String>, retryable: bool) -> Self {
        Self {
            code: code.into(),
            stage: "subagent-mcp".to_owned(),
            retryable,
            recovery: if retryable {
                "retry_after_recovery"
            } else {
                "correct_request_and_retry"
            }
            .to_owned(),
            diagnostics: Vec::new(),
        }
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
    Ok(json!({
        "schemaVersion": "licoup.subagents.v2",
        "managerAgentId": manager_agent_id,
        "subagents": subagents,
        "count": subagents.len()
    }))
}

fn dispatch_subagent(
    service: &ConversationService,
    manager_agent_id: &str,
    arguments: &Value,
    continuing: bool,
) -> Result<Value, ToolFailure> {
    ensure_manager_bound(manager_agent_id)?;
    let prompt = required_text(arguments, "prompt", MAX_PROMPT_BYTES)?;
    let context = conversation_dispatch_context(service, manager_agent_id, arguments)?;
    let candidates = [context.candidate.clone()];
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
    let session_mode = if continuing {
        DispatchSessionMode::Resume
    } else {
        DispatchSessionMode::New
    };
    let mut continuation = None;
    if session_mode == DispatchSessionMode::Resume {
        let previous = service
            .store()
            .latest_resumable_dispatch(&context.conversation_id, &context.membership_id)
            .map_err(|_| ToolFailure::new("conversation_state_unavailable", true))?
            .ok_or(ToolFailure::new("subagent_resume_unavailable", false))?;
        let conversation_path = previous
            .runtime_conversation_path
            .ok_or(ToolFailure::new("subagent_resume_unavailable", false))?;
        let resume_target = resume_target_for_path(&candidates[0].agent_id, &conversation_path)?;
        working_directory = Some(continuation_working_directory(
            working_directory,
            resume_target.working_directory.as_deref(),
        )?);
        continuation = Some((resume_target.session_id, conversation_path));
    }
    // Validate the membership-derived candidate before ACK so invalid requests fail closed.
    let first = &context.candidate;
    let inspected = ensure_subordinate_available(&first.agent_id)?;
    validate_dispatch_selection(first, &inspected)?;

    let operation = if session_mode == DispatchSessionMode::Resume {
        "subagent.continue"
    } else {
        "subagent.delegate"
    };
    let mut params = json!({
        "agent": first.agent_id.clone(),
        "agentId": first.agent_id.clone(),
        "text": prompt,
        "streamEvents": true,
        "timeoutMs": timeout_ms.unwrap_or(0),
        "conversationId": context.conversation_id.clone(),
        "membershipId": context.membership_id.clone(),
        "causationId": operation,
    });
    if let Some(model) = &first.model {
        params["model"] = json!(model);
    }
    if let Some(reasoning) = &first.reasoning_effort {
        params["reasoningEffort"] = json!(reasoning);
    }
    if let Some(working_directory) = &working_directory {
        params["workingDirectory"] = json!(working_directory);
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
    if let Some(permission_mode) = &permission_mode {
        params["permissionMode"] = json!(permission_mode);
    }
    if let Some((session_id, source_path)) = &continuation {
        params["sessionId"] = json!(session_id);
        params["sourcePath"] = json!(source_path);
    }

    // The persistent host opens the dispatch and records acceptance before
    // this ACK is returned, then remains the sole execution and completion
    // owner. The MCP process never creates a parallel turn registry or
    // terminal writer.
    let accepted = execute_persistent_conversation_method("agent.conversation.dispatch", &params)?;
    let dispatch_id = accepted
        .get("turnHandle")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(ToolFailure::new("conversation_state_unavailable", true))?
        .to_owned();
    if accepted.get("accepted").and_then(Value::as_bool) != Some(true)
        || accepted.get("conversationId").and_then(Value::as_str)
            != Some(context.conversation_id.as_str())
        || accepted.get("membershipId").and_then(Value::as_str)
            != Some(context.membership_id.as_str())
    {
        return Err(ToolFailure::new("conversation_state_unavailable", true));
    }
    let receipt = json!({
        "schemaVersion": "licoup.subagent.receipt.v2",
        "operation": operation,
        "agentId": first.agent_id,
        "conversationId": context.conversation_id,
        "membershipId": context.membership_id,
        "state": "accepted",
        "dispatchId": dispatch_id,
        "sessionMode": session_mode.as_str(),
        "accepted": true,
    });
    Ok(receipt)
}

/// Execute one bounded read-only request against an already-published
/// Conversation host endpoint. A missing endpoint is observed as unavailable;
/// this path never creates its identity.
fn execute_read_only_persistent_conversation_method(
    method: &str,
    params: &Value,
) -> Result<Value, ToolFailure> {
    execute_persistent_conversation_method_with_connector(
        method,
        params,
        conversation_host_transport::connect_existing,
    )
    .map_err(project_readiness_transport_failure)
}

fn project_readiness_transport_failure(error: ToolFailure) -> ToolFailure {
    match error.code.as_str() {
        "invalid_request" | PERSISTENT_TRANSPORT_REQUIRED | "subagent_transport_failed" => error,
        _ => ToolFailure::new("subagent_transport_failed", true),
    }
}

fn execute_persistent_conversation_method(
    method: &str,
    params: &Value,
) -> Result<Value, ToolFailure> {
    execute_persistent_conversation_method_with_connector(
        method,
        params,
        conversation_host_transport::connect,
    )
}

fn execute_persistent_conversation_method_with_connector(
    method: &str,
    params: &Value,
    connect: fn() -> io::Result<Stream>,
) -> Result<Value, ToolFailure> {
    const RESPONSE_LIMIT: usize = 64 * 1024;
    const IO_WAIT: Duration = Duration::from_secs(3);

    let mut stream =
        connect().map_err(|_| ToolFailure::new(PERSISTENT_TRANSPORT_REQUIRED, true))?;
    stream
        .set_nonblocking(true)
        .map_err(|_| ToolFailure::new("subagent_transport_failed", true))?;
    let request_id = format!("subagent-{}", uuid::Uuid::new_v4().simple());
    let workflow_id = request_id.clone();
    let mut encoded = serde_json::to_vec(&json!({
        "protocol": conversation_host_transport::STDIO_RPC_PROTOCOL,
        "id": request_id.clone(),
        "workflowId": workflow_id.clone(),
        "method": method,
        "params": params,
    }))
    .map_err(|_| ToolFailure::new("subagent_transport_failed", true))?;
    encoded.push(b'\n');
    if encoded.len() > RESPONSE_LIMIT {
        return Err(ToolFailure::new("invalid_request", false));
    }

    let deadline = Instant::now() + IO_WAIT;
    let mut written = 0;
    while written < encoded.len() {
        if Instant::now() >= deadline {
            return Err(ToolFailure::new("subagent_transport_failed", true));
        }
        match stream.write(&encoded[written..]) {
            Ok(0) => return Err(ToolFailure::new("subagent_transport_failed", true)),
            Ok(count) => written += count,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                thread::sleep(Duration::from_millis(5));
            }
            Err(_) => return Err(ToolFailure::new("subagent_transport_failed", true)),
        }
    }
    stream
        .flush()
        .map_err(|_| ToolFailure::new("subagent_transport_failed", true))?;

    let mut response = Vec::with_capacity(1024);
    let mut buffer = [0_u8; 4096];
    loop {
        if Instant::now() >= deadline || response.len() >= RESPONSE_LIMIT {
            return Err(ToolFailure::new("subagent_transport_failed", true));
        }
        match stream.read(&mut buffer) {
            Ok(0) => return Err(ToolFailure::new("subagent_transport_failed", true)),
            Ok(count) => {
                response.extend_from_slice(&buffer[..count]);
                if let Some(end) = response.iter().position(|byte| *byte == b'\n') {
                    response.truncate(end);
                    break;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                thread::sleep(Duration::from_millis(5));
            }
            Err(_) => return Err(ToolFailure::new("subagent_transport_failed", true)),
        }
    }

    let frame: Value = serde_json::from_slice(&response)
        .map_err(|_| ToolFailure::new("subagent_transport_failed", true))?;
    if frame.get("protocol").and_then(Value::as_str)
        != Some(conversation_host_transport::STDIO_RPC_PROTOCOL)
        || frame.get("id").and_then(Value::as_str) != Some(request_id.as_str())
        || frame.get("workflowId").and_then(Value::as_str) != Some(workflow_id.as_str())
    {
        return Err(ToolFailure::new("subagent_transport_failed", true));
    }
    if frame.get("ok").and_then(Value::as_bool) != Some(true) {
        let error = frame.get("error").unwrap_or(&frame);
        let code = error
            .get("code")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or("subagent_transport_failed");
        let retryable = error
            .get("retryable")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        return Err(ToolFailure::new(code, retryable));
    }
    let result = frame
        .get("result")
        .cloned()
        .ok_or(ToolFailure::new("subagent_transport_failed", true))?;
    if result.get("ok").and_then(Value::as_bool) == Some(false) {
        let error = result.get("error").unwrap_or(&result);
        let code = error
            .get("code")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or("subagent_transport_failed");
        return Err(ToolFailure::new(code, true));
    }
    Ok(result)
}

fn conversation_dispatch_context(
    service: &ConversationService,
    manager_agent_id: &str,
    arguments: &Value,
) -> Result<ConversationDispatchContext, ToolFailure> {
    let conversation_id = required_text(arguments, "conversationId", MAX_ID_BYTES)?;
    let membership_id = required_text(arguments, "membershipId", MAX_ID_BYTES)?;
    let conversation = service
        .store()
        .get(&conversation_id)
        .map_err(|_| ToolFailure::new("conversation_not_found", false))?;
    if !conversation.memberships.iter().any(|membership| {
        membership.status == MembershipStatus::Active
            && membership.principal.kind == PrincipalKind::Agent
            && membership.principal.agent_id.as_deref() == Some(manager_agent_id)
    }) {
        return Err(ToolFailure::new("conversation_access_denied", false));
    }
    let membership = conversation
        .memberships
        .iter()
        .find(|membership| membership.id == membership_id)
        .filter(|membership| membership.status == MembershipStatus::Active)
        .filter(|membership| membership.principal.kind == PrincipalKind::Agent)
        .ok_or(ToolFailure::new("membership_not_runnable", false))?;
    let agent_id = membership
        .principal
        .agent_id
        .as_deref()
        .filter(|agent_id| !agent_id.trim().is_empty())
        .ok_or(ToolFailure::new("membership_not_runnable", false))?
        .to_owned();
    Ok(ConversationDispatchContext {
        conversation_id,
        membership_id,
        candidate: DispatchCandidate {
            agent_id,
            model: optional_text(arguments, "model", MAX_ID_BYTES)?,
            reasoning_effort: optional_text(arguments, "reasoningEffort", 32)?,
        },
    })
}

fn cancel_subagent(
    service: &ConversationService,
    manager_agent_id: &str,
    arguments: &Value,
) -> Result<Value, ToolFailure> {
    ensure_manager_bound(manager_agent_id)?;
    let context = conversation_dispatch_context(service, manager_agent_id, arguments)?;
    let agent_id = context.candidate.agent_id;
    let _ = ensure_subordinate_available(&agent_id)?;
    let dispatch = service
        .store()
        .latest_resumable_dispatch(&context.conversation_id, &context.membership_id)
        .map_err(|_| ToolFailure::new("conversation_state_unavailable", true))?
        .ok_or(ToolFailure::new("subagent_cancel_unavailable", false))?;
    let value = execute_persistent_conversation_method(
        "agent.conversation.cancel",
        &json!({
            "turnHandle": dispatch.id.clone(),
            "conversationId": context.conversation_id.clone(),
            "agentId": agent_id.clone(),
        }),
    )?;
    if value.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(project_dispatch_failure(&agent_id, &value));
    }
    Ok(json!({
        "schemaVersion": "licoup.subagent.receipt.v2",
        "operation": "subagent.cancel",
        "agentId": agent_id,
        "conversationId": context.conversation_id,
        "membershipId": context.membership_id,
        "dispatchId": dispatch.id,
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct ConversationResumeTarget {
    session_id: String,
    working_directory: Option<String>,
}

#[cfg(test)]
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
    let _ = agent_id;
    ToolFailure::new(projected_code, retryable)
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

fn tool_catalog() -> Vec<Value> {
    vec![
        json!({
            "name": "lico_assistant_profiles",
            "description": "Rank active Agent Membership Profiles for one canonical Conversation and return a privacy-safe route receipt derived from existing fact owners.",
            "inputSchema": closed_object(
                &["conversationId"],
                json!({
                    "conversationId": bounded_string(MAX_ID_BYTES),
                    "filters": {"type": "object"}
                })
            )
        }),
        json!({
            "name": "lico_assistant_workflow_execute",
            "description": "Compile, preflight, durably admit and execute one Assistant-temporary workflow under exact Membership bindings and an idempotency key.",
            "inputSchema": closed_object(
                &["conversationId", "membershipId", "workflow", "bindings", "idempotencyKey"],
                json!({
                    "conversationId": bounded_string(MAX_ID_BYTES),
                    "membershipId": bounded_string(MAX_ID_BYTES),
                    "workflow": {"type": "object"},
                    "bindings": {"type": "array"},
                    "filters": {"type": "object"},
                    "input": {"type": "object"},
                    "idempotencyKey": bounded_string(MAX_ID_BYTES)
                })
            )
        }),
        json!({
            "name": "lico_assistant_workflow_inspect",
            "description": "Read the projected state of one Assistant-temporary workflow run.",
            "inputSchema": closed_object(
                &["runId"],
                json!({
                    "runId": bounded_string(MAX_ID_BYTES)
                })
            )
        }),
        json!({
            "name": "lico_assistant_workflow_cancel",
            "description": "Request cancellation of one Assistant-temporary workflow run.",
            "inputSchema": closed_object(
                &["runId"],
                json!({
                    "runId": bounded_string(MAX_ID_BYTES)
                })
            )
        }),
        json!({
            "name": "lico_subagents_list",
            "description": "List scanned runnable local Agent integrations. Conversation access and collaboration roles are managed separately by the canonical Conversation service.",
            "inputSchema": closed_object(&[], json!({}))
        }),
        json!({
            "name": "lico_subagent_probe",
            "description": "Read-only readiness observation for one admitted local Agent integration. It never sends Agent input, starts no third-party Agent binary, and creates or mutates no Conversation: the receipt is derived only from target facts, host reachability, and the private Conversation host's active-turn snapshot. busy is a successful observed state, not a failure. The snapshot covers only LicoUp-owned turns, so ready means admitted, reachable, and idle inside LicoUp.",
            "inputSchema": closed_object(
                &["agentId"],
                json!({
                    "agentId": bounded_string(MAX_ID_BYTES)
                })
            )
        }),
        json!({
            "name": "lico_subagent_delegate",
            "description": "Request one new Agent dispatch for an exact active Agent Membership in a canonical Conversation. Collaboration roles and Flywheel selection remain Conversation data, not MCP enums.",
            "inputSchema": closed_object(
                &["conversationId", "membershipId", "prompt"],
                json!({
                    "conversationId": bounded_string(MAX_ID_BYTES),
                    "membershipId": bounded_string(MAX_ID_BYTES),
                    "prompt": bounded_string(MAX_PROMPT_BYTES),
                    "model": bounded_string(MAX_ID_BYTES),
                    "reasoningEffort": bounded_string(32),
                    "workingDirectory": bounded_string(MAX_WORKING_DIRECTORY_BYTES),
                    "timeoutMs": bounded_integer(0, MAX_SUBAGENT_TIMEOUT_MS),
                    "maxStdoutBytes": bounded_integer(MIN_SUBAGENT_STDOUT_BYTES, MAX_SUBAGENT_STDOUT_BYTES),
                    "maxStderrBytes": bounded_integer(MIN_SUBAGENT_STDERR_BYTES, MAX_SUBAGENT_STDERR_BYTES),
                    "allowAll": {"type": "boolean"},
                    "permissionMode": permission_mode_schema()
                })
            )
        }),
        json!({
            "name": "lico_subagent_continue",
            "description": "Resume the latest completed dispatch for an exact active Agent Membership. Native runtime locations remain private Conversation state. Returns immediately with accepted+dispatchId.",
            "inputSchema": closed_object(
                &["conversationId", "membershipId", "prompt"],
                json!({
                    "conversationId": bounded_string(MAX_ID_BYTES),
                    "membershipId": bounded_string(MAX_ID_BYTES),
                    "prompt": bounded_string(MAX_PROMPT_BYTES),
                    "model": bounded_string(MAX_ID_BYTES),
                    "reasoningEffort": bounded_string(32),
                    "workingDirectory": bounded_string(MAX_WORKING_DIRECTORY_BYTES),
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
            "description": "Request cancellation of the latest completed dispatch for an exact active Agent Membership. Native runtime locations remain private Conversation state.",
            "inputSchema": closed_object(
                &["conversationId", "membershipId"],
                json!({
                    "conversationId": bounded_string(MAX_ID_BYTES),
                    "membershipId": bounded_string(MAX_ID_BYTES)
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

fn tool_names() -> &'static [&'static str] {
    &[
        "lico_assistant_profiles",
        "lico_assistant_workflow_execute",
        "lico_assistant_workflow_inspect",
        "lico_assistant_workflow_cancel",
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
        "lico_assistant_profiles" => &["conversationId", "filters"],
        "lico_assistant_workflow_execute" => &[
            "conversationId",
            "membershipId",
            "workflow",
            "bindings",
            "filters",
            "input",
            "idempotencyKey",
        ],
        "lico_assistant_workflow_inspect" | "lico_assistant_workflow_cancel" => &["runId"],
        "lico_subagents_list" => &[],
        "lico_subagent_probe" => &["agentId"],
        "lico_subagent_delegate" => &[
            "conversationId",
            "membershipId",
            "prompt",
            "model",
            "reasoningEffort",
            "workingDirectory",
            "timeoutMs",
            "maxStdoutBytes",
            "maxStderrBytes",
            "allowAll",
            "permissionMode",
        ],
        "lico_subagent_continue" => &[
            "conversationId",
            "membershipId",
            "prompt",
            "model",
            "reasoningEffort",
            "workingDirectory",
            "timeoutMs",
            "maxStdoutBytes",
            "maxStderrBytes",
            "allowAll",
            "permissionMode",
        ],
        "lico_subagent_cancel" => &["conversationId", "membershipId"],
        _ => return false,
    };
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return false;
    }
    match name {
        "lico_assistant_profiles" => {
            valid_required(object, "conversationId", MAX_ID_BYTES)
                && (object.get("filters").is_none()
                    || object.get("filters").is_some_and(Value::is_object))
        }
        "lico_assistant_workflow_execute" => {
            valid_required(object, "conversationId", MAX_ID_BYTES)
                && valid_required(object, "membershipId", MAX_ID_BYTES)
                && valid_required(object, "idempotencyKey", MAX_ID_BYTES)
                && object.get("workflow").is_some_and(Value::is_object)
                && object.get("bindings").is_some_and(Value::is_array)
                && (object.get("filters").is_none()
                    || object.get("filters").is_some_and(Value::is_object))
                && (object.get("input").is_none()
                    || object.get("input").is_some_and(Value::is_object))
        }
        "lico_assistant_workflow_inspect" | "lico_assistant_workflow_cancel" => {
            valid_required(object, "runId", MAX_ID_BYTES)
        }
        "lico_subagents_list" => object.is_empty(),
        "lico_subagent_probe" => valid_required(object, "agentId", MAX_ID_BYTES),
        "lico_subagent_delegate" => {
            valid_required(object, "conversationId", MAX_ID_BYTES)
                && valid_required(object, "membershipId", MAX_ID_BYTES)
                && valid_required(object, "prompt", MAX_PROMPT_BYTES)
                && valid_optional(object, "model", MAX_ID_BYTES)
                && valid_optional(object, "reasoningEffort", 32)
                && valid_optional(object, "workingDirectory", MAX_WORKING_DIRECTORY_BYTES)
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
        "lico_subagent_continue" => {
            valid_required(object, "conversationId", MAX_ID_BYTES)
                && valid_required(object, "membershipId", MAX_ID_BYTES)
                && valid_required(object, "prompt", MAX_PROMPT_BYTES)
                && valid_optional(object, "model", MAX_ID_BYTES)
                && valid_optional(object, "reasoningEffort", 32)
                && valid_optional(object, "workingDirectory", MAX_WORKING_DIRECTORY_BYTES)
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
            valid_required(object, "conversationId", MAX_ID_BYTES)
                && valid_required(object, "membershipId", MAX_ID_BYTES)
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
        "stage": error.stage,
        "retryable": error.retryable,
        "recovery": error.recovery
    });
    if !error.diagnostics.is_empty() {
        value["diagnostics"] = json!(error.diagnostics);
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
    use licoup_native::domain::client_conversation::{MembershipAccess, Principal};

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

    #[test]
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
    fn tool_surface_is_closed_and_contains_assistant_and_subagent_operations() {
        assert_eq!(
            tool_names(),
            &[
                "lico_assistant_profiles",
                "lico_assistant_workflow_execute",
                "lico_assistant_workflow_inspect",
                "lico_assistant_workflow_cancel",
                "lico_subagents_list",
                "lico_subagent_probe",
                "lico_subagent_delegate",
                "lico_subagent_continue",
                "lico_subagent_cancel",
            ]
        );
        assert!(validate_tool_arguments(
            "lico_assistant_profiles",
            &json!({"conversationId": "conversation:fixture", "filters": {"membershipIds": []}})
        ));
        assert!(validate_tool_arguments(
            "lico_assistant_workflow_execute",
            &json!({
                "conversationId": "conversation:fixture",
                "membershipId": "membership:assistant",
                "workflow": {"metadata": {"id": "assistant-temporary:fixture"}},
                "bindings": [],
                "input": {"message": "run"},
                "idempotencyKey": "assistant-graph-1"
            })
        ));
        assert!(validate_tool_arguments(
            "lico_assistant_workflow_inspect",
            &json!({"runId": "run:assistant-fixture"})
        ));
        assert!(validate_tool_arguments(
            "lico_assistant_workflow_cancel",
            &json!({"runId": "run:assistant-fixture"})
        ));
        assert!(!validate_tool_arguments("lico_subagent_probe", &json!({})));
        assert!(!validate_tool_arguments(
            "lico_assistant_workflow_execute",
            &json!({
                "conversationId": "conversation:fixture",
                "membershipId": "membership:assistant",
                "workflow": "not-an-object",
                "bindings": [],
                "idempotencyKey": "assistant-graph-1"
            })
        ));
        assert!(!validate_tool_arguments(
            "lico_assistant_workflow_execute",
            &json!({
                "conversationId": "conversation:fixture",
                "membershipId": "membership:assistant",
                "workflow": {"metadata": {"id": "assistant-temporary:fixture"}},
                "bindings": [],
                "idempotencyKey": "assistant-graph-1",
                "planRoot": "/fixture-root/plan"
            })
        ));
        assert!(!validate_tool_arguments(
            "lico_assistant_workflow_inspect",
            &json!({"runId": "run:assistant-fixture", "workflowId": "workflow:fixture"})
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_probe",
            &json!({"agentId": "worker", "workingDirectory": "/fixture-root/project"})
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_probe",
            &json!({"agentId": "worker", "exactModel": "kimi-code/k3"})
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_probe",
            &json!({
                "agentId": "worker",
                "exactModel": "kimi-code/k3",
                "exactReasoningEffort": "low"
            })
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_probe",
            &json!({"agentId": "worker", "timeoutMs": 120_000})
        ));
        assert!(validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({
                "conversationId": "conversation:fixture",
                "membershipId": "membership:worker",
                "prompt": "do the task"
            })
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({
                "conversationId": "conversation:fixture",
                "membershipId": "membership:worker",
                "role": "worker",
                "prompt": "do the task"
            })
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({
                "conversationId": "conversation:fixture",
                "membershipId": "membership:worker",
                "prompt": "do the task",
                "unexpected": true
            })
        ));
    }

    #[test]
    fn assistant_workflow_request_forwards_only_bounded_tool_fields() {
        let request = assistant_workflow_request(
            "strategy.assistant.workflow.execute",
            &json!({
                "conversationId": "conversation:fixture",
                "membershipId": "membership:assistant",
                "workflow": {"metadata": {"id": "assistant-temporary:fixture"}},
                "bindings": [{"ordinal": 0, "slotId": "review", "valueId": "membership:worker"}],
                "filters": {"membershipIds": ["membership:worker"]},
                "input": {"message": "run"},
                "idempotencyKey": "assistant-graph-1",
                "planRoot": "/fixture-root/plan"
            }),
        );
        let object = request.as_object().unwrap();
        assert_eq!(
            request["action"],
            json!("strategy.assistant.workflow.execute")
        );
        assert_eq!(request["conversationId"], json!("conversation:fixture"));
        assert_eq!(request["membershipId"], json!("membership:assistant"));
        assert_eq!(
            request["workflow"]["metadata"]["id"],
            json!("assistant-temporary:fixture")
        );
        assert_eq!(
            request["bindings"][0]["valueId"],
            json!("membership:worker")
        );
        assert_eq!(
            request["filters"]["membershipIds"][0],
            json!("membership:worker")
        );
        assert_eq!(request["input"]["message"], json!("run"));
        assert_eq!(request["idempotencyKey"], json!("assistant-graph-1"));
        assert!(!object.contains_key("planRoot"));
        assert_eq!(object.len(), 8);

        let inspect = assistant_workflow_request(
            "strategy.assistant.workflow.inspect",
            &json!({"runId": "run:assistant-fixture"}),
        );
        let inspect = inspect.as_object().unwrap();
        assert_eq!(inspect.len(), 2);
        assert_eq!(
            inspect["action"],
            json!("strategy.assistant.workflow.inspect")
        );
        assert_eq!(inspect["runId"], json!("run:assistant-fixture"));
    }

    #[test]
    fn conversation_failures_project_only_stable_codes() {
        let stale = project_conversation_service_failure(anyhow::anyhow!("profile_revision_stale"));
        assert_eq!(stale.code, "profile_revision_stale");
        assert!(!stale.retryable);
        let missing =
            project_conversation_service_failure(anyhow::anyhow!("conversation_not_found"));
        assert_eq!(missing.code, "conversation_not_found");
        let private = project_conversation_service_failure(anyhow::anyhow!(
            "conversation_database_open_failed: <user-home>/private.db"
        ));
        assert_eq!(private.code, "conversation_state_unavailable");
        assert!(private.retryable);
        assert!(!tool_error(&private).to_string().contains("<user-home>"));
    }

    #[test]
    fn assistant_and_direct_tools_are_bound_to_active_manager_membership() {
        let root = std::env::temp_dir().join(format!(
            "lico-subagent-mcp-membership-auth-{}",
            uuid::Uuid::new_v4()
        ));
        let service = ConversationService::open(&root).unwrap();
        let now = 1;
        let conversation = service
            .store()
            .create_conversation_with_members(
                "Membership authorization",
                Principal {
                    id: "human:owner".to_owned(),
                    kind: PrincipalKind::Human,
                    display_name: "Local owner".to_owned(),
                    agent_id: None,
                    created_at_unix_ms: now,
                },
                &[
                    (
                        Principal {
                            id: "agent:codex".to_owned(),
                            kind: PrincipalKind::Agent,
                            display_name: "Codex".to_owned(),
                            agent_id: Some("codex".to_owned()),
                            created_at_unix_ms: now,
                        },
                        MembershipAccess::Member,
                    ),
                    (
                        Principal {
                            id: "agent:kimi-code".to_owned(),
                            kind: PrincipalKind::Agent,
                            display_name: "Kimi Code".to_owned(),
                            agent_id: Some("kimi-code".to_owned()),
                            created_at_unix_ms: now,
                        },
                        MembershipAccess::Member,
                    ),
                ],
            )
            .unwrap();
        let owner_membership_id = conversation
            .memberships
            .iter()
            .find(|membership| membership.principal.kind == PrincipalKind::Human)
            .unwrap()
            .id
            .clone();
        let assistant_membership_id = conversation
            .memberships
            .iter()
            .find(|membership| membership.principal.agent_id.as_deref() == Some("codex"))
            .unwrap()
            .id
            .clone();
        let target_membership_id = conversation
            .memberships
            .iter()
            .find(|membership| membership.principal.agent_id.as_deref() == Some("kimi-code"))
            .unwrap()
            .id
            .clone();
        service
            .store()
            .set_conversation_assistant(
                &conversation.id,
                &owner_membership_id,
                conversation.revision,
                Some(&assistant_membership_id),
            )
            .unwrap();

        assert_eq!(
            ensure_designated_assistant_manager(&service, "codex", &conversation.id, None).unwrap(),
            assistant_membership_id
        );
        assert_eq!(
            ensure_designated_assistant_manager(
                &service,
                "kimi-code",
                &conversation.id,
                Some(&assistant_membership_id),
            )
            .unwrap_err()
            .code,
            "assistant_membership_not_authorized"
        );
        let arguments = json!({
            "conversationId": conversation.id,
            "membershipId": target_membership_id,
        });
        assert_eq!(
            conversation_dispatch_context(&service, "codex", &arguments)
                .unwrap()
                .candidate
                .agent_id,
            "kimi-code"
        );
        assert_eq!(
            conversation_dispatch_context(&service, "unrelated-agent", &arguments)
                .unwrap_err()
                .code,
            "conversation_access_denied"
        );
        drop(service);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn graph_rejections_keep_the_stable_preflight_code() {
        let failure = project_graph_rejection(&json!({
            "accepted": false,
            "error": {
                "code": "graph_preflight_rejected",
                "stage": "assistant-workflow/preflight",
                "diagnostics": [{
                    "code": "graph_membership_rejected",
                    "stage": "assistant-workflow/preflight",
                    "recovery": "update_binding",
                    "path": "/bindings/0/valueId",
                    "membershipId": "membership:worker"
                }]
            }
        }));
        assert_eq!(failure.code, "graph_preflight_rejected");
        assert!(failure.retryable);
        assert_eq!(failure.stage, "assistant-workflow/preflight");
        assert_eq!(failure.recovery, "correct_graph_or_bindings_and_retry");
        assert_eq!(
            failure.diagnostics,
            vec![json!({
                "code": "graph_membership_rejected",
                "stage": "assistant-workflow/preflight",
                "recovery": "update_binding",
                "path": "/bindings/0/valueId",
                "membershipId": "membership:worker"
            })]
        );
        assert_eq!(
            tool_error(&failure)["structuredContent"]["diagnostics"],
            json!(failure.diagnostics)
        );
        let fallback = project_graph_rejection(&json!({"accepted": false}));
        assert_eq!(fallback.code, "graph_preflight_rejected");
        assert!(fallback.diagnostics.is_empty());
    }

    #[test]
    fn readiness_observation_request_is_agent_scoped_and_input_free() {
        let request = readiness_observation_request("kimi-code");
        let object = request.as_object().unwrap();
        assert_eq!(request["agent"], json!("kimi-code"));
        assert_eq!(request["waitForChangeMs"], json!(0));
        assert_eq!(object.len(), 2);
        for retired in [
            "prompt",
            "text",
            "model",
            "reasoningEffort",
            "workingDirectory",
            "timeoutMs",
            "streamEvents",
        ] {
            assert!(!object.contains_key(retired), "{retired}");
        }
    }

    #[test]
    fn readiness_classification_treats_busy_as_a_successful_state() {
        assert_eq!(readiness_state(0), "ready");
        assert_eq!(readiness_state(1), "busy");
        assert_eq!(readiness_state(7), "busy");
    }

    #[test]
    fn readiness_requires_the_exact_admitted_agent_identifier() {
        let target = json!({"target": "kilo-code"});
        assert_eq!(
            exact_readiness_agent_id("kilo-code", &target).unwrap(),
            "kilo-code"
        );
        assert_eq!(
            exact_readiness_agent_id("kilo", &target).unwrap_err().code,
            "invalid_request"
        );
    }

    #[test]
    fn readiness_transport_errors_never_project_private_host_codes() {
        const PRIVATE_HOST_CODE: &str = "private-runtime-identifier";
        let projected =
            project_readiness_transport_failure(ToolFailure::new(PRIVATE_HOST_CODE, false));
        assert_eq!(projected.code, "subagent_transport_failed");
        assert!(projected.retryable);
        assert!(
            !tool_error(&projected)
                .to_string()
                .contains(PRIVATE_HOST_CODE)
        );

        let unavailable = project_readiness_transport_failure(ToolFailure::new(
            PERSISTENT_TRANSPORT_REQUIRED,
            true,
        ));
        assert_eq!(unavailable.code, PERSISTENT_TRANSPORT_REQUIRED);
    }

    #[test]
    fn readiness_receipt_projects_no_private_runtime_identifiers() {
        let target = json!({
            "target": "kimi-code",
            "status": "detected",
            "binaryPath": "<local-path>",
            "adapterCapabilities": {
                "conversationDriver": "native",
                "conversationReadiness": "ready"
            }
        });
        let receipt = readiness_receipt("kimi-code", &target, 2);
        assert_eq!(
            receipt["schemaVersion"],
            json!("licoup.subagent.readiness.v1")
        );
        assert_eq!(receipt["operation"], json!("subagent.readiness"));
        assert_eq!(receipt["agentId"], json!("kimi-code"));
        assert_eq!(receipt["state"], json!("busy"));
        assert_eq!(receipt["integrationStatus"], json!("detected"));
        assert_eq!(receipt["conversationDriver"], json!("native"));
        assert_eq!(receipt["conversationReadiness"], json!("ready"));
        assert_eq!(receipt["blockerCode"], Value::Null);
        assert_eq!(
            receipt["hostTransport"],
            json!(conversation_host_transport::STDIO_RPC_PROTOCOL)
        );
        assert_eq!(receipt["hostActiveTurns"], json!(2));
        let object = receipt.as_object().unwrap();
        assert_eq!(object.len(), 10);
        for forbidden in [
            "sessionId",
            "nativeSessionId",
            "turnHandle",
            "dispatchId",
            "sourcePath",
            "workingDirectory",
            "binaryPath",
            "pid",
            "port",
            "model",
            "reasoningEffort",
            "cleanupState",
        ] {
            assert!(!object.contains_key(forbidden), "{forbidden}");
        }
        assert!(!receipt.to_string().contains("<local-path>"));
        let idle = readiness_receipt("kimi-code", &target, 0);
        assert_eq!(idle["state"], json!("ready"));
        let blocked = readiness_receipt(
            "cursor",
            &json!({
                "target": "cursor",
                "status": "detected",
                "adapterCapabilities": {
                    "conversationDriver": "native",
                    "conversationReadiness": "unverified",
                    "conversationBlocker": "parity-evidence-stale"
                }
            }),
            0,
        );
        assert_eq!(blocked["blockerCode"], json!("parity-evidence-stale"));
        assert_eq!(blocked["state"], json!("ready"));
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
            "/fixture-root/sessions/rollout-2026-08-02T03-23-02-019fbec7-a57b-7612-b817-9c990936846d.jsonl",
        ));
        assert_eq!(
            codex.first().map(String::as_str),
            Some("019fbec7-a57b-7612-b817-9c990936846d")
        );
        let kimi = session_id_candidates(std::path::Path::new(
            "/fixture-root/sessions/session_5ba759f6-100a-4d23-ac3a-adbe0b66ed59/agents/main/wire.jsonl",
        ));
        assert!(
            kimi.iter()
                .any(|value| value == "session_5ba759f6-100a-4d23-ac3a-adbe0b66ed59")
        );
        assert!(
            session_id_candidates(std::path::Path::new("/fixture-root/opaque.jsonl")).len() <= 16
        );
    }

    #[test]
    fn exact_conversation_lookup_revalidates_the_full_source_path() {
        let expected = "/fixture-root/conversations/exact.jsonl";
        let response = json!({
            "sessions": [{
                "sourcePath": expected,
                "nativeSessionId": "native-exact",
                "workingDirectory": "/fixture-root/project"
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
                working_directory: Some("/fixture-root/project".into()),
            })
        );
        assert_eq!(
            exact_session_id_for_path(&response, "/fixture-root/conversations/other.jsonl")
                .unwrap(),
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
                "conversationId": "conversation:fixture",
                "membershipId": "membership:worker",
                "prompt": "do the task",
                "timeoutMs": 15 * 60 * 1_000
            })
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_continue",
            &json!({
                "conversationId": "conversation:fixture",
                "membershipId": "membership:worker",
                "conversationPath": "/fixture-root/conversation.jsonl",
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
                "conversationId": "conversation:fixture",
                "membershipId": "membership:worker",
                "prompt": "do the task",
                "maxStdoutBytes": 8 * 1024 * 1024,
                "maxStderrBytes": 1024 * 1024
            })
        ));
    }

    #[test]
    fn recoverable_failures_never_return_private_runtime_locations() {
        let error = ToolFailure::new("subagent_output_limit", true);
        let projected = tool_error(&error);
        assert_eq!(
            projected["structuredContent"]["reasonCode"],
            "subagent_output_limit"
        );
        assert_eq!(projected["structuredContent"]["retryable"], true);
        assert!(
            projected["structuredContent"]
                .get("conversationPath")
                .is_none()
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
                "conversationId": "conversation:fixture",
                "membershipId": "membership:worker",
                "prompt": "do the task",
                "allowAll": true,
                "permissionMode": "acceptEdits"
            })
        ));
        assert!(!validate_tool_arguments(
            "lico_subagent_delegate",
            &json!({
                "conversationId": "conversation:fixture",
                "membershipId": "membership:worker",
                "prompt": "do the task",
                "allowAll": "true"
            })
        ));
    }
}
