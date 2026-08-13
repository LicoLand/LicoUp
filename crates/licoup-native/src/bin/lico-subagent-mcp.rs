use licoup_native::{
    domain::{
        delivery_workflow::{self, DeliveryError, DeliveryExecutor, SchedulerConfig},
        subagent_handoff::{
            self, DeliveryControlRecord, DeliveryFailureRecord, DeliveryRunnerState, HandoffRecord,
            HandoffState, SessionMode,
        },
        targets,
    },
    platform::{client_state, delivery_workflow_runtime, dispatch_lane_operation, paths},
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    io::{self, BufRead, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender, TrySendError},
    },
    thread,
    time::Duration,
};

const MCP_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "lico-up-subagents";
const SERVER_VERSION: &str = "0.11.0";
const MAX_MCP_FRAME_BYTES: usize = 64 * 1024;
const MAX_PENDING_TOOL_CALLS: usize = 32;
const MAX_TOOL_WORKERS: usize = 8;
const MAX_ID_BYTES: usize = 256;
const MAX_PROMPT_BYTES: usize = 48 * 1024;
const MAX_LOCATION_BYTES: usize = 4096;
const MAX_WORKING_DIRECTORY_BYTES: usize = 4096;

static RUNNING_DELIVERIES: LazyLock<Mutex<HashSet<String>>> =
    LazyLock::new(|| Mutex::new(HashSet::new()));

struct RunningDeliveryGuard(String);

impl Drop for RunningDeliveryGuard {
    fn drop(&mut self) {
        RUNNING_DELIVERIES
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .remove(&self.0);
    }
}

