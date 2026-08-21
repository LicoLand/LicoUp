use interprocess::local_socket::{Stream, traits::Stream as _};
use licoup_native::{
    domain::{
        client_conversation::{
            ConversationService, DispatchSessionMode, MembershipStatus,
            PERSISTENT_TRANSPORT_REQUIRED, PrincipalKind,
        },
        conversations,
        delivery_scheduler::{
            self, DeliveryError, DeliveryExecutor, DeliveryResult, SchedulerConfig,
        },
        delivery_state::{self, DeliveryControlRecord, DeliveryFailureRecord, DeliveryRunnerState},
        targets,
    },
    platform::{client_state, conversation_host_transport, conversation_runtime, paths},
};
use serde_json::{Map, Value, json};
use std::{
    collections::{HashMap, HashSet},
    io::{self, BufRead, Read, Write},
    path::{Path, PathBuf},
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
const SERVER_VERSION: &str = "0.11.0";
const MAX_MCP_FRAME_BYTES: usize = 64 * 1024;
const MAX_PENDING_TOOL_CALLS: usize = 32;
const MAX_TOOL_WORKERS: usize = 8;
const MAX_PROMPT_BYTES: usize = 48 * 1024;
const MAX_ID_BYTES: usize = 256;
const MAX_LOCATION_BYTES: usize = 4096;
const MAX_WORKING_DIRECTORY_BYTES: usize = 4096;
const MIN_SUBAGENT_TIMEOUT_MS: u64 = 1_000;
const MAX_SUBAGENT_TIMEOUT_MS: u64 = 30 * 60 * 1_000;
const MIN_SUBAGENT_STDOUT_BYTES: u64 = 64 * 1024;
const MAX_SUBAGENT_STDOUT_BYTES: u64 = 64 * 1024 * 1024;
const MIN_SUBAGENT_STDERR_BYTES: u64 = 16 * 1024;
const MAX_SUBAGENT_STDERR_BYTES: u64 = 4 * 1024 * 1024;

static RUNNING_DELIVERIES: LazyLock<Mutex<HashSet<String>>> =
    LazyLock::new(|| Mutex::new(HashSet::new()));

struct RunningDeliveryGuard(String);

impl RunningDeliveryGuard {
    fn claim(key: String) -> Option<Self> {
        let mut running = RUNNING_DELIVERIES
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if running.insert(key.clone()) {
            Some(Self(key))
        } else {
            None
        }
    }
}

impl Drop for RunningDeliveryGuard {
    fn drop(&mut self) {
        RUNNING_DELIVERIES
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .remove(&self.0);
    }
}

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
        "lico_delivery_start" => delivery_start(manager_agent_id, arguments),
        "lico_delivery_authorize" => delivery_authorize(manager_agent_id, arguments),
        "lico_delivery_status" => delivery_status(arguments),
        "lico_delivery_cancel" => delivery_cancel(arguments),
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

fn delivery_start(manager_agent_id: &str, arguments: &Value) -> Result<Value, ToolFailure> {
    let (bound, portable) = bind_delivery_state(arguments)?;
    // Compose the required host before the Plan opens a role dispatch. Host
    // absence therefore returns the typed transport rejection without
    // advancing a dispatch checkpoint or trying another execution lane.
    let runtime = compose_delivery_runtime(&portable)?;
    let value = delivery_scheduler::start(&bound).map_err(ToolFailure::from_delivery)?;
    update_delivery_identity_from_response(&portable, &bound, &value)?;
    spawn_delivery_run(manager_agent_id, &bound, portable, runtime)?;
    Ok(value)
}

fn delivery_authorize(manager_agent_id: &str, arguments: &Value) -> Result<Value, ToolFailure> {
    let (bound, portable) = bind_delivery_state(arguments)?;
    let runtime = compose_delivery_runtime(&portable)?;
    let value = delivery_scheduler::authorize(&bound).map_err(ToolFailure::from_delivery)?;
    update_delivery_identity_from_response(&portable, &bound, &value)?;
    spawn_delivery_run(manager_agent_id, &bound, portable, runtime)?;
    Ok(value)
}

fn delivery_status(arguments: &Value) -> Result<Value, ToolFailure> {
    let mut value = delivery_scheduler::status(arguments).map_err(ToolFailure::from_delivery)?;
    let portable = paths::portable_data_dir()
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    let workflow_id = required_text(arguments, "workflowId", MAX_ID_BYTES)?;
    let run_key = delivery_run_key(&workflow_id, arguments)?;
    let runner_active = RUNNING_DELIVERIES
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .contains(&run_key);
    let mut control = delivery_state::load_delivery_control(&portable, &workflow_id)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    if control
        .as_ref()
        .is_some_and(|record| record.runner_state == DeliveryRunnerState::Running)
        && !runner_active
    {
        persist_runner_failure(
            &portable,
            &workflow_id,
            &DeliveryError::new(
                "delivery_runner_interrupted",
                "scheduler",
                "delivery-runner",
                true,
                "resume_native_runner",
            ),
        )?;
        control = delivery_state::load_delivery_control(&portable, &workflow_id)
            .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    }
    value["runner"] = control
        .as_ref()
        .map(DeliveryControlRecord::public_projection)
        .unwrap_or_else(|| json!({"state": "pending", "failure": null}));
    Ok(value)
}

fn delivery_cancel(arguments: &Value) -> Result<Value, ToolFailure> {
    let (bound, portable) = bind_delivery_state(arguments)?;
    let workflow_id = required_text(&bound, "workflowId", MAX_ID_BYTES)?;
    set_delivery_runner(&portable, &workflow_id, DeliveryRunnerState::Running, None)?;
    let value = match delivery_scheduler::cancel(&bound) {
        Ok(value) => value,
        Err(error) => {
            persist_runner_failure(&portable, &workflow_id, &error)?;
            return Err(ToolFailure::from_delivery(error));
        }
    };
    // Explicit cancellation reaches the same composed host door as the
    // runner: each live dispatch receives exactly one control-plane cancel
    // for its recorded identity and Conversation scope, and an
    // already-settled or never-opened dispatch is an idempotent no-op. No
    // native admission lookup is needed on this path anymore.
    let runtime = compose_delivery_runtime(&portable)?;
    let records = delivery_state::list_delivery_dispatches(&portable)
        .map_err(|_| ToolFailure::new("delivery_dispatch_store_unavailable", true))?;
    for record in records {
        if record.plan_code.is_empty()
            || !record.dispatch_id.starts_with(&format!("{workflow_id}:"))
            || !matches!(
                record.state,
                delivery_state::DeliveryDispatchState::Accepted
                    | delivery_state::DeliveryDispatchState::Running
            )
        {
            continue;
        }
        runtime
            .cancel(&record.dispatch_id)
            .map_err(ToolFailure::from_delivery)?;
    }
    set_delivery_runner(
        &portable,
        &workflow_id,
        DeliveryRunnerState::Cancelled,
        None,
    )?;
    Ok(value)
}

/// The one composed Delivery host door: a single bounded persistent-host
/// request port plus the canonical Conversation store. Both Delivery entry
/// points — the background runner pass and explicit Delivery cancellation —
/// share this composition, so no Delivery path can exist without the host
/// door. Host failures keep their typed codes unchanged; host absence is
/// the typed `persistent_conversation_transport_required` rejection produced
/// by the transport helper, never a one-shot lane fallback.
fn delivery_host_request(method: &str, params: &Value) -> DeliveryResult<Value> {
    execute_persistent_conversation_method(method, params).map_err(|failure| {
        DeliveryError::new(
            failure.code,
            "native-dispatch",
            "persistent-host",
            failure.retryable,
            failure.recovery,
        )
    })
}

fn compose_delivery_runtime(
    portable: &Path,
) -> Result<conversation_runtime::NativeDeliveryRuntime, ToolFailure> {
    require_delivery_host_with(|| conversation_host_transport::connect_existing().map(drop))?;
    let service = ConversationService::open(portable)
        .map_err(|_| ToolFailure::new("conversation_state_unavailable", true))?;
    let port: conversation_runtime::DeliveryHostRequest = Arc::new(delivery_host_request);
    Ok(conversation_runtime::NativeDeliveryRuntime::new(
        port,
        service.store().clone(),
    ))
}

fn require_delivery_host_with(connect: impl FnOnce() -> io::Result<()>) -> Result<(), ToolFailure> {
    connect().map_err(|_| ToolFailure::new(PERSISTENT_TRANSPORT_REQUIRED, true))
}

fn bind_delivery_state(arguments: &Value) -> Result<(Value, PathBuf), ToolFailure> {
    let portable = paths::portable_data_dir()
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    let workflow_id = required_text(arguments, "workflowId", MAX_ID_BYTES)?;
    let existing = delivery_state::load_delivery_control(&portable, &workflow_id)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    let state_root = arguments
        .get("stateRoot")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .or_else(|| {
            existing
                .as_ref()
                .map(|record| PathBuf::from(&record.ledger_state_root))
        })
        .unwrap_or_else(|| portable.clone());
    if !state_root.is_absolute() {
        return Err(ToolFailure::new("delivery_state_root_invalid", false));
    }
    let store = client_state::ClientStateStore::new(state_root)
        .map_err(|_| ToolFailure::new("delivery_state_root_unavailable", true))?;
    let state_root = std::fs::canonicalize(store.root())
        .map_err(|_| ToolFailure::new("delivery_state_root_unavailable", true))?;
    let state_root_text = state_root.to_string_lossy().into_owned();
    if existing
        .as_ref()
        .is_some_and(|record| record.ledger_state_root != state_root_text)
    {
        return Err(ToolFailure::new("delivery_state_root_mismatch", false));
    }
    let record =
        existing.unwrap_or_else(|| DeliveryControlRecord::new(&workflow_id, &state_root_text));
    delivery_state::persist_delivery_control(&portable, &record)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    let mut bound = arguments.clone();
    bound["stateRoot"] = json!(state_root_text);
    Ok((bound, portable))
}

fn delivery_run_key(workflow_id: &str, arguments: &Value) -> Result<String, ToolFailure> {
    let root = arguments
        .get("planRoot")
        .and_then(Value::as_str)
        .ok_or(ToolFailure::new("plan_root_missing", false))?;
    let root =
        std::fs::canonicalize(root).map_err(|_| ToolFailure::new("plan_root_invalid", false))?;
    Ok(format!("{workflow_id}:{}", root.to_string_lossy()))
}

fn update_delivery_identity_from_response(
    portable: &Path,
    arguments: &Value,
    response: &Value,
) -> Result<(), ToolFailure> {
    let workflow_id = required_text(arguments, "workflowId", MAX_ID_BYTES)?;
    let plan_code = response
        .get("planCode")
        .and_then(Value::as_str)
        .ok_or(ToolFailure::new("delivery_identity_missing", false))?;
    let revision = response
        .get("planRevision")
        .and_then(Value::as_u64)
        .ok_or(ToolFailure::new("delivery_identity_missing", false))?;
    update_delivery_identity(portable, &workflow_id, plan_code, revision)
}

fn update_delivery_identity(
    portable: &Path,
    workflow_id: &str,
    plan_code: &str,
    revision: u64,
) -> Result<(), ToolFailure> {
    let mut record = delivery_state::load_delivery_control(portable, workflow_id)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?
        .ok_or(ToolFailure::new("delivery_control_not_found", false))?;
    if record.plan_code.as_deref() == Some(plan_code) && record.plan_revision == revision {
        // An unchanged runner record is never rewritten, so a pass that only
        // waits on live turns performs no store write.
        return Ok(());
    }
    record.plan_code = Some(plan_code.to_owned());
    record.plan_revision = revision;
    record.updated_at_unix_ms = delivery_state::unix_ms_now();
    delivery_state::persist_delivery_control(portable, &record)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))
}

