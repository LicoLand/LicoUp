use lico_client_native::platform::orchestrator_control_plane::{
    build_codex_mcp_orchestrator_request, build_codex_mcp_status_event_request,
};
use lico_client_native::platform::orchestrator_ipc::{
    OrchestratorIpcClient, OrchestratorIpcReceipt,
};
use lico_client_native::platform::orchestrator_service::default_orchestrator_state_root;
use serde_json::{Map, Value, json};
use std::{
    collections::HashMap,
    io::{self, BufRead, Write},
    process::ExitCode,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender, TrySendError},
    },
    thread,
};
use std::{path::PathBuf, time::Duration};

const MCP_VERSION: &str = "2025-06-18";
const MAX_MCP_FRAME_BYTES: usize = 64 * 1024;
const MAX_IPC_CONCURRENCY: usize = 8;
const MAX_PENDING_TOOL_CALLS: usize = 32;
const SERVER_NAME: &str = "lico-arc-orchestration";
const SERVER_VERSION: &str = "0.1.0";

fn main() -> ExitCode {
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
    output: Arc<Mutex<io::Stdout>>,
    cancellations: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
    jobs: Mutex<Option<SyncSender<ToolJob>>>,
    workers: Mutex<Vec<thread::JoinHandle<()>>>,
}