fn main() -> std::process::ExitCode {
    if targets::scan_targets().is_err() {
        return std::process::ExitCode::FAILURE;
    }
    let shared = Arc::new(ServerState::new());
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    loop {
        match read_line_bounded(&mut reader) {
            InputFrame::Eof => break,
            InputFrame::Oversized => write_json(&shared.output, rpc_error(Value::Null, -32600)),
            InputFrame::Line(line) => process_line(&shared, &line),
        }
    }
    shared.shutdown();
    std::process::ExitCode::SUCCESS
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
            std::env::var("LICOUP_MAIN_AGENT_ID").unwrap_or_default(),
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
                while let Ok(job) = receiver
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .recv()
                {
                    let manager = manager_agent_id
                        .lock()
                        .unwrap_or_else(|error| error.into_inner())
                        .clone();
                    let value = if job.cancelled.load(Ordering::Acquire) {
                        rpc_error(job.id.clone(), -32800)
                    } else {
                        let result = execute_tool(&manager, &job.name, &job.arguments);
                        if job.cancelled.load(Ordering::Acquire) {
                            rpc_error(job.id.clone(), -32800)
                        } else {
                            match result {
                                Ok(value) => rpc_success(job.id.clone(), tool_success(value)),
                                Err(error) => rpc_success(job.id.clone(), tool_error(&error)),
                            }
                        }
                    };
                    cancellations
                        .lock()
                        .unwrap_or_else(|error| error.into_inner())
                        .remove(&job.key);
                    write_json(&output, value);
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
    Oversized,
}

fn read_line_bounded(reader: &mut impl BufRead) -> InputFrame {
    let mut bytes = Vec::new();
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
                InputFrame::Oversized
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
        let newline = slice.last() == Some(&b'\n');
        reader.consume(consumed);
        if newline {
            if bytes.last() == Some(&b'\n') {
                bytes.pop();
            }
            return if oversized {
                InputFrame::Oversized
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
        if method == "notifications/cancelled"
            && let Some(request_id) = object
                .get("params")
                .and_then(Value::as_object)
                .and_then(|params| params.get("requestId"))
            && let Some(flag) = shared
                .cancellations
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .get(&id_key(request_id))
        {
            flag.store(true, Ordering::Release);
        }
        return;
    }
    let id = id.unwrap_or(Value::Null);
    match method {
        "initialize" => initialize(shared, id, object.get("params")),
        "ping" => write_json(&shared.output, rpc_success(id, json!({}))),
        "tools/list" => {
            if !shared.initialized.load(Ordering::Acquire) {
                write_json(&shared.output, rpc_error(id, -32002));
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
    let Some(params) = params.and_then(Value::as_object) else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    let Some(version) = params
        .get("protocolVersion")
        .and_then(Value::as_str)
        .filter(|version| supported_protocol_version(version))
    else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    if !params.get("capabilities").is_some_and(Value::is_object)
        || !params.get("clientInfo").is_some_and(|value| {
            value.is_object()
                && value
                    .get("name")
                    .and_then(Value::as_str)
                    .is_some_and(|name| valid_identifier(name, MAX_ID_BYTES))
        })
    {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    }
    if shared
        .manager_agent_id
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .is_empty()
        && let Some(name) = params
            .get("clientInfo")
            .and_then(|value| value.get("name"))
            .and_then(Value::as_str)
    {
        *shared
            .manager_agent_id
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = name.to_owned();
    }
    shared.initialized.store(true, Ordering::Release);
    write_json(
        &shared.output,
        rpc_success(
            id,
            json!({
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}
            }),
        ),
    );
}

fn start_tool_call(shared: &Arc<ServerState>, id: Value, params: Option<&Value>) {
    if !shared.initialized.load(Ordering::Acquire) {
        write_json(&shared.output, rpc_error(id, -32002));
        return;
    }
    let Some(object) = params.and_then(Value::as_object) else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    let Some(name) = object.get("name").and_then(Value::as_str) else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    let arguments = object
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if !tool_names().contains(&name) || !valid_tool_arguments(name, &arguments) {
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
    let response_id = id.clone();
    let job = ToolJob {
        id,
        name: name.to_owned(),
        arguments,
        key,
        cancelled,
    };
    let sender = shared
        .jobs
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let result = sender
        .as_ref()
        .map(|sender| sender.try_send(job))
        .unwrap_or(Err(TrySendError::Disconnected(ToolJob {
            id: Value::Null,
            name: String::new(),
            arguments: json!({}),
            key: String::new(),
            cancelled: Arc::new(AtomicBool::new(true)),
        })));
    if let Err(error) = result {
        let rejected = match error {
            TrySendError::Full(job) | TrySendError::Disconnected(job) => job,
        };
        shared
            .cancellations
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .remove(&rejected.key);
        write_json(
            &shared.output,
            rpc_success(
                response_id,
                tool_error(&ToolFailure::new("server_busy", true)),
            ),
        );
    }
}

fn execute_tool(
    manager_agent_id: &str,
    name: &str,
    arguments: &Value,
) -> Result<Value, ToolFailure> {
    match name {
        "lico_delivery_start" => delivery_start(manager_agent_id, arguments),
        "lico_delivery_authorize" => delivery_authorize(manager_agent_id, arguments),
        "lico_delivery_status" => delivery_projection(arguments),
        "lico_delivery_cancel" => delivery_cancel(manager_agent_id, arguments),
        "lico_subagents_list" => list_subagents(manager_agent_id),
        "lico_subagent_delegate" => generic_delegate(manager_agent_id, arguments, false),
        "lico_subagent_continue" => generic_delegate(manager_agent_id, arguments, true),
        "lico_subagent_cancel" => generic_cancel(arguments),
        _ => Err(ToolFailure::new("invalid_request", false)),
    }
}

fn delivery_start(manager_agent_id: &str, arguments: &Value) -> Result<Value, ToolFailure> {
    let (bound_arguments, portable) = bind_delivery_state(arguments)?;
    let value = delivery_workflow::start(&bound_arguments).map_err(ToolFailure::from_delivery)?;
    update_delivery_identity(&portable, &bound_arguments, &value)?;
    spawn_delivery_run(manager_agent_id, &bound_arguments, portable)?;
    Ok(value)
}

fn delivery_authorize(manager_agent_id: &str, arguments: &Value) -> Result<Value, ToolFailure> {
    let (bound_arguments, portable) = bind_delivery_state(arguments)?;
    let value =
        delivery_workflow::authorize(&bound_arguments).map_err(ToolFailure::from_delivery)?;
    update_delivery_identity(&portable, &bound_arguments, &value)?;
    spawn_delivery_run(manager_agent_id, &bound_arguments, portable)?;
    Ok(value)
}

fn delivery_projection(arguments: &Value) -> Result<Value, ToolFailure> {
    let value = delivery_workflow::status(arguments).map_err(ToolFailure::from_delivery)?;
    let portable = paths::portable_data_dir()
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    let workflow_id = required_text(arguments, "workflowId", 256)?;
    let run_key = delivery_run_key(&workflow_id, arguments)?;
    let runner_active = RUNNING_DELIVERIES
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .contains(&run_key);
    project_runner_status(value, &portable, &workflow_id, runner_active)
}

fn project_runner_status(
    mut value: Value,
    portable: &Path,
    workflow_id: &str,
    runner_active: bool,
) -> Result<Value, ToolFailure> {
    let mut control = subagent_handoff::load_delivery_control(portable, workflow_id)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    if control
        .as_ref()
        .is_some_and(|record| record.runner_state == DeliveryRunnerState::Running)
        && !runner_active
    {
        persist_runner_failure(
            portable,
            workflow_id,
            &DeliveryError::new(
                "delivery_runner_interrupted",
                "scheduler",
                "delivery-runner",
                true,
                "resume_native_runner",
            ),
        )?;
        control = subagent_handoff::load_delivery_control(portable, workflow_id)
            .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    }
    value["runner"] = control
        .as_ref()
        .map(DeliveryControlRecord::public_projection)
        .unwrap_or_else(|| json!({"state": "pending", "failure": null}));
    Ok(value)
}

fn delivery_cancel(manager_agent_id: &str, arguments: &Value) -> Result<Value, ToolFailure> {
    let (bound_arguments, portable) = bind_delivery_state(arguments)?;
    let workflow_id = required_text(&bound_arguments, "workflowId", 256)?;
    set_runner_state(
        &portable,
        &workflow_id,
        DeliveryRunnerState::Running,
        None,
        false,
    )?;
    let value = match delivery_workflow::cancel(&bound_arguments) {
        Ok(value) => value,
        Err(error) => {
            persist_runner_failure(&portable, &workflow_id, &error)?;
            return Err(ToolFailure::from_delivery(error));
        }
    };
    // Once the checkpoint+ledger gate is terminal, no runner can admit more
    // work. Native conversations are then cancelled; any failure stays typed
    // in_doubt and a repeated cancellation resumes this cleanup.
    let records = match subagent_handoff::list_handoffs(&portable) {
        Ok(records) => records,
        Err(_) => {
            let error = DeliveryError::new(
                "handoff_store_unavailable",
                "cancellation",
                "handoff-store",
                true,
                "retry_after_store_recovers",
            );
            persist_runner_failure(&portable, &workflow_id, &error)?;
            return Err(ToolFailure::from_delivery(error));
        }
    };
    let runtime = delivery_workflow_runtime::NativeDeliveryRuntime;
    for record in records {
        if record.plan_code.is_empty()
            || !record.dispatch_id.starts_with(&format!("{}:", workflow_id))
            || !matches!(record.state, HandoffState::Accepted | HandoffState::Running)
        {
            continue;
        }
        if let Some(path) = record.conversation_path.as_deref() {
            let conversation = match runtime.prepare_conversation(&record.agent_id, "", Some(path))
            {
                Ok(conversation) => conversation,
                Err(error) => {
                    persist_runner_failure(&portable, &workflow_id, &error)?;
                    return Err(ToolFailure::from_delivery(error));
                }
            };
            if let Err(error) = runtime.cancel(&conversation) {
                persist_runner_failure(&portable, &workflow_id, &error)?;
                return Err(ToolFailure::from_delivery(error));
            }
        }
    }
    set_runner_state(
        &portable,
        &workflow_id,
        DeliveryRunnerState::Cancelled,
        None,
        true,
    )?;
    let _ = manager_agent_id;
    Ok(value)
}

fn delivery_run_key(workflow_id: &str, arguments: &Value) -> Result<String, ToolFailure> {
    let root = arguments
        .get("planRoot")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolFailure::new("plan_root_missing", false))?;
    let canonical_root =
        std::fs::canonicalize(root).map_err(|_| ToolFailure::new("plan_root_invalid", false))?;
    Ok(format!(
        "{}:{}",
        workflow_id,
        canonical_root.to_string_lossy()
    ))
}

fn bind_delivery_state(arguments: &Value) -> Result<(Value, PathBuf), ToolFailure> {
    let portable = paths::portable_data_dir()
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    let bound = bind_delivery_state_at(arguments, &portable)?;
    Ok((bound, portable))
}

fn bind_delivery_state_at(arguments: &Value, portable: &Path) -> Result<Value, ToolFailure> {
    let workflow_id = required_text(arguments, "workflowId", 256)?;
    let existing = subagent_handoff::load_delivery_control(portable, &workflow_id)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    let requested = arguments
        .get("stateRoot")
        .and_then(Value::as_str)
        .map(PathBuf::from);
    let state_root = if let Some(control) = &existing {
        let bound = canonical_delivery_state_root(Path::new(&control.ledger_state_root))?;
        if let Some(requested) = requested {
            if !requested.is_absolute() {
                return Err(ToolFailure::new("delivery_state_root_invalid", false));
            }
            // A later lifecycle request may confirm the existing binding but
            // must not initialize an arbitrary replacement path before the
            // mismatch check.
            let requested = std::fs::canonicalize(&requested)
                .map_err(|_| ToolFailure::new("delivery_state_root_mismatch", false))?;
            if requested != bound {
                return Err(ToolFailure::new("delivery_state_root_mismatch", false));
            }
        }
        bound
    } else {
        canonical_delivery_state_root(requested.as_deref().unwrap_or(portable))?
    };
    let state_root_text = state_root.to_string_lossy().into_owned();
    let mut control = existing
        .unwrap_or_else(|| DeliveryControlRecord::new(&workflow_id, state_root_text.clone()));
    control.ledger_state_root = state_root_text.clone();
    control.updated_at_unix_ms = subagent_handoff::unix_ms_now();
    subagent_handoff::persist_delivery_control(portable, &control)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?;
    let mut bound_arguments = arguments.clone();
    bound_arguments["stateRoot"] = Value::String(state_root_text);
    Ok(bound_arguments)
}

fn canonical_delivery_state_root(path: &Path) -> Result<PathBuf, ToolFailure> {
    if !path.is_absolute() {
        return Err(ToolFailure::new("delivery_state_root_invalid", false));
    }
    let store = client_state::ClientStateStore::new(path.to_path_buf())
        .map_err(|_| ToolFailure::new("delivery_state_root_unavailable", true))?;
    std::fs::canonicalize(store.root())
        .map_err(|_| ToolFailure::new("delivery_state_root_unavailable", true))
}

fn update_delivery_identity(
    portable: &Path,
    arguments: &Value,
    response: &Value,
) -> Result<(), ToolFailure> {
    let workflow_id = required_text(arguments, "workflowId", 256)?;
    let plan_code = response
        .get("planCode")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolFailure::new("delivery_identity_missing", false))?;
    let revision = response
        .get("planRevision")
        .and_then(Value::as_u64)
        .ok_or_else(|| ToolFailure::new("delivery_identity_missing", false))?;
    update_delivery_identity_from_engine(portable, &workflow_id, plan_code, revision)
}

fn update_delivery_identity_from_engine(
    portable: &Path,
    workflow_id: &str,
    plan_code: &str,
    revision: u64,
) -> Result<(), ToolFailure> {
    let mut control = subagent_handoff::load_delivery_control(portable, workflow_id)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?
        .ok_or_else(|| ToolFailure::new("delivery_control_not_found", false))?;
    control.plan_code = Some(plan_code.to_owned());
    control.plan_revision = revision;
    control.updated_at_unix_ms = subagent_handoff::unix_ms_now();
    subagent_handoff::persist_delivery_control(portable, &control)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))
}

fn set_runner_state(
    portable: &Path,
    workflow_id: &str,
    state: DeliveryRunnerState,
    failure: Option<DeliveryFailureRecord>,
    clear_failure: bool,
) -> Result<(), ToolFailure> {
    let mut control = subagent_handoff::load_delivery_control(portable, workflow_id)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))?
        .ok_or_else(|| ToolFailure::new("delivery_control_not_found", false))?;
    control.runner_state = state;
    if failure.is_some() || clear_failure {
        control.failure = failure;
    }
    control.updated_at_unix_ms = subagent_handoff::unix_ms_now();
    subagent_handoff::persist_delivery_control(portable, &control)
        .map_err(|_| ToolFailure::new("delivery_control_store_unavailable", true))
}