fn set_delivery_runner(
    portable: &Path,
    workflow_id: &str,
    state: DeliveryRunnerState,
    failure: Option<DeliveryFailureRecord>,
) -> Result<(), ToolFailure> {
    let mut record = delivery_state::load_delivery_control(portable, workflow_id)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?
        .ok_or(ToolFailure::new("delivery_control_not_found", false))?;
    if record.runner_state == state && record.failure == failure {
        // An unchanged runner record is never rewritten, so a pass that only
        // waits on live turns performs no store write.
        return Ok(());
    }
    record.runner_state = state;
    record.failure = failure;
    record.updated_at_unix_ms = delivery_state::unix_ms_now();
    delivery_state::persist_delivery_control(portable, &record)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))
}

fn persist_runner_failure(
    portable: &Path,
    workflow_id: &str,
    error: &DeliveryError,
) -> Result<(), ToolFailure> {
    set_delivery_runner(
        portable,
        workflow_id,
        if error.retryable {
            DeliveryRunnerState::InDoubt
        } else {
            DeliveryRunnerState::Blocked
        },
        Some(DeliveryFailureRecord {
            code: error.code.clone(),
            stage: error.stage.clone(),
            component: error.component.clone(),
            retryable: error.retryable,
            recovery: error.recovery.clone(),
        }),
    )
}