impl ServerState {
    fn new() -> Self {
        let output = Arc::new(Mutex::new(io::stdout()));
        let cancellations = Arc::new(Mutex::new(HashMap::new()));
        let (sender, receiver) = mpsc::sync_channel::<ToolJob>(MAX_PENDING_TOOL_CALLS);
        let receiver = Arc::new(Mutex::new(receiver));
        let mut workers = Vec::with_capacity(MAX_IPC_CONCURRENCY);
        for _ in 0..MAX_IPC_CONCURRENCY {
            let receiver = Arc::clone(&receiver);
            let output = Arc::clone(&output);
            let cancellations = Arc::clone(&cancellations);
            workers.push(thread::spawn(move || {
                loop {
                    let job = receiver
                        .lock()
                        .unwrap_or_else(|error| error.into_inner())
                        .recv();
                    let Ok(job) = job else { break };
                    let response = if job.cancelled.load(Ordering::Acquire) {
                        rpc_error(job.id.clone(), -32800)
                    } else {
                        execute_tool(
                            job.id.clone(),
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
            .map_or(available.len(), |i| i + 1);
        let slice = &available[..consumed];
        if !oversized {
            let remaining = MAX_MCP_FRAME_BYTES
                .saturating_add(1)
                .saturating_sub(bytes.len());
            bytes.extend_from_slice(&slice[..slice.len().min(remaining)]);
            oversized = bytes.len() > MAX_MCP_FRAME_BYTES || (slice.len() > remaining);
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
    let valid = params.and_then(Value::as_object).is_some_and(|object| {
        object.get("protocolVersion").and_then(Value::as_str) == Some(MCP_VERSION)
            && object.get("capabilities").is_some_and(Value::is_object)
            && object.get("clientInfo").is_some_and(Value::is_object)
    });
    if !valid {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    }
    shared.initialized.store(true, Ordering::Release);
    write_json(
        &shared.output,
        rpc_success(
            id,
            json!({
                "protocolVersion": MCP_VERSION,
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
        .unwrap_or_else(|e| e.into_inner())
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
        .unwrap_or_else(|e| e.into_inner())
        .insert(key.clone(), Arc::clone(&cancelled));
    let job = ToolJob {
        id: id.clone(),
        name,
        arguments,
        key: key.clone(),
        cancelled,
    };
    let jobs = shared.jobs.lock().unwrap_or_else(|e| e.into_inner());
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
            .unwrap_or_else(|e| e.into_inner())
            .remove(&job.key);
        write_json(
            &shared.output,
            rpc_success(job.id, tool_error_with_retryability("server_busy", true)),
        );
    }
}

fn execute_tool(id: Value, name: &str, arguments: &Value, cancelled: Arc<AtomicBool>) -> Value {
    let acceptance_root = cfg!(debug_assertions)
        .then(|| std::env::var_os("LICO_CODEX_MCP_ACCEPTANCE_STATE_ROOT"))
        .flatten();
    let root = match acceptance_root
        .clone()
        .map(PathBuf::from)
        .map(Ok)
        .unwrap_or_else(default_orchestrator_state_root)
    {
        Ok(root) => root,
        Err(_) => return rpc_success(id, tool_error("service_unavailable")),
    };
    let timeout = if name == "lico_workflow_wait" {
        Duration::from_millis(
            arguments
                .get("timeoutMs")
                .and_then(Value::as_u64)
                .unwrap_or(0)
                .saturating_add(2_000)
                .min(32_000),
        )
    } else {
        acceptance_timeout()
    };
    let request = match build_codex_mcp_orchestrator_request(name, arguments) {
        Ok(request) => request,
        Err(_) => return rpc_success(id, tool_error("invalid_request")),
    };
    let receipt = OrchestratorIpcClient::new(root.clone())
        .with_client_kind("codex-mcp")
        .with_auto_start(false)
        .with_timeout(timeout)
        .execute_abortable(&request, Arc::clone(&cancelled));
    if cancelled.load(Ordering::Acquire) || receipt.error_code() == Some("request_cancelled") {
        return rpc_error(id, -32800);
    }
    if !receipt.ok {
        return rpc_success(id, tool_error(project_error(&receipt)));
    }
    let Some(result) = receipt.result.as_ref() else {
        return rpc_success(id, tool_error("backend_transport_error"));
    };
    if name == "lico_workflow_status" {
        return execute_status(id, arguments, result, cancelled, timeout, request, root);
    }
    rpc_success(id, tool_success(project_receipt(name, result, None)))
}

fn execute_status(
    id: Value,
    arguments: &Value,
    status: &Value,
    cancelled: Arc<AtomicBool>,
    timeout: Duration,
    first_request: lico_client_native::platform::orchestrator_ipc::OrchestratorIpcRequest,
    root: PathBuf,
) -> Value {
    let events_request = match build_codex_mcp_status_event_request(&first_request, arguments) {
        Ok(request) => request,
        Err(_) => return rpc_success(id, tool_error("invalid_request")),
    };
    if events_request.method != "workflow.events" {
        return rpc_success(id, tool_error("backend_transport_error"));
    }
    let events = OrchestratorIpcClient::new(root)
        .with_client_kind("codex-mcp")
        .with_auto_start(false)
        .with_timeout(timeout)
        .execute_abortable(&events_request, Arc::clone(&cancelled));
    if cancelled.load(Ordering::Acquire) || events.error_code() == Some("request_cancelled") {
        return rpc_error(id, -32800);
    }
    if !events.ok {
        return rpc_success(id, tool_error(project_error(&events)));
    }
    rpc_success(
        id,
        tool_success(project_receipt(
            "lico_workflow_status",
            status,
            events.result.as_ref(),
        )),
    )
}

fn acceptance_timeout() -> Duration {
    let millis = std::env::var("LICO_CODEX_MCP_ACCEPTANCE_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| (50..=30_000).contains(value))
        .unwrap_or(1_000);
    Duration::from_millis(millis)
}

fn project_receipt(name: &str, source: &Value, events: Option<&Value>) -> Value {
    let operation = match name {
        "lico_agent_capabilities" => "agent.capabilities",
        "lico_strategy_preview" => "strategy.preview",
        "lico_workflow_submit" => "workflow.submit",
        "lico_workflow_approve" => "workflow.approve",
        "lico_workflow_cancel" => "workflow.cancel",
        "lico_workflow_wait" => "workflow.wait",
        "lico_workflow_message" => "workflow.message",
        _ => "workflow.status",
    };
    let mut result = Map::new();
    result.insert("schemaVersion".into(), json!("lico.arc.mcp.receipt.v1"));
    result.insert("operation".into(), json!(operation));
    copy_string(source, &mut result, "workflowId", 128);
    copy_string(source, &mut result, "state", 64);
    copy_string(source, &mut result, "admissionState", 64);
    copy_string(source, &mut result, "policyRevisionId", 128);
    copy_string(source, &mut result, "compiledRevisionId", 128);
    copy_string(source, &mut result, "capabilityRevisionId", 128);
    copy_string(source, &mut result, "receiptId", 128);
    copy_string(source, &mut result, "approvalId", 128);
    copy_string(source, &mut result, "messageId", 128);
    copy_string(source, &mut result, "deliveryMode", 64);
    copy_u64(source, &mut result, "cursor");
    copy_u64(source, &mut result, "stepCount");
    copy_u64(source, &mut result, "readyTargetCount");
    for key in ["active", "terminal", "timedOut", "cursorExpired", "hasMore"] {
        if let Some(value) = source.get(key).and_then(Value::as_bool) {
            result.insert(key.into(), json!(value));
        }
    }
    if let Some(source_events) = source.get("events").and_then(Value::as_array) {
        let projected = source_events
            .iter()
            .take(128)
            .map(|event| {
                let mut item = Map::new();
                copy_u64(event, &mut item, "cursor");
                copy_u64(event, &mut item, "outputBytes");
                copy_string(event, &mut item, "type", 128);
                copy_string(event, &mut item, "state", 64);
                copy_string(event, &mut item, "stepId", 128);
                copy_string(event, &mut item, "agentId", 128);
                copy_string(event, &mut item, "deliveryMode", 64);
                Value::Object(item)
            })
            .collect();
        result.insert("events".into(), Value::Array(projected));
        copy_u64(source, &mut result, "nextCursor");
    }
    if let Some(events) = events {
        let projected: Vec<Value> = events["events"]
            .as_array()
            .into_iter()
            .flatten()
            .take(128)
            .map(|event| {
                let mut item = Map::new();
                copy_u64(event, &mut item, "cursor");
                copy_string(event, &mut item, "type", 128);
                copy_string(event, &mut item, "state", 64);
                Value::Object(item)
            })
            .collect();
        result.insert("events".into(), Value::Array(projected));
        copy_u64(events, &mut result, "nextCursor");
        if let Some(value) = events.get("hasMore").and_then(Value::as_bool) {
            result.insert("hasMore".into(), json!(value));
        }
    }
    Value::Object(result)
}

fn copy_string(source: &Value, target: &mut Map<String, Value>, key: &str, max: usize) {
    if let Some(value) = source
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= max)
    {
        target.insert(key.into(), json!(value));
    }
}

fn copy_u64(source: &Value, target: &mut Map<String, Value>, key: &str) {
    if let Some(value) = source.get(key).and_then(Value::as_u64) {
        target.insert(key.into(), json!(value));
    }
}

fn project_error(receipt: &OrchestratorIpcReceipt) -> &'static str {
    match receipt.error_code().unwrap_or("backend_transport_error") {
        "backend_timeout" => "backend_timeout",
        "service_unavailable" => "service_unavailable",
        "private_local_state" | "unsafe_local_state" => "unsafe_local_state",
        "invalid_request" => "invalid_request",
        "idempotency_conflict" => "idempotency_conflict",
        "workflow_unavailable" => "workflow_unavailable",
        "workflow_not_active" | "workflow_terminal" => "workflow_not_active",
        "bridge_queue_full" => "bridge_queue_full",
        "message_artifact_unavailable" | "message_artifact_invalid" | "message_artifact_empty" => {
            "message_artifact_unavailable"
        }
        "capability_rejected" | "capability_missing" => "capability_rejected",
        "operation_forbidden" => "operation_forbidden",
        _ => "backend_transport_error",
    }
}

fn tool_success(value: Value) -> Value {
    let text = serde_json::to_string(&value).unwrap_or_else(|_| "{}".into());
    json!({"content": [{"type": "text", "text": text}], "isError": false, "structuredContent": value})
}

fn tool_error(code: &str) -> Value {
    tool_error_with_retryability(code, false)
}

fn tool_error_with_retryability(code: &str, retryable: bool) -> Value {
    let value = json!({
        "schemaVersion": "lico.arc.mcp.error.v1",
        "reasonCode": code,
        "retryable": retryable
    });
    let text = serde_json::to_string(&value).unwrap_or_else(|_| "{}".into());
    json!({"content": [{"type": "text", "text": text}], "isError": true, "structuredContent": value})
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

fn validate_tool_arguments(name: &str, value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    match name {
        "lico_agent_capabilities" => object.is_empty(),
        "lico_strategy_preview" => {
            exact(object, &["policyRevisionId", "inputDigest"])
                && id_field(object, "policyRevisionId", 128)
                && digest_field(object, "inputDigest")
        }
        "lico_workflow_cancel" => {
            exact(object, &["workflowId", "idempotencyKey"])
                && id_field(object, "workflowId", 128)
                && id_field(object, "idempotencyKey", 128)
        }
        "lico_workflow_approve" => {
            exact(
                object,
                &["workflowId", "approvalId", "decision", "idempotencyKey"],
            ) && id_field(object, "workflowId", 128)
                && id_field(object, "approvalId", 128)
                && matches!(
                    object.get("decision").and_then(Value::as_str),
                    Some("approved" | "rejected")
                )
                && id_field(object, "idempotencyKey", 128)
        }
        "lico_workflow_status" => {
            exact(object, &["workflowId", "afterCursor", "limit"])
                && id_field(object, "workflowId", 128)
                && object
                    .get("afterCursor")
                    .and_then(Value::as_u64)
                    .is_some_and(|value| value <= 9_007_199_254_740_991)
                && object
                    .get("limit")
                    .and_then(Value::as_u64)
                    .is_some_and(|value| (1..=128).contains(&value))
        }
        "lico_workflow_wait" => {
            exact(object, &["workflowId", "afterCursor", "limit", "timeoutMs"])
                && id_field(object, "workflowId", 128)
                && object
                    .get("afterCursor")
                    .and_then(Value::as_u64)
                    .is_some_and(|value| value <= 9_007_199_254_740_991)
                && object
                    .get("limit")
                    .and_then(Value::as_u64)
                    .is_some_and(|value| (1..=128).contains(&value))
                && object
                    .get("timeoutMs")
                    .and_then(Value::as_u64)
                    .is_some_and(|value| value <= 30_000)
        }
        "lico_workflow_message" => {
            let artifact = object.get("messageArtifact").and_then(Value::as_object);
            exact(object, &["workflowId", "messageArtifact", "idempotencyKey"])
                && id_field(object, "workflowId", 128)
                && id_field(object, "idempotencyKey", 128)
                && artifact.is_some_and(|artifact| {
                    exact(artifact, &["handle", "digest"])
                        && id_field(artifact, "handle", 128)
                        && digest_field(artifact, "digest")
                })
        }
        "lico_workflow_submit" => {
            let artifact = object.get("inputArtifact").and_then(Value::as_object);
            exact(
                object,
                &["policyRevisionId", "inputArtifact", "idempotencyKey"],
            ) && id_field(object, "policyRevisionId", 128)
                && id_field(object, "idempotencyKey", 128)
                && artifact.is_some_and(|artifact| {
                    exact(artifact, &["handle", "digest"])
                        && id_field(artifact, "handle", 256)
                        && digest_field(artifact, "digest")
                })
        }
        _ => false,
    }
}

fn exact(object: &Map<String, Value>, keys: &[&str]) -> bool {
    object.len() == keys.len() && keys.iter().all(|key| object.contains_key(*key))
}

fn id_field(object: &Map<String, Value>, key: &str, max: usize) -> bool {
    object
        .get(key)
        .and_then(Value::as_str)
        .is_some_and(|value| !value.is_empty() && value.len() <= max)
}

fn digest_field(object: &Map<String, Value>, key: &str) -> bool {
    object
        .get(key)
        .and_then(Value::as_str)
        .is_some_and(|value| {
            value.len() == 64
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        })
}

fn tool_names() -> [&'static str; 8] {
    [
        "lico_agent_capabilities",
        "lico_strategy_preview",
        "lico_workflow_approve",
        "lico_workflow_cancel",
        "lico_workflow_status",
        "lico_workflow_submit",
        "lico_workflow_wait",
        "lico_workflow_message",
    ]
}

fn tool_catalog() -> Vec<Value> {
    tool_names().into_iter().map(tool_definition).collect()
}

fn string_schema(max: usize) -> Value {
    json!({"type": "string", "minLength": 1, "maxLength": max})
}
fn digest_schema() -> Value {
    json!({"type": "string", "maxLength": 64, "pattern": "^[0-9a-f]{64}$"})
}
fn object_schema(properties: Value, required: &[&str]) -> Value {
    json!({"type": "object", "properties": properties, "required": required, "additionalProperties": false})
}

fn tool_definition(name: &str) -> Value {
    let (description, input) = match name {
        "lico_agent_capabilities" => (
            "Read the redacted local orchestration readiness projection.",
            object_schema(json!({}), &[]),
        ),
        "lico_strategy_preview" => (
            "Preview a pinned policy revision against a digest-bound input.",
            object_schema(
                json!({
                    "policyRevisionId": string_schema(128), "inputDigest": digest_schema()
                }),
                &["policyRevisionId", "inputDigest"],
            ),
        ),
        "lico_workflow_approve" => (
            "Resolve a pending workflow approval using an idempotent command.",
            object_schema(
                json!({
                    "workflowId": string_schema(128), "approvalId": string_schema(128),
                    "decision": {"type": "string", "enum": ["approved", "rejected"]},
                    "idempotencyKey": string_schema(128)
                }),
                &["workflowId", "approvalId", "decision", "idempotencyKey"],
            ),
        ),
        "lico_workflow_cancel" => (
            "Request idempotent cancellation of a backend-owned workflow.",
            object_schema(
                json!({
                    "workflowId": string_schema(128), "idempotencyKey": string_schema(128)
                }),
                &["workflowId", "idempotencyKey"],
            ),
        ),
        "lico_workflow_status" => (
            "Read workflow state and a bounded page of redacted events.",
            object_schema(
                json!({
                    "workflowId": string_schema(128),
                    "afterCursor": {"type": "integer", "minimum": 0, "maximum": 9007199254740991_u64},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 128}
                }),
                &["workflowId", "afterCursor", "limit"],
            ),
        ),
        "lico_workflow_wait" => (
            "Suspend until child progress arrives, the workflow terminates, or the bounded wait expires.",
            object_schema(
                json!({
                    "workflowId": string_schema(128),
                    "afterCursor": {"type": "integer", "minimum": 0, "maximum": 9007199254740991_u64},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 128},
                    "timeoutMs": {"type": "integer", "minimum": 0, "maximum": 30000}
                }),
                &["workflowId", "afterCursor", "limit", "timeoutMs"],
            ),
        ),
        "lico_workflow_message" => (
            "Insert a digest-bound message into an active child conversation; native steer is preferred and exact-session bridge follow-up is the fallback.",
            object_schema(
                json!({
                    "workflowId": string_schema(128),
                    "messageArtifact": object_schema(json!({"handle": string_schema(128), "digest": digest_schema()}), &["handle", "digest"]),
                    "idempotencyKey": string_schema(128)
                }),
                &["workflowId", "messageArtifact", "idempotencyKey"],
            ),
        ),
        _ => (
            "Submit a digest-bound artifact to a pinned backend workflow policy.",
            object_schema(
                json!({
                    "policyRevisionId": string_schema(128),
                    "inputArtifact": object_schema(json!({"handle": string_schema(256), "digest": digest_schema()}), &["handle", "digest"]),
                    "idempotencyKey": string_schema(128)
                }),
                &["policyRevisionId", "inputArtifact", "idempotencyKey"],
            ),
        ),
    };
    json!({"name": name, "description": description, "inputSchema": input, "outputSchema": output_schema()})
}

fn output_schema() -> Value {
    object_schema(
        json!({
            "schemaVersion": {"type": "string", "const": "lico.arc.mcp.receipt.v1"},
            "operation": {"type": "string", "enum": ["agent.capabilities", "strategy.preview", "workflow.submit", "workflow.status", "workflow.cancel", "workflow.approve", "workflow.wait", "workflow.message"]},
            "workflowId": string_schema(128), "state": string_schema(64), "admissionState": string_schema(64),
            "policyRevisionId": string_schema(128), "compiledRevisionId": string_schema(128),
            "capabilityRevisionId": string_schema(128), "receiptId": string_schema(128), "approvalId": string_schema(128),
            "messageId": string_schema(128), "deliveryMode": {"type": "string", "enum": ["native_steer", "bridge_interrupt_resume", "bridge_follow_up"]},
            "cursor": {"type": "integer", "minimum": 0, "maximum": 9007199254740991_u64},
            "stepCount": {"type": "integer", "minimum": 0, "maximum": 4096},
            "readyTargetCount": {"type": "integer", "minimum": 0, "maximum": 4096},
            "events": {"type": "array", "maxItems": 128, "items": object_schema(json!({
                "cursor": {"type": "integer", "minimum": 0, "maximum": 9007199254740991_u64},
                "type": string_schema(128), "state": string_schema(64),
                "stepId": string_schema(128), "agentId": string_schema(128),
                "deliveryMode": {"type": "string", "enum": ["native_steer", "bridge_interrupt_resume", "bridge_follow_up"]},
                "outputBytes": {"type": "integer", "minimum": 0, "maximum": 9007199254740991_u64}
            }), &["cursor", "type", "state"])},
            "nextCursor": {"type": "integer", "minimum": 0, "maximum": 9007199254740991_u64},
            "hasMore": {"type": "boolean"}, "active": {"type": "boolean"},
            "terminal": {"type": "boolean"}, "timedOut": {"type": "boolean"},
            "cursorExpired": {"type": "boolean"}
        }),
        &["schemaVersion", "operation"],
    )
}

fn empty_object(value: Option<&Value>) -> bool {
    value.and_then(Value::as_object).is_some_and(Map::is_empty)
}

fn id_key(id: &Value) -> String {
    serde_json::to_string(id).unwrap_or_else(|_| "null".into())
}

fn extract_id(prefix: &[u8]) -> Value {
    let text = String::from_utf8_lossy(prefix);
    let Some(index) = text.find("\"id\"") else {
        return Value::Null;
    };
    let Some(rest) = text[index + 4..]
        .split_once(':')
        .map(|(_, value)| value.trim_start())
    else {
        return Value::Null;
    };
    if rest.starts_with('"') {
        let tail = &rest[1..];
        return tail
            .find('"')
            .map(|end| json!(&tail[..end]))
            .unwrap_or(Value::Null);
    }
    let digits: String = rest
        .chars()
        .take_while(|ch| ch.is_ascii_digit() || *ch == '-')
        .collect();
    digits
        .parse::<i64>()
        .map_or(Value::Null, |value| json!(value))
}

fn rpc_success(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}
fn rpc_error(id: Value, code: i64) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": "request rejected"}})
}

fn write_json(output: &Mutex<io::Stdout>, value: Value) {
    let mut output = output.lock().unwrap_or_else(|e| e.into_inner());
    if serde_json::to_writer(&mut *output, &value).is_ok() {
        let _ = output.write_all(b"\n");
        let _ = output.flush();
    }
}