fn persist_runner_failure(
    portable: &Path,
    workflow_id: &str,
    error: &DeliveryError,
) -> Result<(), ToolFailure> {
    set_runner_state(
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
        false,
    )
}

fn persist_runner_failure_until_durable(portable: &Path, workflow_id: &str, error: &DeliveryError) {
    while persist_runner_failure(portable, workflow_id, error).is_err() {
        // The control record was already durable before the request was
        // accepted. Keep its write-ahead in_doubt state and retry rather than
        // allowing a background failure to disappear.
        thread::sleep(Duration::from_millis(250));
    }
}

fn set_runner_state_until_durable(
    portable: &Path,
    workflow_id: &str,
    state: DeliveryRunnerState,
    clear_failure: bool,
) {
    while set_runner_state(portable, workflow_id, state, None, clear_failure).is_err() {
        thread::sleep(Duration::from_millis(250));
    }
}

fn update_delivery_identity_until_durable(
    portable: &Path,
    workflow_id: &str,
    plan_code: &str,
    revision: u64,
) {
    while update_delivery_identity_from_engine(portable, workflow_id, plan_code, revision).is_err()
    {
        thread::sleep(Duration::from_millis(250));
    }
}

fn spawn_delivery_run(
    manager_agent_id: &str,
    arguments: &Value,
    portable: PathBuf,
) -> Result<(), ToolFailure> {
    let root = arguments
        .get("planRoot")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolFailure::new("plan_root_missing", false))?
        .to_owned();
    let workflow_id = required_text(arguments, "workflowId", 256)?;
    let run_key = delivery_run_key(&workflow_id, arguments)?;
    {
        let mut running = RUNNING_DELIVERIES
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if !running.insert(run_key.clone()) {
            return Ok(());
        }
    }
    let config = SchedulerConfig {
        state_root: arguments
            .get("stateRoot")
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .ok_or_else(|| ToolFailure::new("delivery_state_root_unbound", false))?,
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
    // Write-ahead state: after the caller observes acceptance, a crash before
    // or during the first native pass is restart-visible as recoverable
    // in_doubt rather than a stale running workflow.
    persist_runner_failure(&portable, &workflow_id, &pass_in_doubt)?;
    thread::spawn(move || {
        let _running_guard = RunningDeliveryGuard(run_key);
        let mut config = config;
        let mut exhausted = true;
        // One native runner owns the workflow until it reaches a quiescent or
        // terminal state. Synchronous turns advance immediately; pending
        // native turns are reconciled from their exact admitted location.
        for _ in 0..28_800_u32 {
            persist_runner_failure_until_durable(&portable, &workflow_id, &pass_in_doubt);
            let engine = match licoup_native::domain::delivery_plan::DeliveryPlanEngine::load(&root)
            {
                Ok(engine) => engine,
                Err(error) => {
                    let error = DeliveryError::from(error);
                    persist_runner_failure_until_durable(&portable, &workflow_id, &error);
                    exhausted = false;
                    break;
                }
            };
            if config.manager_location.is_none() {
                config.manager_location = engine
                    .checkpoints()
                    .designer
                    .as_ref()
                    .and_then(|session| session.conversation_location.clone());
            }
            let report =
                match delivery_workflow_runtime::run_once(&workflow_id, engine, config.clone()) {
                    Ok(report) => report,
                    Err(error) => {
                        persist_runner_failure_until_durable(&portable, &workflow_id, &error);
                        exhausted = false;
                        break;
                    }
                };
            let engine = match licoup_native::domain::delivery_plan::DeliveryPlanEngine::load(&root)
            {
                Ok(engine) => engine,
                Err(error) => {
                    let error = DeliveryError::from(error);
                    persist_runner_failure_until_durable(&portable, &workflow_id, &error);
                    exhausted = false;
                    break;
                }
            };
            update_delivery_identity_until_durable(
                &portable,
                &workflow_id,
                engine.plan().code.as_str(),
                engine.checkpoints().revision,
            );
            if matches!(
                engine.checkpoints().phase,
                licoup_native::domain::delivery_plan::PlanPhase::Ready
                    | licoup_native::domain::delivery_plan::PlanPhase::Completed
                    | licoup_native::domain::delivery_plan::PlanPhase::Blocked
            ) || engine.checkpoints().cancellation_requested
            {
                let terminal_state = if engine.checkpoints().cancellation_requested {
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
                set_runner_state_until_durable(&portable, &workflow_id, terminal_state, true);
                exhausted = false;
                break;
            }
            if report.pending > 0 {
                thread::sleep(Duration::from_millis(250));
            } else if report.dispatched == 0 && report.completed == 0 && report.failed == 0 {
                set_runner_state_until_durable(
                    &portable,
                    &workflow_id,
                    DeliveryRunnerState::Ready,
                    true,
                );
                exhausted = false;
                break;
            }
            set_runner_state_until_durable(
                &portable,
                &workflow_id,
                DeliveryRunnerState::Running,
                true,
            );
        }
        if exhausted {
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
        }
    });
    Ok(())
}

fn list_subagents(manager_agent_id: &str) -> Result<Value, ToolFailure> {
    ensure_manager_bound(manager_agent_id)?;
    let scan = targets::scan_targets().map_err(|_| ToolFailure::new("scan_failed", true))?;
    let subagents = scan
        .get("candidates")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|candidate| {
            subordinate_is_available(candidate)
                && candidate.get("target").and_then(Value::as_str) != Some(manager_agent_id)
        })
        .map(|candidate| {
            json!({
                "agentId": candidate.get("target").and_then(Value::as_str).unwrap_or_default(),
                "label": candidate.get("label").and_then(Value::as_str).unwrap_or_default(),
                "status": candidate.get("status").and_then(Value::as_str).unwrap_or_default()
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "schemaVersion": "licoup.subagents.v2",
        "deliveryAuthority": delivery_workflow::DELIVERY_AUTHORITY,
        "routeSelectionAuthority": delivery_workflow::ROUTE_SELECTION_AUTHORITY,
        "subagents": subagents,
        "count": subagents.len()
    }))
}

fn generic_delegate(
    manager_agent_id: &str,
    arguments: &Value,
    continuing: bool,
) -> Result<Value, ToolFailure> {
    ensure_manager_bound(manager_agent_id)?;
    let agent_id = required_text(arguments, "agentId", MAX_ID_BYTES)?;
    if agent_id == manager_agent_id {
        return Err(ToolFailure::new("subagent_must_differ_from_manager", false));
    }
    ensure_subordinate_available(&agent_id)?;
    let prompt = required_text(arguments, "prompt", MAX_PROMPT_BYTES)?;
    let working_directory =
        required_text(arguments, "workingDirectory", MAX_WORKING_DIRECTORY_BYTES)?;
    let existing = arguments.get("conversationPath").and_then(Value::as_str);
    if continuing && existing.is_none() {
        return Err(ToolFailure::new("conversation_location_missing", false));
    }
    let runtime = delivery_workflow_runtime::NativeDeliveryRuntime;
    let conversation = runtime
        .prepare_conversation(&agent_id, &working_directory, existing)
        .map_err(ToolFailure::from_delivery)?;
    let dispatch_id = subagent_handoff::new_dispatch_id();
    let portable = paths::portable_data_dir()
        .map_err(|_| ToolFailure::new("handoff_store_unavailable", true))?;
    let mut record = HandoffRecord::new(
        dispatch_id.clone(),
        if continuing {
            "subagent.continue"
        } else {
            "subagent.delegate"
        },
        manager_agent_id,
        agent_id.clone(),
        if continuing {
            SessionMode::Resume
        } else {
            SessionMode::New
        },
        None,
    );
    // The private handoff must retain the exact admitted native location even
    // for a newly opened one-off session. Public acknowledgements stay path-free.
    record.conversation_path = Some(conversation.source_path.clone());
    record.child_conversation_binding = Some(conversation.binding.clone());
    subagent_handoff::persist_handoff(&portable, &record)
        .map_err(|_| ToolFailure::new("handoff_store_unavailable", true))?;
    let mut params = json!({
        "agent": agent_id,
        "agentId": agent_id,
        "text": prompt,
        "sessionId": conversation.session_id,
        "sourcePath": conversation.source_path,
        "workingDirectory": working_directory,
        "streamEvents": false
    });
    if let Some(model) = arguments.get("model").and_then(Value::as_str) {
        params["model"] = json!(model);
    }
    if let Some(effort) = arguments.get("reasoningEffort").and_then(Value::as_str) {
        params["reasoningEffort"] = json!(effort);
    }
    let result = dispatch_lane_operation("send", &params)
        .map_err(|_| ToolFailure::new("subagent_dispatch_failed", true))?;
    let returned_session = result
        .get("nativeSessionId")
        .or_else(|| result.get("sessionId"))
        .and_then(Value::as_str);
    record.state = if result.get("ok").and_then(Value::as_bool) == Some(true)
        && returned_session == Some(conversation.session_id.as_str())
    {
        HandoffState::Completed
    } else {
        HandoffState::Failed
    };
    record.error_code =
        (record.state == HandoffState::Failed).then(|| "subagent_failed".to_owned());
    subagent_handoff::persist_handoff(&portable, &record)
        .map_err(|_| ToolFailure::new("handoff_store_unavailable", true))?;
    if record.state == HandoffState::Failed {
        return Err(ToolFailure::new("subagent_failed", true));
    }
    Ok(json!({
        "schemaVersion": "licoup.subagent.receipt.v2",
        "operation": if continuing { "subagent.continue" } else { "subagent.delegate" },
        "agentId": agent_id,
        "state": record.state.as_str(),
        "dispatchId": dispatch_id,
        "accepted": true
    }))
}

fn generic_cancel(arguments: &Value) -> Result<Value, ToolFailure> {
    let agent_id = required_text(arguments, "agentId", MAX_ID_BYTES)?;
    ensure_subordinate_available(&agent_id)?;
    let path = required_text(arguments, "conversationPath", MAX_LOCATION_BYTES)?;
    let runtime = delivery_workflow_runtime::NativeDeliveryRuntime;
    let conversation = runtime
        .prepare_conversation(&agent_id, "", Some(&path))
        .map_err(ToolFailure::from_delivery)?;
    runtime
        .cancel(&conversation)
        .map_err(ToolFailure::from_delivery)?;
    Ok(json!({
        "schemaVersion": "licoup.subagent.receipt.v2",
        "operation": "subagent.cancel",
        "agentId": agent_id,
        "state": "cancel-requested",
        "accepted": true
    }))
}

fn ensure_manager_bound(manager_agent_id: &str) -> Result<(), ToolFailure> {
    if valid_identifier(manager_agent_id, MAX_ID_BYTES) {
        Ok(())
    } else {
        Err(ToolFailure::new("main_agent_unbound", false))
    }
}

fn ensure_subordinate_available(agent_id: &str) -> Result<(), ToolFailure> {
    let inspected = targets::inspect_target(agent_id)
        .map_err(|_| ToolFailure::new("subagent_unavailable", false))?;
    let candidate = inspected
        .get("target")
        .ok_or_else(|| ToolFailure::new("subagent_unavailable", false))?;
    if subordinate_is_available(candidate) {
        Ok(())
    } else {
        Err(ToolFailure::new("subagent_unavailable", false))
    }
}

fn subordinate_is_available(candidate: &Value) -> bool {
    let Some(agent_id) = candidate.get("target").and_then(Value::as_str) else {
        return false;
    };
    agent_id != "code"
        && valid_identifier(agent_id, MAX_ID_BYTES)
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
                "retry_after_recovery".to_owned()
            } else {
                "correct_request_and_retry".to_owned()
            },
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

fn tool_catalog() -> Vec<Value> {
    vec![
        delivery_tool(
            "lico_delivery_start",
            "Start or resume a persisted native delivery. LicoUp schedules its Plan internally.",
            &["workflowId", "planRoot"],
            json!({
                "workflowId": bounded_string(256),
                "planRoot": bounded_string(MAX_LOCATION_BYTES),
                "stateRoot": bounded_string(MAX_LOCATION_BYTES),
                "plan": {"type": "object"},
                "decisions": {"type": "object"},
                "mainConversationLocation": bounded_string(MAX_LOCATION_BYTES)
            }),
        ),
        delivery_tool(
            "lico_delivery_authorize",
            "Authorize the current semantic Plan digest; scheduling remains native and internal.",
            &["workflowId", "planRoot", "semanticDigest"],
            json!({
                "workflowId": bounded_string(256),
                "planRoot": bounded_string(MAX_LOCATION_BYTES),
                "semanticDigest": bounded_string(128),
                "stateRoot": bounded_string(MAX_LOCATION_BYTES),
                "mainConversationLocation": bounded_string(MAX_LOCATION_BYTES)
            }),
        ),
        delivery_tool(
            "lico_delivery_status",
            "Read persisted delivery status and the deterministic Plan next action.",
            &["workflowId", "planRoot"],
            json!({"workflowId": bounded_string(256), "planRoot": bounded_string(MAX_LOCATION_BYTES)}),
        ),
        delivery_tool(
            "lico_delivery_cancel",
            "Explicitly cancel a persisted delivery and relay cancellation to active native turns.",
            &["workflowId", "planRoot"],
            json!({"workflowId": bounded_string(256), "planRoot": bounded_string(MAX_LOCATION_BYTES), "stateRoot": bounded_string(MAX_LOCATION_BYTES)}),
        ),
        delivery_tool(
            "lico_subagents_list",
            "List direct one-off native subordinate targets.",
            &[],
            json!({}),
        ),
        delivery_tool(
            "lico_subagent_delegate",
            "Run one direct non-delivery subordinate turn.",
            &["agentId", "prompt", "workingDirectory"],
            json!({
                "agentId": bounded_string(MAX_ID_BYTES),
                "prompt": bounded_string(MAX_PROMPT_BYTES),
                "workingDirectory": bounded_string(MAX_WORKING_DIRECTORY_BYTES),
                "model": bounded_string(MAX_ID_BYTES),
                "reasoningEffort": bounded_string(32)
            }),
        ),
        delivery_tool(
            "lico_subagent_continue",
            "Continue one exact direct non-delivery native conversation.",
            &["agentId", "conversationPath", "prompt", "workingDirectory"],
            json!({
                "agentId": bounded_string(MAX_ID_BYTES),
                "conversationPath": bounded_string(MAX_LOCATION_BYTES),
                "prompt": bounded_string(MAX_PROMPT_BYTES),
                "workingDirectory": bounded_string(MAX_WORKING_DIRECTORY_BYTES),
                "model": bounded_string(MAX_ID_BYTES),
                "reasoningEffort": bounded_string(32)
            }),
        ),
        delivery_tool(
            "lico_subagent_cancel",
            "Explicitly cancel one direct native subordinate turn.",
            &["agentId", "conversationPath"],
            json!({
                "agentId": bounded_string(MAX_ID_BYTES),
                "conversationPath": bounded_string(MAX_LOCATION_BYTES)
            }),
        ),
    ]
}

fn delivery_tool(name: &str, description: &str, required: &[&str], properties: Value) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "required": required,
            "properties": properties
        }
    })
}