fn persist_runner_failure_until_durable(portable: &Path, workflow_id: &str, error: &DeliveryError) {
    while persist_runner_failure(portable, workflow_id, error).is_err() {
        thread::sleep(Duration::from_millis(250));
    }
}

fn set_runner_state_until_durable(portable: &Path, workflow_id: &str, state: DeliveryRunnerState) {
    while set_delivery_runner(portable, workflow_id, state, None).is_err() {
        thread::sleep(Duration::from_millis(250));
    }
}

fn update_delivery_identity_until_durable(
    portable: &Path,
    workflow_id: &str,
    plan_code: &str,
    revision: u64,
) {
    while update_delivery_identity(portable, workflow_id, plan_code, revision).is_err() {
        thread::sleep(Duration::from_millis(250));
    }
}

fn spawn_delivery_run(
    manager_agent_id: &str,
    arguments: &Value,
    portable: PathBuf,
    runtime: conversation_runtime::NativeDeliveryRuntime,
) -> Result<(), ToolFailure> {
    let root = arguments
        .get("planRoot")
        .and_then(Value::as_str)
        .ok_or(ToolFailure::new("plan_root_missing", false))?
        .to_owned();
    let workflow_id = required_text(arguments, "workflowId", MAX_ID_BYTES)?;
    let run_key = delivery_run_key(&workflow_id, arguments)?;
    let Some(running_guard) = RunningDeliveryGuard::claim(run_key) else {
        return Ok(());
    };
    let mut config = SchedulerConfig {
        state_root: PathBuf::from(
            arguments
                .get("stateRoot")
                .and_then(Value::as_str)
                .ok_or(ToolFailure::new("delivery_state_root_unbound", false))?,
        ),
        manager_agent_id: manager_agent_id.to_owned(),
        manager_location: arguments
            .get("mainConversationLocation")
            .or_else(|| arguments.get("conversationLocation"))
            .and_then(Value::as_str)
            .map(str::to_owned),
    };
    let pass_in_doubt = DeliveryError::new(
        "delivery_runner_pass_uncommitted",
        "scheduler",
        "delivery-runner",
        true,
        "resume_native_runner",
    );
    persist_runner_failure(&portable, &workflow_id, &pass_in_doubt)?;
    thread::spawn(move || {
        // Moving the already-claimed guard into the runner makes every setup
        // error release the process-local claim instead of poisoning retries.
        let _guard = running_guard;
        // The bounded progress budget only prices passes that move work;
        // waiting on live turns is not progress and never spends it.
        let mut budget = 28_800_u32;
        loop {
            persist_runner_failure_until_durable(&portable, &workflow_id, &pass_in_doubt);
            let engine = match licoup_native::domain::delivery_plan::DeliveryPlanEngine::load(&root)
            {
                Ok(engine) => engine,
                Err(error) => {
                    persist_runner_failure_until_durable(
                        &portable,
                        &workflow_id,
                        &DeliveryError::from(error),
                    );
                    return;
                }
            };
            if config.manager_location.is_none() {
                config.manager_location = engine
                    .checkpoints()
                    .designer
                    .as_ref()
                    .and_then(|session| session.conversation_location.clone());
            }
            let report = match conversation_runtime::run_once(
                &workflow_id,
                engine,
                config.clone(),
                &runtime,
            ) {
                Ok(report) => report,
                Err(error) => {
                    persist_runner_failure_until_durable(&portable, &workflow_id, &error);
                    return;
                }
            };
            let engine = match licoup_native::domain::delivery_plan::DeliveryPlanEngine::load(&root)
            {
                Ok(engine) => engine,
                Err(error) => {
                    persist_runner_failure_until_durable(
                        &portable,
                        &workflow_id,
                        &DeliveryError::from(error),
                    );
                    return;
                }
            };
            update_delivery_identity_until_durable(
                &portable,
                &workflow_id,
                &engine.plan().code,
                engine.checkpoints().revision,
            );
            if engine.checkpoints().cancellation_requested
                || matches!(
                    engine.checkpoints().phase,
                    licoup_native::domain::delivery_plan::PlanPhase::Ready
                        | licoup_native::domain::delivery_plan::PlanPhase::Completed
                        | licoup_native::domain::delivery_plan::PlanPhase::Blocked
                )
            {
                let state = if engine.checkpoints().cancellation_requested {
                    DeliveryRunnerState::Cancelled
                } else {
                    match engine.checkpoints().phase {
                        licoup_native::domain::delivery_plan::PlanPhase::Completed => {
                            DeliveryRunnerState::Completed
                        }
                        licoup_native::domain::delivery_plan::PlanPhase::Blocked => {
                            DeliveryRunnerState::Blocked
                        }
                        _ => DeliveryRunnerState::Ready,
                    }
                };
                set_runner_state_until_durable(&portable, &workflow_id, state);
                return;
            }
            match delivery_pass_outcome(&report) {
                DeliveryPassOutcome::WaitPending => {
                    // A pass that only observes live turns sleeps without
                    // consuming the bounded progress budget, and the runner
                    // record above was already left unchanged. Nothing here
                    // may fail or cancel a turn that is still running.
                    thread::sleep(Duration::from_millis(250));
                }
                DeliveryPassOutcome::Unproductive => {
                    set_runner_state_until_durable(
                        &portable,
                        &workflow_id,
                        DeliveryRunnerState::Ready,
                    );
                    return;
                }
                DeliveryPassOutcome::Progress => {
                    budget = budget.saturating_sub(1);
                    if budget == 0 {
                        break;
                    }
                    if report.pending > 0 {
                        thread::sleep(Duration::from_millis(250));
                    } else {
                        set_runner_state_until_durable(
                            &portable,
                            &workflow_id,
                            DeliveryRunnerState::Running,
                        );
                    }
                }
            }
        }
        persist_runner_failure_until_durable(
            &portable,
            &workflow_id,
            &DeliveryError::new(
                "delivery_runner_iteration_limit",
                "scheduler",
                "delivery-runner",
                true,
                "retry_after_runner_restarts",
            ),
        );
    });
    Ok(())
}