fn tool_names() -> &'static [&'static str] {
    &[
        "lico_delivery_start",
        "lico_delivery_authorize",
        "lico_delivery_status",
        "lico_delivery_cancel",
        "lico_subagents_list",
        "lico_subagent_delegate",
        "lico_subagent_continue",
        "lico_subagent_cancel",
    ]
}

fn valid_tool_arguments(name: &str, value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    let required: &[&str] = match name {
        "lico_delivery_start" | "lico_delivery_status" | "lico_delivery_cancel" => {
            &["workflowId", "planRoot"]
        }
        "lico_delivery_authorize" => &["workflowId", "planRoot", "semanticDigest"],
        "lico_subagents_list" => &[],
        "lico_subagent_delegate" => &["agentId", "prompt", "workingDirectory"],
        "lico_subagent_continue" => &["agentId", "conversationPath", "prompt", "workingDirectory"],
        "lico_subagent_cancel" => &["agentId", "conversationPath"],
        _ => return false,
    };
    required.iter().all(|key| object.contains_key(*key))
        && object.keys().all(|key| match key.as_str() {
            "workflowId"
            | "planRoot"
            | "stateRoot"
            | "mainConversationLocation"
            | "conversationLocation"
            | "conversationPath"
            | "workingDirectory"
            | "agentId"
            | "prompt"
            | "semanticDigest"
            | "model"
            | "reasoningEffort" => object.get(key).is_some_and(Value::is_string),
            "plan" | "decisions" => object.get(key).is_some_and(Value::is_object),
            _ => false,
        })
        && object
            .get("workflowId")
            .is_none_or(|value| valid_string(value, 256))
        && object.get("workflowId").is_none_or(|value| {
            value
                .as_str()
                .is_some_and(|text| valid_identifier(text, 256))
        })
        && object
            .get("planRoot")
            .is_none_or(|value| valid_string(value, MAX_LOCATION_BYTES))
        && object
            .get("prompt")
            .is_none_or(|value| valid_string(value, MAX_PROMPT_BYTES))
}

fn valid_string(value: &Value, max: usize) -> bool {
    value.as_str().is_some_and(|value| {
        !value.trim().is_empty() && value.len() <= max && !value.contains('\0')
    })
}

fn valid_identifier(value: &str, max: usize) -> bool {
    !value.is_empty()
        && value.len() <= max
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':' | b'@' | b'+')
        })
        && value != "."
        && value != ".."
}

fn required_text(value: &Value, key: &str, max: usize) -> Result<String, ToolFailure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| valid_string(&Value::String((*value).to_owned()), max))
        .map(str::to_owned)
        .ok_or_else(|| ToolFailure::new("invalid_request", false))
}

fn bounded_string(max: usize) -> Value {
    json!({"type": "string", "minLength": 1, "maxLength": max})
}

fn supported_protocol_version(version: &str) -> bool {
    let bytes = version.as_bytes();
    bytes.len() == 10
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| index == 4 || index == 7 || byte.is_ascii_digit())
        && version >= MCP_VERSION
}

fn id_key(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_owned)
        .or_else(|| value.as_i64().map(|value| value.to_string()))
        .unwrap_or_else(|| value.to_string())
}

fn rpc_success(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn rpc_error(id: Value, code: i64) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": "request failed"}})
}

fn tool_success(value: Value) -> Value {
    json!({"content": [{"type": "text", "text": value.to_string()}], "structuredContent": value})
}