/// Budget decision for one runner pass. A pass that only observes pending
/// turns waits on live work: it sleeps without consuming the bounded
/// progress budget and without rewriting an unchanged runner record. An
/// unproductive pass ends the run as ready exactly as before, and any other
/// pass consumes exactly one bounded budget unit.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DeliveryPassOutcome {
    WaitPending,
    Unproductive,
    Progress,
}

fn delivery_pass_outcome(report: &delivery_scheduler::ScheduleReport) -> DeliveryPassOutcome {
    if report.pending > 0 {
        if report.dispatched == 0 && report.completed == 0 && report.failed == 0 {
            DeliveryPassOutcome::WaitPending
        } else {
            DeliveryPassOutcome::Progress
        }
    } else if report.dispatched == 0 && report.completed == 0 && report.failed == 0 {
        DeliveryPassOutcome::Unproductive
    } else {
        DeliveryPassOutcome::Progress
    }
}

#[derive(Clone, Debug)]
struct ToolFailure {
    code: String,
    stage: String,
    retryable: bool,
    recovery: String,
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
        }
    }

    fn from_delivery(error: DeliveryError) -> Self {
        Self {
            code: error.code,
            stage: error.stage,
            retryable: error.retryable,
            recovery: error.recovery,
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
    let context = conversation_dispatch_context(service, arguments)?;
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
    arguments: &Value,
) -> Result<ConversationDispatchContext, ToolFailure> {
    let conversation_id = required_text(arguments, "conversationId", MAX_ID_BYTES)?;
    let membership_id = required_text(arguments, "membershipId", MAX_ID_BYTES)?;
    let conversation = service
        .store()
        .get(&conversation_id)
        .map_err(|_| ToolFailure::new("conversation_not_found", false))?;
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
    let context = conversation_dispatch_context(service, arguments)?;
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
            "name": "lico_delivery_start",
            "description": "Start or resume a persisted native delivery through canonical Agent conversations.",
            "inputSchema": closed_object(&["workflowId", "planRoot"], json!({
                "workflowId": bounded_string(MAX_ID_BYTES),
                "planRoot": bounded_string(MAX_LOCATION_BYTES),
                "stateRoot": bounded_string(MAX_LOCATION_BYTES),
                "plan": {"type": "object"},
                "decisions": {"type": "object"},
                "mainConversationLocation": bounded_string(MAX_LOCATION_BYTES)
            }))
        }),
        json!({
            "name": "lico_delivery_authorize",
            "description": "Authorize the current semantic Plan digest and run the native scheduler.",
            "inputSchema": closed_object(&["workflowId", "planRoot", "semanticDigest"], json!({
                "workflowId": bounded_string(MAX_ID_BYTES),
                "planRoot": bounded_string(MAX_LOCATION_BYTES),
                "semanticDigest": bounded_string(128),
                "stateRoot": bounded_string(MAX_LOCATION_BYTES),
                "mainConversationLocation": bounded_string(MAX_LOCATION_BYTES)
            }))
        }),
        json!({
            "name": "lico_delivery_status",
            "description": "Read persisted delivery, runner, Plan, and numeric Token ledger status.",
            "inputSchema": closed_object(&["workflowId", "planRoot"], json!({
                "workflowId": bounded_string(MAX_ID_BYTES),
                "planRoot": bounded_string(MAX_LOCATION_BYTES)
            }))
        }),
        json!({
            "name": "lico_delivery_cancel",
            "description": "Persist cancellation of a delivery before any later scheduler pass.",
            "inputSchema": closed_object(&["workflowId", "planRoot"], json!({
                "workflowId": bounded_string(MAX_ID_BYTES),
                "planRoot": bounded_string(MAX_LOCATION_BYTES),
                "stateRoot": bounded_string(MAX_LOCATION_BYTES)
            }))
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
        "lico_delivery_start",
        "lico_delivery_authorize",
        "lico_delivery_status",
        "lico_delivery_cancel",
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
        "lico_delivery_start" => &[
            "workflowId",
            "planRoot",
            "stateRoot",
            "plan",
            "decisions",
            "mainConversationLocation",
        ],
        "lico_delivery_authorize" => &[
            "workflowId",
            "planRoot",
            "semanticDigest",
            "stateRoot",
            "mainConversationLocation",
        ],
        "lico_delivery_status" => &["workflowId", "planRoot"],
        "lico_delivery_cancel" => &["workflowId", "planRoot", "stateRoot"],
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
        "lico_delivery_start" => {
            valid_required(object, "workflowId", MAX_ID_BYTES)
                && valid_required(object, "planRoot", MAX_WORKING_DIRECTORY_BYTES)
                && valid_optional(object, "stateRoot", MAX_WORKING_DIRECTORY_BYTES)
                && valid_optional(
                    object,
                    "mainConversationLocation",
                    MAX_WORKING_DIRECTORY_BYTES,
                )
                && object.get("plan").is_none_or(Value::is_object)
                && object.get("decisions").is_none_or(Value::is_object)
        }
        "lico_delivery_authorize" => {
            valid_required(object, "workflowId", MAX_ID_BYTES)
                && valid_required(object, "planRoot", MAX_WORKING_DIRECTORY_BYTES)
                && valid_required(object, "semanticDigest", 128)
                && valid_optional(object, "stateRoot", MAX_WORKING_DIRECTORY_BYTES)
                && valid_optional(
                    object,
                    "mainConversationLocation",
                    MAX_WORKING_DIRECTORY_BYTES,
                )
        }
        "lico_delivery_status" => {
            valid_required(object, "workflowId", MAX_ID_BYTES)
                && valid_required(object, "planRoot", MAX_WORKING_DIRECTORY_BYTES)
        }
        "lico_delivery_cancel" => {
            valid_required(object, "workflowId", MAX_ID_BYTES)
                && valid_required(object, "planRoot", MAX_WORKING_DIRECTORY_BYTES)
                && valid_optional(object, "stateRoot", MAX_WORKING_DIRECTORY_BYTES)
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
    let value = json!({
        "schemaVersion": "licoup.subagent.error.v1",
        "reasonCode": error.code,
        "stage": error.stage,
        "retryable": error.retryable,
        "recovery": error.recovery
    });
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
    fn tool_surface_is_closed_and_contains_delivery_and_subagent_operations() {
        assert_eq!(
            tool_names(),
            &[
                "lico_delivery_start",
                "lico_delivery_authorize",
                "lico_delivery_status",
                "lico_delivery_cancel",
                "lico_subagents_list",
                "lico_subagent_probe",
                "lico_subagent_delegate",
                "lico_subagent_continue",
                "lico_subagent_cancel",
            ]
        );
        assert!(validate_tool_arguments(
            "lico_delivery_status",
            &json!({"workflowId": "workflow:fixture", "planRoot": "/fixture-root/plan"})
        ));
        assert!(validate_tool_arguments(
            "lico_subagent_probe",
            &json!({"agentId": "worker"})
        ));
        assert!(!validate_tool_arguments("lico_subagent_probe", &json!({})));
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

    #[test]
    fn delivery_pending_only_pass_sleeps_without_consuming_the_progress_budget() {
        let pending_only = delivery_scheduler::ScheduleReport {
            dispatched: 0,
            completed: 0,
            failed: 0,
            pending: 3,
        };
        assert_eq!(
            delivery_pass_outcome(&pending_only),
            DeliveryPassOutcome::WaitPending
        );
        let mixed = delivery_scheduler::ScheduleReport {
            dispatched: 1,
            ..pending_only
        };
        assert_eq!(delivery_pass_outcome(&mixed), DeliveryPassOutcome::Progress);
        let settled = delivery_scheduler::ScheduleReport {
            dispatched: 0,
            completed: 1,
            failed: 0,
            pending: 0,
        };
        assert_eq!(
            delivery_pass_outcome(&settled),
            DeliveryPassOutcome::Progress
        );
        let unproductive = delivery_scheduler::ScheduleReport::default();
        assert_eq!(
            delivery_pass_outcome(&unproductive),
            DeliveryPassOutcome::Unproductive
        );
    }

    #[test]
    fn delivery_runner_record_is_not_rewritten_when_unchanged() {
        let root = std::env::temp_dir().join(format!(
            "licoup-delivery-runner-record-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let workflow_id = "workflow-delivery-pass";
        let record = delivery_state::DeliveryControlRecord::new(workflow_id, "/fixture-state");
        delivery_state::persist_delivery_control(&root, &record).unwrap();
        let failure = DeliveryFailureRecord {
            code: "delivery_runner_pass_uncommitted".to_owned(),
            stage: "scheduler".to_owned(),
            component: "delivery-runner".to_owned(),
            retryable: true,
            recovery: "resume_native_runner".to_owned(),
        };
        set_delivery_runner(
            &root,
            workflow_id,
            DeliveryRunnerState::InDoubt,
            Some(failure.clone()),
        )
        .unwrap();
        let first = delivery_state::load_delivery_control(&root, workflow_id)
            .unwrap()
            .unwrap();
        std::thread::sleep(Duration::from_millis(2));
        set_delivery_runner(
            &root,
            workflow_id,
            DeliveryRunnerState::InDoubt,
            Some(failure),
        )
        .unwrap();
        let second = delivery_state::load_delivery_control(&root, workflow_id)
            .unwrap()
            .unwrap();
        assert_eq!(second.runner_state, DeliveryRunnerState::InDoubt);
        assert_eq!(first.updated_at_unix_ms, second.updated_at_unix_ms);
        update_delivery_identity(&root, workflow_id, "PLAN-DELIVERY", 7).unwrap();
        let third = delivery_state::load_delivery_control(&root, workflow_id)
            .unwrap()
            .unwrap();
        assert_eq!(third.plan_code.as_deref(), Some("PLAN-DELIVERY"));
        std::thread::sleep(Duration::from_millis(2));
        update_delivery_identity(&root, workflow_id, "PLAN-DELIVERY", 7).unwrap();
        let fourth = delivery_state::load_delivery_control(&root, workflow_id)
            .unwrap()
            .unwrap();
        assert_eq!(third.updated_at_unix_ms, fourth.updated_at_unix_ms);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn delivery_host_absence_is_the_typed_persistent_transport_rejection() {
        let error = require_delivery_host_with(|| {
            Err(io::Error::new(io::ErrorKind::NotFound, "synthetic absence"))
        })
        .unwrap_err();
        assert_eq!(error.code, PERSISTENT_TRANSPORT_REQUIRED);
        assert!(error.retryable);
    }

    #[test]
    fn delivery_host_absence_does_not_open_a_plan_checkpoint() {
        let root = std::env::temp_dir().join(format!(
            "licoup-delivery-host-absence-{}",
            uuid::Uuid::new_v4()
        ));
        let plan_root = root.join("plan");
        std::fs::create_dir_all(&plan_root).unwrap();
        let previous = paths::set_portable_data_dir_override(Some(root.clone()));
        let error = delivery_start(
            "manager-agent",
            &json!({
                "workflowId": "workflow-host-absence",
                "planRoot": plan_root.to_string_lossy(),
            }),
        )
        .unwrap_err();
        paths::set_portable_data_dir_override(previous);
        assert_eq!(error.code, PERSISTENT_TRANSPORT_REQUIRED);
        assert!(!plan_root.join("Checkpoints.json").exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn delivery_runner_setup_failure_releases_the_process_local_claim() {
        let key = format!("delivery-claim-fixture-{}", uuid::Uuid::new_v4());
        let first = RunningDeliveryGuard::claim(key.clone()).unwrap();
        assert!(RunningDeliveryGuard::claim(key.clone()).is_none());
        drop(first);
        assert!(RunningDeliveryGuard::claim(key).is_some());
    }
}