fn tool_error(error: &ToolFailure) -> Value {
    let value = json!({
        "ok": false,
        "error": {
            "code": error.code,
            "stage": error.stage,
            "component": "subagent-mcp",
            "retryable": error.retryable,
            "recovery": error.recovery
        }
    });
    json!({"content": [{"type": "text", "text": value.to_string()}], "isError": true, "structuredContent": value})
}

fn write_json(output: &Mutex<io::Stdout>, value: Value) {
    let mut output = output.lock().unwrap_or_else(|error| error.into_inner());
    let _ = writeln!(output, "{}", value);
    let _ = output.flush();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn test_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("licoup-mcp-{label}-{}", uuid::Uuid::new_v4()))
    }

    #[test]
    fn custom_state_root_binding_is_sticky_private_and_mismatch_safe() {
        let root = test_root("state-binding");
        let portable = root.join("portable");
        let custom = root.join("custom-state");
        fs::create_dir_all(&portable).unwrap();
        let bound = bind_delivery_state_at(
            &json!({
                "workflowId": "workflow-custom-binding",
                "stateRoot": custom.to_string_lossy()
            }),
            &portable,
        )
        .unwrap();
        let canonical_custom = fs::canonicalize(&custom).unwrap();
        assert_eq!(
            bound["stateRoot"].as_str().map(PathBuf::from),
            Some(canonical_custom.clone())
        );

        // A fresh lifecycle call with no stateRoot recovers the durable
        // binding rather than silently falling back to portable state.
        let rebound =
            bind_delivery_state_at(&json!({"workflowId": "workflow-custom-binding"}), &portable)
                .unwrap();
        assert_eq!(
            rebound["stateRoot"].as_str().map(PathBuf::from),
            Some(canonical_custom.clone())
        );
        let control = subagent_handoff::load_delivery_control(&portable, "workflow-custom-binding")
            .unwrap()
            .unwrap();
        assert_eq!(PathBuf::from(&control.ledger_state_root), canonical_custom);
        assert!(
            !control
                .public_projection()
                .to_string()
                .contains(&control.ledger_state_root)
        );
        set_runner_state(
            &portable,
            "workflow-custom-binding",
            DeliveryRunnerState::Cancelled,
            None,
            true,
        )
        .unwrap();
        let restarted_status = project_runner_status(
            json!({"phase": "blocked"}),
            &portable,
            "workflow-custom-binding",
            false,
        )
        .unwrap();
        assert_eq!(restarted_status["runner"]["state"], "cancelled");

        let unbound = root.join("must-not-be-created");
        let mismatch = bind_delivery_state_at(
            &json!({
                "workflowId": "workflow-custom-binding",
                "stateRoot": unbound.to_string_lossy()
            }),
            &portable,
        )
        .unwrap_err();
        assert_eq!(mismatch.code, "delivery_state_root_mismatch");
        assert!(!unbound.exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn background_failure_survives_restart_and_is_status_visible() {
        let root = test_root("runner-failure");
        let portable = root.join("portable");
        let custom = root.join("custom-state");
        fs::create_dir_all(&portable).unwrap();
        bind_delivery_state_at(
            &json!({
                "workflowId": "workflow-runner-failure",
                "stateRoot": custom.to_string_lossy()
            }),
            &portable,
        )
        .unwrap();
        let failure = DeliveryError::new(
            "native_effect_in_doubt",
            "native-dispatch",
            "native-lane",
            true,
            "reconcile_exact_conversation_before_retry",
        );
        persist_runner_failure(&portable, "workflow-runner-failure", &failure).unwrap();

        // The fresh load and projection model a new MCP process after the
        // accepted background turn stopped.
        let reloaded =
            subagent_handoff::load_delivery_control(&portable, "workflow-runner-failure")
                .unwrap()
                .unwrap();
        assert_eq!(reloaded.runner_state, DeliveryRunnerState::InDoubt);
        let projected = project_runner_status(
            json!({"phase": "authorized"}),
            &portable,
            "workflow-runner-failure",
            false,
        )
        .unwrap();
        assert_eq!(projected["runner"]["state"], "in_doubt");
        assert_eq!(projected["runner"]["failure"]["stage"], "native-dispatch");
        assert_eq!(projected["runner"]["failure"]["component"], "native-lane");
        assert_eq!(projected["runner"]["failure"]["retryable"], true);
        assert_eq!(
            projected["runner"]["failure"]["recovery"],
            "reconcile_exact_conversation_before_retry"
        );
        assert!(!projected.to_string().contains(&reloaded.ledger_state_root));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn stale_running_state_becomes_recoverable_in_doubt_on_restart() {
        let root = test_root("runner-restart");
        let portable = root.join("portable");
        let custom = root.join("custom-state");
        fs::create_dir_all(&portable).unwrap();
        bind_delivery_state_at(
            &json!({
                "workflowId": "workflow-runner-restart",
                "stateRoot": custom.to_string_lossy()
            }),
            &portable,
        )
        .unwrap();
        set_runner_state(
            &portable,
            "workflow-runner-restart",
            DeliveryRunnerState::Running,
            None,
            true,
        )
        .unwrap();
        let projected = project_runner_status(
            json!({"phase": "authorized"}),
            &portable,
            "workflow-runner-restart",
            false,
        )
        .unwrap();
        assert_eq!(projected["runner"]["state"], "in_doubt");
        assert_eq!(
            projected["runner"]["failure"]["code"],
            "delivery_runner_interrupted"
        );
        assert_eq!(projected["runner"]["failure"]["retryable"], true);
        let _ = fs::remove_dir_all(root);
    }
}
