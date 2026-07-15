use super::process_supervisor::{
    BoundedStdinWriter, IO_THREAD_EXIT_GRACE, SupervisedChild, TransportFinishFailure,
    finish_protocol_transport, join_bounded,
};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, SyncSender, TryRecvError};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use time::OffsetDateTime;
use uuid::Uuid;

pub(super) const RUNTIME_PROTOCOL: &str = "hermes-acp-stdio-jsonrpc";

const INITIALIZE_REQUEST_ID: i64 = 1;
const SESSION_REQUEST_ID: i64 = 2;
const MODEL_REQUEST_ID: i64 = 3;
const PROMPT_REQUEST_ID: i64 = 4;
const ACP_PROTOCOL_VERSION: i64 = 1;
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
const CONTROL_ACK_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_PROTOCOL_LINE_BYTES: usize = 8 * 1024 * 1024;
const CONTROL_QUEUE_CAPACITY: usize = 4;
const MAX_POOLED_TRANSPORTS: usize = 8;
const MAX_TRACKED_SESSIONS: usize = 1024;
const MAX_PARKED_PERMISSIONS: usize = 32;
const APPROVAL_WAIT_TIMEOUT: Duration = Duration::from_secs(300);
const APPROVAL_POLL_INTERVAL: Duration = Duration::from_millis(50);

static TRANSPORT_POOL: OnceLock<Mutex<HashMap<TransportKey, Arc<ManagedTransport>>>> =
    OnceLock::new();
static SESSION_TRANSPORTS: OnceLock<Mutex<HashMap<String, Weak<ManagedTransport>>>> =
    OnceLock::new();
static PARKED_PERMISSIONS: OnceLock<Mutex<HashMap<String, ParkedPermission>>> = OnceLock::new();

#[derive(Debug)]
struct ParkedPermission {
    #[allow(dead_code)]
    request_id: Value,
    session_id: String,
    turn_id: String,
    #[allow(dead_code)]
    display_summary: String,
    #[allow(dead_code)]
    option_id: Option<String>,
    decision_tx: SyncSender<bool>,
    created_at: Instant,
}

fn parked_permissions() -> &'static Mutex<HashMap<String, ParkedPermission>> {
    PARKED_PERMISSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Clone, Debug, Default)]
pub(super) struct EffectiveSettings {
    pub(super) cwd: Option<String>,
    pub(super) model: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) sandbox: Option<Value>,
    pub(super) approval_policy: Option<Value>,
}

#[derive(Clone, Debug)]
pub(super) struct ProtocolFailure {
    pub(super) code: &'static str,
    pub(super) message: &'static str,
    pub(super) stage: &'static str,
    pub(super) user_interaction_required: bool,
    pub(super) request_method: Option<String>,
    pub(super) session_id: Option<String>,
    pub(super) turn_id: Option<String>,
    pub(super) turn_status: Option<String>,
}

impl ProtocolFailure {
    fn new(code: &'static str, message: &'static str, stage: &'static str) -> Self {
        Self {
            code,
            message,
            stage,
            user_interaction_required: false,
            request_method: None,
            session_id: None,
            turn_id: None,
            turn_status: None,
        }
    }

    fn user_interaction(method: &str, session_id: Option<&str>, turn_id: Option<&str>) -> Self {
        Self {
            code: "hermes_user_interaction_required",
            message: "Hermes Agent requires explicit user interaction before this turn can continue.",
            stage: "server/request",
            user_interaction_required: true,
            request_method: Some(method.to_string()),
            session_id: session_id.map(str::to_string),
            turn_id: turn_id.map(str::to_string),
            turn_status: None,
        }
    }
}

#[derive(Debug)]
pub(super) struct RunResult {
    pub(super) ok: bool,
    pub(super) output: String,
    pub(super) events: Vec<Value>,
    pub(super) error: Option<ProtocolFailure>,
    pub(super) session_id: String,
    pub(super) thread_id: String,
    pub(super) turn_id: String,
    pub(super) turn_status: String,
    pub(super) effective: EffectiveSettings,
    pub(super) status_code: Option<i32>,
    pub(super) stdout_truncated: bool,
    pub(super) stderr_truncated: bool,
    pub(super) started_at: String,
}

impl RunResult {
    fn failed(
        failure: ProtocolFailure,
        started_at: String,
        status_code: Option<i32>,
        stdout_truncated: bool,
        stderr_truncated: bool,
    ) -> Self {
        let session_id = failure.session_id.clone().unwrap_or_default();
        Self {
            ok: false,
            output: String::new(),
            events: Vec::new(),
            error: Some(failure.clone()),
            thread_id: session_id.clone(),
            session_id,
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            status_code,
            stdout_truncated,
            stderr_truncated,
            started_at,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(super) struct CapabilityProbe {
    pub(super) available: bool,
    pub(super) supported: bool,
    pub(super) version: Option<String>,
    pub(super) error_code: Option<&'static str>,
    pub(super) supports_streaming: bool,
    pub(super) supports_tools: bool,
    pub(super) supports_approvals: bool,
    pub(super) supports_model_override: bool,
    pub(super) supports_reasoning_override: bool,
}

#[derive(Clone, Debug)]
struct ProtocolConfig {
    prompt: String,
    requested_session_id: String,
    cwd: String,
    model: Option<String>,
    turn_id: String,
}

impl ProtocolConfig {
    fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        if prompt.trim().is_empty() {
            return Err(ProtocolFailure::new(
                "hermes_empty_prompt",
                "Hermes Agent requires a non-empty message.",
                "request/validate",
            ));
        }
        if text_param(params, &["reasoningEffort", "reasoning_effort"]).is_some() {
            return Err(ProtocolFailure::new(
                "hermes_acp_reasoning_override_unsupported",
                "Hermes ACP does not expose a per-session reasoning-effort override.",
                "capability/reasoning",
            ));
        }
        if explicit_value(params, &["sandbox", "sandboxMode"]).is_some() {
            return Err(ProtocolFailure::new(
                "hermes_acp_sandbox_override_unsupported",
                "Hermes ACP inherits the native sandbox configuration and has no per-turn override.",
                "capability/sandbox",
            ));
        }
        if explicit_value(params, &["approvalPolicy", "approval_policy"]).is_some() {
            return Err(ProtocolFailure::new(
                "hermes_acp_approval_override_unsupported",
                "Hermes ACP approvals require an explicit client approval response.",
                "capability/approval",
            ));
        }
        let cwd = cwd
            .filter(|path| path.is_absolute())
            .map(|path| path.to_string_lossy().to_string())
            .ok_or_else(|| {
                ProtocolFailure::new(
                    "hermes_acp_absolute_cwd_required",
                    "Hermes ACP requires an absolute working directory.",
                    "request/validate",
                )
            })?;
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id: session_id.trim().to_string(),
            cwd,
            model: text_param(params, &["model", "modelId"]),
            turn_id: Uuid::new_v4().to_string(),
        })
    }

    fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty()
    }
}

#[derive(Clone, Debug)]
struct ProtocolOutcome {
    output: String,
    events: Vec<Value>,
    session_id: String,
    turn_id: String,
    turn_status: String,
    effective: EffectiveSettings,
}

#[derive(Debug)]
enum ProtocolEffect {
    Send(Value),
    Complete(ProtocolOutcome),
    Fail(ProtocolFailure),
    /// Durable pause: keep the ACP process waiting until the user resolves.
    AwaitExternalApproval {
        request_id: Value,
        display_summary: String,
        option_id: Option<String>,
        requested_tools: Vec<String>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ProtocolPhase {
    AwaitInitialize,
    AwaitSession,
    AwaitModel,
    AwaitPrompt,
    Finished,
}

#[derive(Debug)]
struct HermesProtocol {
    config: ProtocolConfig,
    phase: ProtocolPhase,
    session_id: Option<String>,
    output: String,
    events: Vec<Value>,
    effective: EffectiveSettings,
    interaction_failure: Option<ProtocolFailure>,
}

impl HermesProtocol {
    fn new(config: ProtocolConfig) -> Self {
        let effective = EffectiveSettings {
            cwd: Some(config.cwd.clone()),
            model: config.model.clone(),
            ..EffectiveSettings::default()
        };
        Self {
            config,
            phase: ProtocolPhase::AwaitInitialize,
            session_id: None,
            output: String::new(),
            events: Vec::new(),
            effective,
            interaction_failure: None,
        }
    }

    fn new_ready(config: ProtocolConfig) -> Self {
        let mut protocol = Self::new(config);
        protocol.phase = ProtocolPhase::AwaitSession;
        protocol
    }

    fn initial_request(&self) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": INITIALIZE_REQUEST_ID,
            "method": "initialize",
            "params": {
                "protocolVersion": ACP_PROTOCOL_VERSION,
                "clientCapabilities": {
                    "fs": {"readTextFile": false, "writeTextFile": false},
                    "terminal": false,
                    "auth": {"terminal": false}
                },
                "clientInfo": {
                    "name": "lico-arc",
                    "title": "Lico Arc",
                    "version": env!("CARGO_PKG_VERSION")
                }
            }
        })
    }

    fn handle_message(&mut self, message: Value) -> Vec<ProtocolEffect> {
        if let Some(effects) = self.handle_server_request(&message) {
            return effects;
        }
        if message.get("method").is_some() {
            return self.handle_notification(message);
        }
        match self.phase {
            ProtocolPhase::AwaitInitialize
                if request_id_matches(&message, INITIALIZE_REQUEST_ID) =>
            {
                self.handle_initialize_response(&message)
            }
            ProtocolPhase::AwaitSession if request_id_matches(&message, SESSION_REQUEST_ID) => {
                self.handle_session_response(&message)
            }
            ProtocolPhase::AwaitModel if request_id_matches(&message, MODEL_REQUEST_ID) => {
                self.handle_model_response(&message)
            }
            ProtocolPhase::AwaitPrompt if request_id_matches(&message, PROMPT_REQUEST_ID) => {
                self.handle_prompt_response(&message)
            }
            _ => Vec::new(),
        }
    }

    fn handle_server_request(&mut self, message: &Value) -> Option<Vec<ProtocolEffect>> {
        let request_id = message.get("id")?;
        let method = message.get("method")?.as_str()?;
        if message.get("result").is_some() || message.get("error").is_some() {
            return None;
        }
        if method == "session/request_permission" {
            // Fail closed when the lane lacks a durable pause handle (no session).
            let Some(session_id) = self.session_id.as_deref() else {
                return Some(self.fail_closed_permission_denial(request_id, method));
            };
            let params = message.get("params").cloned().unwrap_or(Value::Null);
            if params
                .get("sessionId")
                .and_then(Value::as_str)
                .is_some_and(|id| id != session_id)
            {
                return Some(self.fail_closed_permission_denial(request_id, method));
            }
            let (display_summary, option_id, requested_tools) =
                permission_request_display_safe(&params);
            return Some(vec![ProtocolEffect::AwaitExternalApproval {
                request_id: request_id.clone(),
                display_summary,
                option_id,
                requested_tools,
            }]);
        }
        self.interaction_failure = Some(ProtocolFailure::user_interaction(
            method,
            self.session_id.as_deref(),
            Some(&self.config.turn_id),
        ));
        let mut effects = vec![ProtocolEffect::Send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": "Client method is not available."}
        }))];
        if let Some(session_id) = self.session_id.as_deref() {
            effects.push(ProtocolEffect::Send(json!({
                "jsonrpc": "2.0",
                "method": "session/cancel",
                "params": {"sessionId": session_id}
            })));
        }
        Some(effects)
    }

    fn fail_closed_permission_denial(
        &mut self,
        request_id: &Value,
        method: &str,
    ) -> Vec<ProtocolEffect> {
        self.interaction_failure = Some(ProtocolFailure::user_interaction(
            method,
            self.session_id.as_deref(),
            Some(&self.config.turn_id),
        ));
        let mut effects = vec![ProtocolEffect::Send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {"outcome": {"outcome": "cancelled"}}
        }))];
        if let Some(session_id) = self.session_id.as_deref() {
            effects.push(ProtocolEffect::Send(json!({
                "jsonrpc": "2.0",
                "method": "session/cancel",
                "params": {"sessionId": session_id}
            })));
        }
        effects
    }

    fn handle_initialize_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "hermes_acp_initialize_failed",
                "Hermes ACP initialization failed.",
                "initialize",
            ))];
        }
        let protocol_version = message
            .pointer("/result/protocolVersion")
            .and_then(Value::as_i64);
        let load_session = message
            .pointer("/result/agentCapabilities/loadSession")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if protocol_version != Some(ACP_PROTOCOL_VERSION) || !load_session {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "hermes_acp_capability_mismatch",
                "Hermes ACP does not expose the required conversation lifecycle.",
                "initialize/capabilities",
            ))];
        }
        self.phase = ProtocolPhase::AwaitSession;
        vec![ProtocolEffect::Send(self.session_request())]
    }

    fn session_request(&self) -> Value {
        let mut params = Map::new();
        params.insert("cwd".to_string(), json!(self.config.cwd));
        params.insert("mcpServers".to_string(), json!([]));
        let method = if self.config.is_resume() {
            params.insert(
                "sessionId".to_string(),
                json!(self.config.requested_session_id),
            );
            "session/load"
        } else {
            "session/new"
        };
        json!({
            "jsonrpc": "2.0",
            "id": SESSION_REQUEST_ID,
            "method": method,
            "params": params
        })
    }

    fn handle_session_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.failure_with_ids(
                "hermes_acp_session_open_failed",
                "Hermes ACP could not open the requested conversation.",
                if self.config.is_resume() {
                    "session/load"
                } else {
                    "session/new"
                },
            ))];
        }
        let session_id = if self.config.is_resume() {
            if message
                .pointer("/result/sessionId")
                .and_then(Value::as_str)
                .is_some_and(|returned| returned != self.config.requested_session_id)
            {
                self.phase = ProtocolPhase::Finished;
                return vec![ProtocolEffect::Fail(self.failure_with_ids(
                    "hermes_acp_session_mismatch",
                    "Hermes ACP returned a different conversation than the one requested.",
                    "session/load",
                ))];
            }
            self.config.requested_session_id.clone()
        } else {
            message
                .pointer("/result/sessionId")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
                .unwrap_or_default()
        };
        if session_id.is_empty() {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "hermes_acp_session_id_missing",
                "Hermes ACP did not return a native conversation identifier.",
                "session/open",
            ))];
        }
        self.session_id = Some(session_id);
        self.capture_effective_controls(message.get("result"));
        if self.config.model.is_some() {
            self.phase = ProtocolPhase::AwaitModel;
            vec![ProtocolEffect::Send(self.model_request())]
        } else {
            self.phase = ProtocolPhase::AwaitPrompt;
            vec![ProtocolEffect::Send(self.prompt_request())]
        }
    }

    fn model_request(&self) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": MODEL_REQUEST_ID,
            "method": "session/set_model",
            "params": {
                "sessionId": self.session_id,
                "modelId": self.config.model
            }
        })
    }

    fn handle_model_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.failure_with_ids(
                "hermes_acp_model_override_failed",
                "Hermes ACP could not apply the requested model.",
                "session/set_model",
            ))];
        }
        self.effective.model = self.config.model.clone();
        self.phase = ProtocolPhase::AwaitPrompt;
        vec![ProtocolEffect::Send(self.prompt_request())]
    }

    fn prompt_request(&self) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": PROMPT_REQUEST_ID,
            "method": "session/prompt",
            "params": {
                "sessionId": self.session_id,
                "prompt": [{"type": "text", "text": self.config.prompt}]
            }
        })
    }

    fn handle_prompt_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.failure_with_ids(
                "hermes_acp_prompt_failed",
                "Hermes ACP could not complete the requested turn.",
                "session/prompt",
            ))];
        }
        let stop_reason = message
            .pointer("/result/stopReason")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        self.phase = ProtocolPhase::Finished;
        if let Some(mut failure) = self.interaction_failure.take() {
            failure.turn_status = Some(stop_reason);
            return vec![ProtocolEffect::Fail(failure)];
        }
        // Cancelled / interrupted turns still expose the native session id on the
        // failure so a later boundary send can exact-resume that same conversation.
        if !matches!(
            stop_reason.as_str(),
            "end_turn" | "max_tokens" | "max_turn_requests"
        ) {
            let mut failure = self.failure_with_ids(
                "hermes_acp_turn_not_completed",
                "Hermes ACP did not complete the requested turn.",
                "session/prompt",
            );
            failure.turn_status = Some(stop_reason);
            return vec![ProtocolEffect::Fail(failure)];
        }
        if self.output.is_empty() {
            let mut failure = self.failure_with_ids(
                "hermes_acp_final_message_missing",
                "Hermes ACP completed the turn without a final agent message.",
                "session/prompt",
            );
            failure.turn_status = Some(stop_reason);
            return vec![ProtocolEffect::Fail(failure)];
        }
        let session_id = self.session_id.clone().unwrap_or_default();
        super::turn_event_emit::emit_agent_message_completed(
            &session_id,
            &self.config.turn_id,
            &self.output,
        );
        vec![ProtocolEffect::Complete(ProtocolOutcome {
            output: self.output.clone(),
            events: self.events.clone(),
            session_id,
            turn_id: self.config.turn_id.clone(),
            turn_status: stop_reason,
            effective: self.effective.clone(),
        })]
    }

    fn handle_notification(&mut self, message: Value) -> Vec<ProtocolEffect> {
        if message.get("method").and_then(Value::as_str) != Some("session/update") {
            return Vec::new();
        }
        let Some(params) = message.get("params") else {
            return Vec::new();
        };
        if params.get("sessionId").and_then(Value::as_str) != self.session_id.as_deref() {
            return Vec::new();
        }
        let Some(update) = params.get("update") else {
            return Vec::new();
        };
        let update_type = update.get("sessionUpdate").and_then(Value::as_str);
        if self.phase == ProtocolPhase::AwaitPrompt {
            self.events.push(update.clone());
            if update_type == Some("agent_message_chunk")
                && let Some(text) = update.pointer("/content/text").and_then(Value::as_str)
            {
                self.output.push_str(text);
                super::turn_event_emit::emit_agent_message_chunk(
                    self.session_id.as_deref().unwrap_or_default(),
                    &self.config.turn_id,
                    text,
                );
            }
        }
        if update_type == Some("current_mode_update")
            && let Some(mode) = update.get("currentModeId").and_then(Value::as_str)
        {
            self.effective.approval_policy = Some(json!(mode));
        }
        Vec::new()
    }

    fn capture_effective_controls(&mut self, result: Option<&Value>) {
        let Some(result) = result else {
            return;
        };
        if self.config.model.is_none()
            && let Some(model) = result
                .pointer("/models/currentModelId")
                .and_then(Value::as_str)
        {
            self.effective.model = Some(model.to_string());
        }
        if let Some(mode) = result
            .pointer("/modes/currentModeId")
            .and_then(Value::as_str)
        {
            self.effective.approval_policy = Some(json!(mode));
        }
    }

    fn failure_with_ids(
        &self,
        code: &'static str,
        message: &'static str,
        stage: &'static str,
    ) -> ProtocolFailure {
        let mut failure = ProtocolFailure::new(code, message, stage);
        failure.session_id = self.session_id.clone().or_else(|| {
            (!self.config.requested_session_id.is_empty())
                .then(|| self.config.requested_session_id.clone())
        });
        failure.turn_id = Some(self.config.turn_id.clone());
        failure
    }
}

#[derive(Debug)]
struct LaunchSpec {
    executable: String,
    args: [&'static str; 1],
    cwd: PathBuf,
}

impl LaunchSpec {
    fn new(executable: &str, cwd: &Path) -> Self {
        Self {
            executable: executable.to_string(),
            args: ["acp"],
            cwd: cwd.to_path_buf(),
        }
    }

    fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(self.args)
            .current_dir(&self.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        SupervisedChild::spawn(&mut command)
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct TransportKey {
    executable: String,
    cwd: PathBuf,
}

impl TransportKey {
    fn new(executable: &str, cwd: &Path) -> Self {
        Self {
            executable: executable.to_string(),
            cwd: cwd.to_path_buf(),
        }
    }
}

#[derive(Debug)]
enum ControlRequest {
    Cancel {
        session_id: String,
        acknowledged: SyncSender<bool>,
    },
    Cleanup {
        acknowledged: SyncSender<bool>,
    },
}

#[derive(Debug)]
struct ManagedTransport {
    key: TransportKey,
    transport: Mutex<PersistentTransport>,
    control_sender: SyncSender<ControlRequest>,
    active_session: Mutex<Option<String>>,
}

#[derive(Debug)]
struct PersistentTransport {
    child: SupervisedChild,
    stdin: BoundedStdinWriter,
    receiver: Receiver<TransportEvent>,
    control_receiver: Receiver<ControlRequest>,
    stdout_handle: Option<thread::JoinHandle<()>>,
    stderr_handle: Option<thread::JoinHandle<()>>,
    stderr_truncated: Arc<AtomicBool>,
    closed: bool,
}

impl PersistentTransport {
    fn spawn(
        launch: &LaunchSpec,
        control_receiver: Receiver<ControlRequest>,
        timeout_ms: u64,
        max_stdout: usize,
        max_stderr: usize,
    ) -> Result<Self, ProtocolFailure> {
        let mut child = launch.spawn().map_err(|error| {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The Hermes Agent executable is not available.",
                io::ErrorKind::PermissionDenied => {
                    "The Hermes Agent executable is not permitted to run."
                }
                _ => "Hermes ACP could not be started.",
            };
            ProtocolFailure::new("hermes_acp_start_failed", message, "process/start")
        })?;
        let stdout = child.stdout().ok_or_else(|| {
            ProtocolFailure::new(
                "hermes_acp_pipe_failed",
                "Hermes ACP stdout is unavailable.",
                "process/start",
            )
        })?;
        let stderr = child.stderr().ok_or_else(|| {
            ProtocolFailure::new(
                "hermes_acp_pipe_failed",
                "Hermes ACP stderr is unavailable.",
                "process/start",
            )
        })?;
        let stdin = child.stdin().ok_or_else(|| {
            ProtocolFailure::new(
                "hermes_acp_pipe_failed",
                "Hermes ACP stdin is unavailable.",
                "process/start",
            )
        })?;
        let stdin = BoundedStdinWriter::new(stdin);
        let (sender, receiver) = mpsc::channel();
        let stdout_handle =
            thread::spawn(move || read_protocol_messages(BufReader::new(stdout), sender));
        let stderr_truncated = Arc::new(AtomicBool::new(false));
        let stderr_flag = Arc::clone(&stderr_truncated);
        let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));
        let mut transport = Self {
            child,
            stdin,
            receiver,
            control_receiver,
            stdout_handle: Some(stdout_handle),
            stderr_handle: Some(stderr_handle),
            stderr_truncated,
            closed: false,
        };
        if let Err(failure) = transport.initialize(timeout_ms, max_stdout) {
            let _ = transport.shutdown();
            return Err(failure);
        }
        Ok(transport)
    }

    fn initialize(&mut self, timeout_ms: u64, max_stdout: usize) -> Result<(), ProtocolFailure> {
        let request = HermesProtocol::new(ProtocolConfig {
            prompt: String::new(),
            requested_session_id: String::new(),
            cwd: String::new(),
            model: None,
            turn_id: String::new(),
        })
        .initial_request();
        write_message(&mut self.stdin, &request).map_err(|_| {
            ProtocolFailure::new(
                "hermes_acp_write_failed",
                "Hermes ACP stopped accepting protocol messages.",
                "initialize",
            )
        })?;
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        let mut observed_bytes = 0usize;
        loop {
            if self.stdin.check_health().is_err() {
                return Err(ProtocolFailure::new(
                    "hermes_acp_write_failed",
                    "Hermes ACP stopped accepting protocol messages.",
                    "initialize",
                ));
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(ProtocolFailure::new(
                    "hermes_acp_timeout",
                    "Hermes ACP timed out during initialization.",
                    "initialize",
                ));
            }
            match self
                .receiver
                .recv_timeout((deadline - now).min(PROCESS_POLL_INTERVAL))
            {
                Ok(TransportEvent::Message { message, bytes }) => {
                    observed_bytes = observed_bytes.saturating_add(bytes);
                    if observed_bytes > max_stdout {
                        return Err(ProtocolFailure::new(
                            "hermes_acp_output_limit",
                            "Hermes ACP exceeded the configured protocol output limit.",
                            "initialize",
                        ));
                    }
                    if !request_id_matches(&message, INITIALIZE_REQUEST_ID) {
                        continue;
                    }
                    if response_is_error(&message) {
                        return Err(ProtocolFailure::new(
                            "hermes_acp_initialize_failed",
                            "Hermes ACP initialization failed.",
                            "initialize",
                        ));
                    }
                    let version = message
                        .pointer("/result/protocolVersion")
                        .and_then(Value::as_i64);
                    let load_session = message
                        .pointer("/result/agentCapabilities/loadSession")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    if version != Some(ACP_PROTOCOL_VERSION) || !load_session {
                        return Err(ProtocolFailure::new(
                            "hermes_acp_capability_mismatch",
                            "Hermes ACP does not expose the required conversation lifecycle.",
                            "initialize/capabilities",
                        ));
                    }
                    return Ok(());
                }
                Ok(TransportEvent::InvalidJson) => {
                    return Err(ProtocolFailure::new(
                        "hermes_acp_invalid_json",
                        "Hermes ACP returned an invalid protocol message.",
                        "initialize",
                    ));
                }
                Ok(TransportEvent::LineLimitExceeded) => {
                    return Err(ProtocolFailure::new(
                        "hermes_acp_output_limit",
                        "Hermes ACP exceeded the hard protocol line limit.",
                        "initialize",
                    ));
                }
                Ok(TransportEvent::StdoutReadFailed) => {
                    return Err(ProtocolFailure::new(
                        "hermes_acp_read_failed",
                        "Hermes ACP protocol output could not be read.",
                        "initialize",
                    ));
                }
                Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                    return Err(ProtocolFailure::new(
                        "hermes_acp_exited",
                        "Hermes ACP exited during initialization.",
                        "process/exit",
                    ));
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
    }

    fn shutdown(&mut self) -> Result<(), TransportFinishFailure> {
        if self.closed {
            return Ok(());
        }
        self.closed = true;
        let Some(stdout_handle) = self.stdout_handle.take() else {
            return Err(TransportFinishFailure::Lifecycle);
        };
        let Some(stderr_handle) = self.stderr_handle.take() else {
            return Err(TransportFinishFailure::Lifecycle);
        };
        finish_protocol_transport(
            &mut self.child,
            &mut self.stdin,
            stdout_handle,
            stderr_handle,
        )
    }
}

impl Drop for PersistentTransport {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

#[derive(Debug)]
enum TransportEvent {
    Message { message: Value, bytes: usize },
    InvalidJson,
    LineLimitExceeded,
    StdoutReadFailed,
    StdoutClosed,
}

pub(super) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> RunResult {
    let started_at = timestamp();
    let config = match ProtocolConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => return RunResult::failed(failure, started_at, None, false, false),
    };
    let managed = match acquire_transport(
        executable,
        Path::new(&config.cwd),
        timeout_ms,
        max_stdout,
        max_stderr,
    ) {
        Ok(managed) => managed,
        Err(failure) => return RunResult::failed(failure, started_at, None, false, false),
    };
    let mut transport = match managed.transport.lock() {
        Ok(transport) => transport,
        Err(_) => {
            remove_transport(&managed, false);
            return RunResult::failed(
                ProtocolFailure::new(
                    "hermes_acp_supervisor_unavailable",
                    "Hermes ACP supervisor state is unavailable.",
                    "process/supervisor",
                ),
                started_at,
                None,
                false,
                false,
            );
        }
    };
    let mut protocol = HermesProtocol::new_ready(config);
    // An empty value is an internal "session/open in progress" marker. It lets
    // cleanup interrupt a new turn before Hermes has returned its native ID.
    set_active_session(&managed, Some(protocol.config.requested_session_id.clone()));
    let initial_write = write_message(&mut transport.stdin, &protocol.session_request());
    let (outcome, failure, stdout_was_truncated) = if initial_write.is_err() {
        (
            None,
            Some(protocol.failure_with_ids(
                "hermes_acp_write_failed",
                "Hermes ACP stopped accepting protocol messages.",
                "protocol/write",
            )),
            false,
        )
    } else {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        run_protocol_loop(
            &mut transport,
            &managed,
            &mut protocol,
            deadline,
            max_stdout,
        )
    };
    let stderr_was_truncated = transport.stderr_truncated.load(Ordering::Relaxed);
    set_active_session(&managed, None);
    let reset_transport = failure
        .as_ref()
        .is_some_and(failure_requires_transport_reset);
    drop(transport);

    if let Some(outcome) = outcome {
        register_session(&outcome.session_id, &managed);
        return RunResult {
            ok: true,
            output: outcome.output,
            events: outcome.events,
            error: None,
            thread_id: outcome.session_id.clone(),
            session_id: outcome.session_id,
            turn_id: outcome.turn_id,
            turn_status: outcome.turn_status,
            effective: outcome.effective,
            status_code: None,
            stdout_truncated: stdout_was_truncated,
            stderr_truncated: stderr_was_truncated,
            started_at,
        };
    }
    let failure = failure.unwrap_or_else(|| {
        ProtocolFailure::new(
            "hermes_acp_failed",
            "Hermes ACP did not complete the request.",
            "protocol",
        )
    });
    if reset_transport {
        remove_transport(&managed, true);
    }
    RunResult::failed(
        failure,
        started_at,
        None,
        stdout_was_truncated,
        stderr_was_truncated,
    )
}

fn run_protocol_loop(
    transport: &mut PersistentTransport,
    managed: &Arc<ManagedTransport>,
    protocol: &mut HermesProtocol,
    deadline: Instant,
    max_stdout: usize,
) -> (Option<ProtocolOutcome>, Option<ProtocolFailure>, bool) {
    let mut observed_bytes = 0usize;
    loop {
        if let Some(failure) = handle_control_requests(transport, protocol) {
            return (None, Some(failure), false);
        }
        if transport.stdin.check_health().is_err() {
            return (
                None,
                Some(protocol.failure_with_ids(
                    "hermes_acp_write_failed",
                    "Hermes ACP stopped accepting protocol messages.",
                    "protocol/write",
                )),
                false,
            );
        }
        let now = Instant::now();
        if now >= deadline {
            let mut failure = protocol.failure_with_ids(
                "hermes_acp_timeout",
                "Hermes ACP timed out before the turn completed.",
                "turn/wait",
            );
            failure.turn_status = Some("timeout".to_string());
            return (None, Some(failure), false);
        }
        match transport
            .receiver
            .recv_timeout((deadline - now).min(PROCESS_POLL_INTERVAL))
        {
            Ok(TransportEvent::Message { message, bytes }) => {
                observed_bytes = observed_bytes.saturating_add(bytes);
                if observed_bytes > max_stdout {
                    return (
                        None,
                        Some(protocol.failure_with_ids(
                            "hermes_acp_output_limit",
                            "Hermes ACP exceeded the configured protocol output limit.",
                            "protocol/read",
                        )),
                        true,
                    );
                }
                for effect in protocol.handle_message(message) {
                    match effect {
                        ProtocolEffect::Send(message) => {
                            if write_message(&mut transport.stdin, &message).is_err() {
                                return (
                                    None,
                                    Some(protocol.failure_with_ids(
                                        "hermes_acp_write_failed",
                                        "Hermes ACP stopped accepting protocol messages.",
                                        "protocol/write",
                                    )),
                                    false,
                                );
                            }
                        }
                        ProtocolEffect::Complete(outcome) => {
                            return (Some(outcome), None, false);
                        }
                        ProtocolEffect::Fail(failure) => {
                            return (None, Some(failure), false);
                        }
                        ProtocolEffect::AwaitExternalApproval {
                            request_id,
                            display_summary,
                            option_id,
                            requested_tools,
                        } => {
                            match await_external_approval(
                                transport,
                                protocol,
                                &request_id,
                                &display_summary,
                                option_id.as_deref(),
                                &requested_tools,
                                deadline,
                            ) {
                                Ok(ApprovalWaitOutcome::Allowed) => {}
                                Ok(ApprovalWaitOutcome::Denied) => {
                                    // Denial was written; continue until prompt returns cancelled.
                                }
                                Err(failure) => return (None, Some(failure), false),
                            }
                        }
                    }
                }
                if let Ok(mut active) = managed.active_session.lock() {
                    *active = protocol.session_id.clone();
                }
                if let Some(session_id) = protocol.session_id.as_deref() {
                    register_session(session_id, managed);
                }
            }
            Ok(TransportEvent::InvalidJson) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "hermes_acp_invalid_json",
                        "Hermes ACP returned an invalid protocol message.",
                        "protocol/read",
                    )),
                    false,
                );
            }
            Ok(TransportEvent::LineLimitExceeded) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "hermes_acp_output_limit",
                        "Hermes ACP exceeded the configured protocol output limit.",
                        "protocol/read",
                    )),
                    true,
                );
            }
            Ok(TransportEvent::StdoutReadFailed) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "hermes_acp_read_failed",
                        "Hermes ACP protocol output could not be read.",
                        "protocol/read",
                    )),
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "hermes_acp_exited",
                        "Hermes ACP exited before the turn completed.",
                        "process/exit",
                    )),
                    false,
                );
            }
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

fn acquire_transport(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> Result<Arc<ManagedTransport>, ProtocolFailure> {
    let key = TransportKey::new(executable, cwd);
    if let Some(existing) = transport_pool()
        .lock()
        .map_err(|_| supervisor_failure())?
        .get(&key)
        .cloned()
    {
        return Ok(existing);
    }
    if transport_pool()
        .lock()
        .map_err(|_| supervisor_failure())?
        .len()
        >= MAX_POOLED_TRANSPORTS
    {
        return Err(ProtocolFailure::new(
            "hermes_acp_transport_capacity",
            "Hermes ACP reached the bounded persistent transport capacity.",
            "process/supervisor",
        ));
    }
    let (control_sender, control_receiver) = mpsc::sync_channel(CONTROL_QUEUE_CAPACITY);
    let launch = LaunchSpec::new(executable, cwd);
    let transport = PersistentTransport::spawn(
        &launch,
        control_receiver,
        timeout_ms,
        max_stdout,
        max_stderr,
    )?;
    let candidate = Arc::new(ManagedTransport {
        key: key.clone(),
        transport: Mutex::new(transport),
        control_sender,
        active_session: Mutex::new(None),
    });
    let mut pool = transport_pool().lock().map_err(|_| supervisor_failure())?;
    if let Some(existing) = pool.get(&key).cloned() {
        return Ok(existing);
    }
    if pool.len() >= MAX_POOLED_TRANSPORTS {
        return Err(ProtocolFailure::new(
            "hermes_acp_transport_capacity",
            "Hermes ACP reached the bounded persistent transport capacity.",
            "process/supervisor",
        ));
    }
    pool.insert(key, Arc::clone(&candidate));
    Ok(candidate)
}

fn transport_pool() -> &'static Mutex<HashMap<TransportKey, Arc<ManagedTransport>>> {
    TRANSPORT_POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn session_transports() -> &'static Mutex<HashMap<String, Weak<ManagedTransport>>> {
    SESSION_TRANSPORTS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn register_session(session_id: &str, managed: &Arc<ManagedTransport>) {
    if session_id.is_empty() {
        return;
    }
    if let Ok(mut sessions) = session_transports().lock() {
        sessions.retain(|_, transport| transport.strong_count() > 0);
        if sessions.len() >= MAX_TRACKED_SESSIONS && !sessions.contains_key(session_id) {
            if let Some(oldest_available) = sessions.keys().next().cloned() {
                sessions.remove(&oldest_available);
            }
        }
        sessions.insert(session_id.to_string(), Arc::downgrade(managed));
    }
}

fn set_active_session(managed: &ManagedTransport, session_id: Option<String>) {
    if let Ok(mut active) = managed.active_session.lock() {
        *active = session_id;
    }
}

fn remove_transport(managed: &Arc<ManagedTransport>, cleanup: bool) {
    if let Ok(mut pool) = transport_pool().lock() {
        if pool
            .get(&managed.key)
            .is_some_and(|current| Arc::ptr_eq(current, managed))
        {
            pool.remove(&managed.key);
        }
    }
    if let Ok(mut sessions) = session_transports().lock() {
        sessions.retain(|_, weak| {
            weak.upgrade()
                .is_some_and(|current| !Arc::ptr_eq(&current, managed))
        });
    }
    if cleanup && let Ok(mut transport) = managed.transport.lock() {
        let _ = transport.shutdown();
    }
}

fn supervisor_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "hermes_acp_supervisor_unavailable",
        "Hermes ACP supervisor state is unavailable.",
        "process/supervisor",
    )
}

fn failure_requires_transport_reset(failure: &ProtocolFailure) -> bool {
    matches!(
        failure.code,
        "hermes_acp_write_failed"
            | "hermes_acp_timeout"
            | "hermes_acp_invalid_json"
            | "hermes_acp_output_limit"
            | "hermes_acp_read_failed"
            | "hermes_acp_exited"
            | "hermes_acp_cleanup_requested"
    )
}

fn handle_control_requests(
    transport: &mut PersistentTransport,
    protocol: &HermesProtocol,
) -> Option<ProtocolFailure> {
    loop {
        match transport.control_receiver.try_recv() {
            Ok(ControlRequest::Cancel {
                session_id,
                acknowledged,
            }) => {
                let matches = protocol.session_id.as_deref() == Some(session_id.as_str());
                let written = matches
                    && write_message(
                        &mut transport.stdin,
                        &json!({
                            "jsonrpc": "2.0",
                            "method": "session/cancel",
                            "params": {"sessionId": session_id}
                        }),
                    )
                    .is_ok();
                let _ = acknowledged.send(written);
                if matches && !written {
                    return Some(protocol.failure_with_ids(
                        "hermes_acp_write_failed",
                        "Hermes ACP stopped accepting protocol messages.",
                        "session/cancel",
                    ));
                }
            }
            Ok(ControlRequest::Cleanup { acknowledged }) => {
                if let Some(session_id) = protocol.session_id.as_deref() {
                    let _ = write_message(
                        &mut transport.stdin,
                        &json!({
                            "jsonrpc": "2.0",
                            "method": "session/cancel",
                            "params": {"sessionId": session_id}
                        }),
                    );
                }
                let _ = acknowledged.send(true);
                return Some(protocol.failure_with_ids(
                    "hermes_acp_cleanup_requested",
                    "Hermes ACP transport cleanup was requested.",
                    "process/cleanup",
                ));
            }
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => {
                return Some(protocol.failure_with_ids(
                    "hermes_acp_supervisor_unavailable",
                    "Hermes ACP supervisor control channel is unavailable.",
                    "process/supervisor",
                ));
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ControlDisposition {
    Accepted,
    NoActiveTurn,
    SessionUnavailable,
    TransportUnavailable,
}

pub(super) fn cancel(session_id: &str) -> ControlDisposition {
    let managed = match lookup_session_transport(session_id) {
        Some(managed) => managed,
        None => return ControlDisposition::SessionUnavailable,
    };
    let is_active = managed
        .active_session
        .lock()
        .ok()
        .and_then(|active| active.clone())
        .as_deref()
        == Some(session_id);
    if !is_active {
        return ControlDisposition::NoActiveTurn;
    }
    let (acknowledged, receiver) = mpsc::sync_channel(1);
    if managed
        .control_sender
        .try_send(ControlRequest::Cancel {
            session_id: session_id.to_string(),
            acknowledged,
        })
        .is_err()
    {
        return ControlDisposition::TransportUnavailable;
    }
    match receiver.recv_timeout(CONTROL_ACK_TIMEOUT) {
        Ok(true) => ControlDisposition::Accepted,
        Ok(false) => ControlDisposition::NoActiveTurn,
        Err(_) => ControlDisposition::TransportUnavailable,
    }
}

pub(super) fn cleanup_session(session_id: &str) -> ControlDisposition {
    let managed = match lookup_session_transport(session_id) {
        Some(managed) => managed,
        None => return ControlDisposition::SessionUnavailable,
    };
    if !request_cleanup_if_active(&managed) {
        return ControlDisposition::TransportUnavailable;
    }
    remove_transport(&managed, true);
    ControlDisposition::Accepted
}

fn request_cleanup_if_active(managed: &ManagedTransport) -> bool {
    let active = managed
        .active_session
        .lock()
        .ok()
        .is_some_and(|active| active.is_some());
    if !active {
        return true;
    }
    let (acknowledged, receiver) = mpsc::sync_channel(1);
    managed
        .control_sender
        .try_send(ControlRequest::Cleanup { acknowledged })
        .is_ok()
        && receiver.recv_timeout(CONTROL_ACK_TIMEOUT) == Ok(true)
}

fn lookup_session_transport(session_id: &str) -> Option<Arc<ManagedTransport>> {
    if session_id.trim().is_empty() {
        return None;
    }
    session_transports()
        .lock()
        .ok()?
        .get(session_id)
        .and_then(Weak::upgrade)
}

#[derive(Debug)]
enum ApprovalWaitOutcome {
    Allowed,
    Denied,
}

/// Resolve a parked Hermes permission request. Fail-closed when the token is gone.
///
/// Works across processes: the conversation send process parks and polls a
/// decision file under the portable data dir; approval respond writes that file.
pub fn resolve_parked_permission(token: &str, allow: bool) -> Result<Value, &'static str> {
    let trimmed = token.trim();
    if trimmed.is_empty() {
        return Err("hermes_approval_token_missing");
    }
    // Prefer in-process channel when the park lives in this process.
    let parked = {
        let mut guard = parked_permissions()
            .lock()
            .map_err(|_| "hermes_approval_park_unavailable")?;
        guard.remove(trimmed)
    };
    if let Some(parked) = parked {
        let _ = parked.decision_tx.send(allow);
        let _ = write_park_decision_file(trimmed, allow);
        return Ok(json!({
            "ok": true,
            "agentId": "hermes",
            "adapterCallbackTokenRef": trimmed,
            "decision": if allow { "allow" } else { "deny" },
            "sessionId": parked.session_id,
            "turnId": parked.turn_id,
            "parkAgeMs": parked.created_at.elapsed().as_millis() as u64,
            "signal": "in-process",
        }));
    }
    // Cross-process: signal the parked send process via durable decision file.
    if !park_metadata_exists(trimmed) {
        return Err("hermes_approval_park_missing");
    }
    write_park_decision_file(trimmed, allow)
        .map_err(|_| "hermes_approval_decision_write_failed")?;
    Ok(json!({
        "ok": true,
        "agentId": "hermes",
        "adapterCallbackTokenRef": trimmed,
        "decision": if allow { "allow" } else { "deny" },
        "signal": "decision-file",
    }))
}

fn hermes_approval_park_root() -> Result<PathBuf, &'static str> {
    let root = super::paths::portable_data_dir()
        .map_err(|_| "hermes_approval_park_root_unavailable")?
        .join("hermes-approval-parks");
    std::fs::create_dir_all(&root).map_err(|_| "hermes_approval_park_root_unavailable")?;
    Ok(root)
}

fn park_metadata_path(token: &str) -> Result<PathBuf, &'static str> {
    Ok(hermes_approval_park_root()?.join(format!("{token}.park.json")))
}

fn park_decision_path(token: &str) -> Result<PathBuf, &'static str> {
    Ok(hermes_approval_park_root()?.join(format!("{token}.decision")))
}

fn park_metadata_exists(token: &str) -> bool {
    park_metadata_path(token)
        .ok()
        .is_some_and(|path| path.is_file())
}

fn write_park_metadata_file(
    token: &str,
    session_id: &str,
    turn_id: &str,
    display_summary: &str,
) -> Result<(), &'static str> {
    let path = park_metadata_path(token)?;
    let body = json!({
        "adapterCallbackTokenRef": token,
        "agentId": "hermes",
        "sessionId": session_id,
        "turnId": turn_id,
        "displaySummary": display_summary,
        "createdAtMs": SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|value| value.as_millis() as u64)
            .unwrap_or(0),
    });
    std::fs::write(path, body.to_string()).map_err(|_| "hermes_approval_park_write_failed")
}

fn write_park_decision_file(token: &str, allow: bool) -> Result<(), &'static str> {
    let path = park_decision_path(token)?;
    std::fs::write(path, if allow { b"allow" as &[u8] } else { b"deny" })
        .map_err(|_| "hermes_approval_decision_write_failed")
}

fn read_park_decision_file(token: &str) -> Option<bool> {
    let path = park_decision_path(token).ok()?;
    let bytes = std::fs::read_to_string(path).ok()?;
    match bytes.trim() {
        "allow" | "approve" | "approved" => Some(true),
        "deny" | "denied" | "reject" | "rejected" => Some(false),
        _ => None,
    }
}

fn clear_park_files(token: &str) {
    if let Ok(path) = park_metadata_path(token) {
        let _ = std::fs::remove_file(path);
    }
    if let Ok(path) = park_decision_path(token) {
        let _ = std::fs::remove_file(path);
    }
}

fn permission_request_display_safe(params: &Value) -> (String, Option<String>, Vec<String>) {
    let mut tools = Vec::new();
    if let Some(tool_calls) = params.get("toolCalls").and_then(Value::as_array) {
        for call in tool_calls {
            if let Some(name) = call
                .get("title")
                .or_else(|| call.get("kind"))
                .or_else(|| call.pointer("/toolCall/title"))
                .and_then(Value::as_str)
            {
                let trimmed = name.trim();
                if !trimmed.is_empty() && tools.len() < 8 {
                    tools.push(trimmed.chars().take(64).collect());
                }
            }
        }
    }
    if let Some(options) = params.get("options").and_then(Value::as_array) {
        for option in options {
            let kind = option.get("kind").and_then(Value::as_str).unwrap_or("");
            let option_id = option.get("optionId").and_then(Value::as_str);
            if matches!(kind, "allow_once" | "allow_always" | "allow")
                || option_id.is_some_and(|id| id.contains("allow"))
            {
                let summary = if tools.is_empty() {
                    "Hermes Agent requests permission to continue.".to_string()
                } else {
                    format!("Hermes Agent requests permission for: {}", tools.join(", "))
                };
                return (summary, option_id.map(str::to_string), tools);
            }
        }
    }
    let summary = if tools.is_empty() {
        "Hermes Agent requests permission to continue.".to_string()
    } else {
        format!("Hermes Agent requests permission for: {}", tools.join(", "))
    };
    let option_id = params
        .get("options")
        .and_then(Value::as_array)
        .and_then(|options| options.first())
        .and_then(|option| option.get("optionId"))
        .and_then(Value::as_str)
        .map(str::to_string);
    (summary, option_id, tools)
}

fn register_park_and_inbox(
    token: &str,
    protocol: &HermesProtocol,
    request_id: &Value,
    display_summary: &str,
    option_id: Option<&str>,
    requested_tools: &[String],
    decision_tx: SyncSender<bool>,
) -> Result<(), ProtocolFailure> {
    let session_id = protocol.session_id.clone().ok_or_else(|| {
        ProtocolFailure::user_interaction(
            "session/request_permission",
            None,
            Some(&protocol.config.turn_id),
        )
    })?;
    {
        let mut guard = parked_permissions().lock().map_err(|_| {
            ProtocolFailure::new(
                "hermes_approval_park_unavailable",
                "Hermes approval park state is unavailable.",
                "server/request",
            )
        })?;
        guard.retain(|_, parked| parked.created_at.elapsed() < APPROVAL_WAIT_TIMEOUT);
        if guard.len() >= MAX_PARKED_PERMISSIONS {
            return Err(ProtocolFailure::new(
                "hermes_approval_park_capacity",
                "Hermes approval park capacity was exceeded.",
                "server/request",
            ));
        }
        guard.insert(
            token.to_string(),
            ParkedPermission {
                request_id: request_id.clone(),
                session_id: session_id.clone(),
                turn_id: protocol.config.turn_id.clone(),
                display_summary: display_summary.to_string(),
                option_id: option_id.map(str::to_string),
                decision_tx,
                created_at: Instant::now(),
            },
        );
    }
    if write_park_metadata_file(
        token,
        &session_id,
        &protocol.config.turn_id,
        display_summary,
    )
    .is_err()
    {
        let _ = parked_permissions()
            .lock()
            .ok()
            .and_then(|mut guard| guard.remove(token));
        return Err(ProtocolFailure::new(
            "hermes_approval_park_write_failed",
            "Hermes could not persist a durable approval pause handle.",
            "server/request",
        ));
    }
    let expires_at = (OffsetDateTime::now_utc() + time::Duration::seconds(300))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "2099-01-01T00:00:00Z".to_string());
    let nonce = Uuid::new_v4().to_string();
    let pending_operation_id = format!("hermes-park-{token}");
    let register = crate::core::secure_mesh_approval::evaluate_approval_request_json(&json!({
        "pendingOperationId": pending_operation_id,
        "requesterAgentId": "hermes",
        "targetClientId": "local-desktop",
        "originEndpointId": "local-desktop",
        "displaySummary": display_summary,
        "policyReason": "ACP session/request_permission",
        "adapterCallbackTokenRef": token,
        "adapterStyle": "callback",
        "expiresAt": expires_at,
        "responseNonce": nonce,
        "trustedEndpointIds": ["local-desktop"],
        "requestedTools": requested_tools,
        "riskLevel": "local_effect",
    }));
    if register.is_err() {
        // Inbox registration failure must not leave an unresolvable park.
        let _ = parked_permissions()
            .lock()
            .ok()
            .and_then(|mut guard| guard.remove(token));
        clear_park_files(token);
        return Err(ProtocolFailure::new(
            "hermes_approval_inbox_register_failed",
            "Hermes could not register a durable approval pause handle.",
            "server/request",
        ));
    }
    let _ = crate::core::secure_mesh_approval::evaluate_approval_fanout_json(&json!({
        "pendingOperationId": format!("hermes-park-{token}"),
    }));
    super::turn_event_emit::emit_turn_event(
        "agent.approval.needed",
        &session_id,
        &protocol.config.turn_id,
        json!({
            "agentId": "hermes",
            "adapterCallbackTokenRef": token,
            "pendingOperationId": format!("hermes-park-{token}"),
            "displaySummary": display_summary,
            "requestedTools": requested_tools,
            "adapterStyle": "callback",
            "responseNonce": nonce,
            "expiresAt": expires_at,
            "originEndpointId": "local-desktop",
            "trustedEndpointIds": ["local-desktop"],
        }),
    );
    Ok(())
}

fn await_external_approval(
    transport: &mut PersistentTransport,
    protocol: &mut HermesProtocol,
    request_id: &Value,
    display_summary: &str,
    option_id: Option<&str>,
    requested_tools: &[String],
    deadline: Instant,
) -> Result<ApprovalWaitOutcome, ProtocolFailure> {
    let (decision_tx, decision_rx) = mpsc::sync_channel(1);
    let token = Uuid::new_v4().to_string();
    if let Err(failure) = register_park_and_inbox(
        &token,
        protocol,
        request_id,
        display_summary,
        option_id,
        requested_tools,
        decision_tx,
    ) {
        // Fail closed: cancel the permission and surface interaction required.
        let _ = write_message(
            &mut transport.stdin,
            &json!({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"outcome": {"outcome": "cancelled"}}
            }),
        );
        if let Some(session_id) = protocol.session_id.as_deref() {
            let _ = write_message(
                &mut transport.stdin,
                &json!({
                    "jsonrpc": "2.0",
                    "method": "session/cancel",
                    "params": {"sessionId": session_id}
                }),
            );
        }
        protocol.interaction_failure = Some(failure.clone());
        return Err(failure);
    }
    let approval_deadline = Instant::now()
        .checked_add(APPROVAL_WAIT_TIMEOUT)
        .unwrap_or(deadline)
        .min(deadline);
    loop {
        if let Some(failure) = handle_control_requests(transport, protocol) {
            let _ = parked_permissions()
                .lock()
                .ok()
                .and_then(|mut guard| guard.remove(&token));
            let _ = write_message(
                &mut transport.stdin,
                &json!({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {"outcome": {"outcome": "cancelled"}}
                }),
            );
            return Err(failure);
        }
        let now = Instant::now();
        if now >= approval_deadline {
            let _ = parked_permissions()
                .lock()
                .ok()
                .and_then(|mut guard| guard.remove(&token));
            let _ = write_message(
                &mut transport.stdin,
                &json!({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {"outcome": {"outcome": "cancelled"}}
                }),
            );
            if let Some(session_id) = protocol.session_id.as_deref() {
                let _ = write_message(
                    &mut transport.stdin,
                    &json!({
                        "jsonrpc": "2.0",
                        "method": "session/cancel",
                        "params": {"sessionId": session_id}
                    }),
                );
            }
            let mut failure = ProtocolFailure::user_interaction(
                "session/request_permission",
                protocol.session_id.as_deref(),
                Some(&protocol.config.turn_id),
            );
            failure.turn_status = Some("approval_timeout".to_string());
            protocol.interaction_failure = Some(failure.clone());
            return Err(failure);
        }
        match decision_rx.recv_timeout(APPROVAL_POLL_INTERVAL) {
            Ok(true) => {
                clear_park_files(&token);
                let outcome = if let Some(option_id) = option_id {
                    json!({
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {
                            "outcome": {
                                "outcome": "selected",
                                "optionId": option_id
                            }
                        }
                    })
                } else {
                    json!({
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {
                            "outcome": {
                                "outcome": "selected",
                                "optionId": "allow"
                            }
                        }
                    })
                };
                if write_message(&mut transport.stdin, &outcome).is_err() {
                    return Err(protocol.failure_with_ids(
                        "hermes_acp_write_failed",
                        "Hermes ACP stopped accepting protocol messages.",
                        "protocol/write",
                    ));
                }
                return Ok(ApprovalWaitOutcome::Allowed);
            }
            Ok(false) => {
                clear_park_files(&token);
                if write_message(
                    &mut transport.stdin,
                    &json!({
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {"outcome": {"outcome": "cancelled"}}
                    }),
                )
                .is_err()
                {
                    return Err(protocol.failure_with_ids(
                        "hermes_acp_write_failed",
                        "Hermes ACP stopped accepting protocol messages.",
                        "protocol/write",
                    ));
                }
                if let Some(session_id) = protocol.session_id.as_deref() {
                    let _ = write_message(
                        &mut transport.stdin,
                        &json!({
                            "jsonrpc": "2.0",
                            "method": "session/cancel",
                            "params": {"sessionId": session_id}
                        }),
                    );
                }
                protocol.interaction_failure = Some(ProtocolFailure::user_interaction(
                    "session/request_permission",
                    protocol.session_id.as_deref(),
                    Some(&protocol.config.turn_id),
                ));
                return Ok(ApprovalWaitOutcome::Denied);
            }
            Err(RecvTimeoutError::Timeout) => {
                // Cross-process resolve writes a decision file while this send is blocked.
                if let Some(allow) = read_park_decision_file(&token) {
                    let _ = parked_permissions()
                        .lock()
                        .ok()
                        .and_then(|mut guard| guard.remove(&token));
                    clear_park_files(&token);
                    if allow {
                        let outcome = if let Some(option_id) = option_id {
                            json!({
                                "jsonrpc": "2.0",
                                "id": request_id,
                                "result": {
                                    "outcome": {
                                        "outcome": "selected",
                                        "optionId": option_id
                                    }
                                }
                            })
                        } else {
                            json!({
                                "jsonrpc": "2.0",
                                "id": request_id,
                                "result": {
                                    "outcome": {
                                        "outcome": "selected",
                                        "optionId": "allow"
                                    }
                                }
                            })
                        };
                        if write_message(&mut transport.stdin, &outcome).is_err() {
                            return Err(protocol.failure_with_ids(
                                "hermes_acp_write_failed",
                                "Hermes ACP stopped accepting protocol messages.",
                                "protocol/write",
                            ));
                        }
                        return Ok(ApprovalWaitOutcome::Allowed);
                    }
                    if write_message(
                        &mut transport.stdin,
                        &json!({
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": {"outcome": {"outcome": "cancelled"}}
                        }),
                    )
                    .is_err()
                    {
                        return Err(protocol.failure_with_ids(
                            "hermes_acp_write_failed",
                            "Hermes ACP stopped accepting protocol messages.",
                            "protocol/write",
                        ));
                    }
                    if let Some(session_id) = protocol.session_id.as_deref() {
                        let _ = write_message(
                            &mut transport.stdin,
                            &json!({
                                "jsonrpc": "2.0",
                                "method": "session/cancel",
                                "params": {"sessionId": session_id}
                            }),
                        );
                    }
                    protocol.interaction_failure = Some(ProtocolFailure::user_interaction(
                        "session/request_permission",
                        protocol.session_id.as_deref(),
                        Some(&protocol.config.turn_id),
                    ));
                    return Ok(ApprovalWaitOutcome::Denied);
                }
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => {
                // Channel dropped; still honor a cross-process decision file.
                if let Some(allow) = read_park_decision_file(&token) {
                    let _ = parked_permissions()
                        .lock()
                        .ok()
                        .and_then(|mut guard| guard.remove(&token));
                    clear_park_files(&token);
                    if allow {
                        let outcome = json!({
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": {
                                "outcome": {
                                    "outcome": "selected",
                                    "optionId": option_id.unwrap_or("allow")
                                }
                            }
                        });
                        if write_message(&mut transport.stdin, &outcome).is_err() {
                            return Err(protocol.failure_with_ids(
                                "hermes_acp_write_failed",
                                "Hermes ACP stopped accepting protocol messages.",
                                "protocol/write",
                            ));
                        }
                        return Ok(ApprovalWaitOutcome::Allowed);
                    }
                }
                clear_park_files(&token);
                let _ = write_message(
                    &mut transport.stdin,
                    &json!({
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "result": {"outcome": {"outcome": "cancelled"}}
                    }),
                );
                return Err(ProtocolFailure::new(
                    "hermes_approval_park_disconnected",
                    "Hermes approval park channel disconnected.",
                    "server/request",
                ));
            }
        }
    }
}

pub(super) fn probe(executable: &str, timeout_ms: u64, max_output: usize) -> CapabilityProbe {
    let check = run_probe_command(executable, &["acp", "--check"], timeout_ms, max_output);
    let Ok(check) = check else {
        return CapabilityProbe {
            error_code: Some("hermes_acp_probe_failed"),
            ..CapabilityProbe::default()
        };
    };
    let supported = String::from_utf8_lossy(&check).contains("ACP check OK");
    let version = run_probe_command(executable, &["acp", "--version"], timeout_ms, max_output)
        .ok()
        .and_then(|bytes| first_nonempty_line(&bytes));
    CapabilityProbe {
        available: true,
        supported,
        version,
        error_code: (!supported).then_some("hermes_acp_capability_missing"),
        supports_streaming: true,
        supports_tools: true,
        supports_approvals: true,
        supports_model_override: true,
        supports_reasoning_override: false,
    }
}

fn run_probe_command(
    executable: &str,
    args: &[&str],
    timeout_ms: u64,
    max_output: usize,
) -> Result<Vec<u8>, ()> {
    let mut command = Command::new(executable);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = SupervisedChild::spawn(&mut command).map_err(|_| ())?;
    let Some(stdout) = child.stdout() else {
        child.terminate_tree().map_err(|_| ())?;
        return Err(());
    };
    let Some(stderr) = child.stderr() else {
        child.terminate_tree().map_err(|_| ())?;
        return Err(());
    };
    let stdout_handle = thread::spawn(move || read_bounded(stdout, max_output));
    let stderr_handle = thread::spawn(move || read_bounded(stderr, max_output));
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    while !stdout_handle.is_finished() && Instant::now() < deadline {
        thread::sleep(PROCESS_POLL_INTERVAL);
    }
    let timed_out = !stdout_handle.is_finished();
    let status = child.terminate_tree().map_err(|_| ())?;
    let stdout = join_bounded(stdout_handle, IO_THREAD_EXIT_GRACE).map_err(|_| ())?;
    let stderr = join_bounded(stderr_handle, IO_THREAD_EXIT_GRACE).map_err(|_| ())?;
    if timed_out || !status.is_some_and(|value| value.success()) || stdout.1 || stderr.1 {
        return Err(());
    }
    let mut combined = stdout.0;
    combined.extend(stderr.0);
    Ok(combined)
}

fn write_message(stdin: &mut BoundedStdinWriter, message: &Value) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(message).map_err(io::Error::other)?;
    bytes.push(b'\n');
    stdin
        .enqueue(bytes)
        .map_err(|_| io::Error::other("native agent protocol write failed"))
}

fn read_protocol_messages<R: BufRead>(mut reader: R, sender: Sender<TransportEvent>) {
    let mut line = Vec::new();
    loop {
        let available = match reader.fill_buf() {
            Ok(bytes) => bytes,
            Err(_) => {
                let _ = sender.send(TransportEvent::StdoutReadFailed);
                return;
            }
        };
        if available.is_empty() {
            if !line.is_empty() && send_protocol_line(&line, &sender).is_err() {
                return;
            }
            let _ = sender.send(TransportEvent::StdoutClosed);
            return;
        }
        let consumed = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|index| index + 1)
            .unwrap_or(available.len());
        if line.len().saturating_add(consumed) > MAX_PROTOCOL_LINE_BYTES {
            let _ = sender.send(TransportEvent::LineLimitExceeded);
            return;
        }
        let completed_line = available.get(consumed.saturating_sub(1)) == Some(&b'\n');
        line.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        if completed_line {
            while matches!(line.last(), Some(b'\n' | b'\r')) {
                line.pop();
            }
            if !line.is_empty() && send_protocol_line(&line, &sender).is_err() {
                return;
            }
            line.clear();
        }
    }
}

fn send_protocol_line(line: &[u8], sender: &Sender<TransportEvent>) -> Result<(), ()> {
    match serde_json::from_slice::<Value>(line) {
        Ok(message) => sender
            .send(TransportEvent::Message {
                message,
                bytes: line.len(),
            })
            .map_err(|_| ()),
        Err(_) => sender.send(TransportEvent::InvalidJson).map_err(|_| ()),
    }
}

fn drain_stderr<R: Read>(mut stderr: R, max_bytes: usize, truncated: &AtomicBool) {
    let mut buffer = [0u8; 8192];
    let mut total_bytes = 0usize;
    loop {
        match stderr.read(&mut buffer) {
            Ok(0) => return,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
            Ok(read) => {
                total_bytes = total_bytes.saturating_add(read);
                if total_bytes > max_bytes {
                    truncated.store(true, Ordering::Relaxed);
                }
            }
        }
    }
}

fn read_bounded<R: Read>(mut reader: R, max_bytes: usize) -> (Vec<u8>, bool) {
    let mut kept = Vec::with_capacity(max_bytes.min(8192));
    let mut buffer = [0u8; 8192];
    let mut total = 0usize;
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return (kept, total > max_bytes),
            Ok(read) => {
                let remaining = max_bytes.saturating_sub(kept.len());
                kept.extend_from_slice(&buffer[..read.min(remaining)]);
                total = total.saturating_add(read);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return (kept, true),
        }
    }
}

fn response_is_error(message: &Value) -> bool {
    message.get("error").is_some()
}

fn request_id_matches(message: &Value, expected: i64) -> bool {
    message.get("id").is_some_and(|id| {
        id.as_i64() == Some(expected)
            || id
                .as_str()
                .is_some_and(|value| value == expected.to_string())
    })
}

fn explicit_value<'a>(params: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter()
        .find_map(|key| params.get(*key))
        .filter(|value| !value.is_null())
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn first_nonempty_line(bytes: &[u8]) -> Option<String> {
    String::from_utf8_lossy(bytes)
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(str::to_string)
}

fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    fn config(params: Value, prompt: &str, session_id: &str) -> ProtocolConfig {
        ProtocolConfig::from_params(
            &params,
            prompt,
            session_id,
            Some(Path::new("/workspace/project")),
        )
        .unwrap()
    }

    fn sent_messages(effects: Vec<ProtocolEffect>) -> Vec<Value> {
        effects
            .into_iter()
            .filter_map(|effect| match effect {
                ProtocolEffect::Send(message) => Some(message),
                ProtocolEffect::Complete(_)
                | ProtocolEffect::Fail(_)
                | ProtocolEffect::AwaitExternalApproval { .. } => None,
            })
            .collect()
    }

    fn initialize(protocol: &mut HermesProtocol) -> Vec<ProtocolEffect> {
        protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "id": INITIALIZE_REQUEST_ID,
            "result": {
                "protocolVersion": 1,
                "agentCapabilities": {"loadSession": true, "sessionCapabilities": {"resume": {}}},
                "agentInfo": {"name": "hermes-agent", "version": "test"}
            }
        }))
    }

    #[test]
    fn new_session_and_prompt_keep_private_values_in_acp_stdin() {
        let prompt = "private-hermes-prompt";
        let mut protocol =
            HermesProtocol::new(config(json!({"model": "provider/model"}), prompt, ""));
        let launch = LaunchSpec::new("hermes", Path::new("/workspace/project"));
        assert_eq!(launch.args, ["acp"]);
        assert!(!launch.args.iter().any(|arg| arg.contains(prompt)));
        assert!(!launch.args.iter().any(|arg| arg.contains("workspace")));

        let session = sent_messages(initialize(&mut protocol));
        assert_eq!(session[0]["method"], "session/new");
        assert_eq!(session[0]["params"]["cwd"], "/workspace/project");
        assert!(!session[0].to_string().contains(prompt));

        let model = sent_messages(protocol.handle_message(json!({
            "id": SESSION_REQUEST_ID,
            "result": {"sessionId": "native-hermes-session", "models": {"currentModelId": "default"}}
        })));
        assert_eq!(model[0]["method"], "session/set_model");
        assert_eq!(model[0]["params"]["modelId"], "provider/model");
        let prompt_request = sent_messages(protocol.handle_message(json!({
            "id": MODEL_REQUEST_ID,
            "result": {}
        })));
        assert_eq!(prompt_request[0]["method"], "session/prompt");
        assert_eq!(prompt_request[0]["params"]["prompt"][0]["text"], prompt);
    }

    #[test]
    fn exact_resume_uses_session_load_inside_json_rpc() {
        let mut protocol = HermesProtocol::new(config(json!({}), "hello", "native-session"));
        let session = sent_messages(initialize(&mut protocol));
        assert_eq!(session[0]["method"], "session/load");
        assert_eq!(session[0]["params"]["sessionId"], "native-session");
    }

    #[test]
    fn streaming_chunks_emit_progressive_turn_events() {
        use std::sync::{Arc, Mutex};

        let captured = Arc::new(Mutex::new(Vec::<Value>::new()));
        let sink_target = Arc::clone(&captured);
        super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
            sink_target.lock().unwrap().push(event);
        }));
        let _guard = super::super::turn_event_emit::StreamSinkGuard;

        let mut protocol = HermesProtocol::new(config(json!({}), "hello", ""));
        initialize(&mut protocol);
        protocol.handle_message(json!({
            "id": SESSION_REQUEST_ID,
            "result": {"sessionId": "native-hermes-session"}
        }));
        protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": "native-hermes-session",
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "watch-"}
                }
            }
        }));
        protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": "native-hermes-session",
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "able"}
                }
            }
        }));
        let completed = protocol.handle_message(json!({
            "id": PROMPT_REQUEST_ID,
            "result": {"stopReason": "end_turn"}
        }));
        assert!(matches!(completed[0], ProtocolEffect::Complete(_)));
        assert_eq!(protocol.output, "watch-able");

        let events = captured.lock().unwrap().clone();
        assert_eq!(events.len(), 3);
        assert_eq!(events[0]["event"], "agent.message.chunk");
        assert_eq!(events[0]["payload"]["text"], "watch-");
        assert_eq!(events[0]["sessionId"], "native-hermes-session");
        assert_eq!(events[1]["payload"]["text"], "able");
        assert_eq!(events[2]["event"], "agent.message.completed");
        assert_eq!(events[2]["payload"]["text"], "watch-able");
        assert!(!events[0]["turnId"].as_str().unwrap_or("").is_empty());
    }

    #[test]
    fn interrupted_turn_keeps_native_session_for_exact_continue() {
        let mut protocol = HermesProtocol::new(config(json!({}), "hello", "native-session"));
        initialize(&mut protocol);
        protocol.handle_message(json!({"id": SESSION_REQUEST_ID, "result": {}}));
        let effects = protocol.handle_message(json!({
            "id": PROMPT_REQUEST_ID,
            "result": {"stopReason": "cancelled"}
        }));
        match &effects[0] {
            ProtocolEffect::Fail(failure) => {
                assert_eq!(failure.code, "hermes_acp_turn_not_completed");
                assert_eq!(failure.session_id.as_deref(), Some("native-session"));
                assert_eq!(failure.turn_status.as_deref(), Some("cancelled"));
            }
            _ => panic!("interrupted turn must fail closed while retaining native session id"),
        }
    }

    #[test]
    fn unsupported_reasoning_override_fails_closed() {
        let failure = ProtocolConfig::from_params(
            &json!({"reasoningEffort": "high"}),
            "hello",
            "",
            Some(Path::new("/workspace")),
        )
        .unwrap_err();
        assert_eq!(failure.code, "hermes_acp_reasoning_override_unsupported");
    }

    #[test]
    fn permission_request_parks_for_external_approval_when_session_exists() {
        let mut protocol = HermesProtocol::new(config(json!({}), "hello", "native-session"));
        initialize(&mut protocol);
        protocol.handle_message(json!({"id": SESSION_REQUEST_ID, "result": {}}));
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "id": "approval-1",
            "method": "session/request_permission",
            "params": {
                "sessionId": "native-session",
                "options": [{"optionId": "allow-once", "kind": "allow_once", "name": "Allow once"}]
            }
        }));
        assert_eq!(effects.len(), 1);
        match &effects[0] {
            ProtocolEffect::AwaitExternalApproval {
                display_summary,
                option_id,
                ..
            } => {
                assert!(display_summary.contains("Hermes Agent requests permission"));
                assert_eq!(option_id.as_deref(), Some("allow-once"));
            }
            _ => panic!("permission request with a session must park for external approval"),
        }
    }

    #[test]
    fn permission_request_without_session_fails_closed() {
        let mut protocol = HermesProtocol::new(config(json!({}), "hello", ""));
        // Skip session establishment so there is no durable pause handle.
        protocol.phase = ProtocolPhase::AwaitPrompt;
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "id": "approval-1",
            "method": "session/request_permission",
            "params": {"options": []}
        }));
        assert!(effects.len() >= 1);
        match &effects[0] {
            ProtocolEffect::Send(message) => {
                assert_eq!(message["result"]["outcome"]["outcome"], "cancelled");
            }
            _ => panic!("missing pause handle must fail closed with an explicit denial"),
        }
        assert!(
            protocol
                .interaction_failure
                .as_ref()
                .is_some_and(|f| f.user_interaction_required)
        );
    }

    #[test]
    fn resolve_parked_permission_fail_closed_without_token() {
        assert!(resolve_parked_permission("", true).is_err());
        assert!(resolve_parked_permission("missing-token", false).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn permission_request_is_denied_and_requires_user_interaction() {
        // Retained name for compatibility with prior fail-closed coverage:
        // after deny resolution the turn still surfaces user interaction required.
        let mut protocol = HermesProtocol::new(config(json!({}), "hello", "native-session"));
        initialize(&mut protocol);
        protocol.handle_message(json!({"id": SESSION_REQUEST_ID, "result": {}}));
        protocol.interaction_failure = Some(ProtocolFailure::user_interaction(
            "session/request_permission",
            Some("native-session"),
            Some(&protocol.config.turn_id),
        ));
        let terminal = protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "id": PROMPT_REQUEST_ID,
            "result": {"stopReason": "cancelled"}
        }));
        match &terminal[0] {
            ProtocolEffect::Fail(failure) => {
                assert!(failure.user_interaction_required);
                assert_eq!(failure.code, "hermes_user_interaction_required");
                assert_eq!(failure.turn_status.as_deref(), Some("cancelled"));
            }
            _ => panic!("denied permission turn must stop autonomous dispatch"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn fake_child_e2e_streams_final_and_drains_stderr() {
        let root = unique_temp_dir("hermes-acp-e2e");
        let executable = root.join("fake-hermes");
        write_executable(
            &executable,
            r#"#!/bin/sh
if [ "$1" = "acp" ] && [ "$2" = "--check" ]; then
  printf '%s\n' 'Hermes ACP check OK'
  exit 0
fi
if [ "$1" = "acp" ] && [ "$2" = "--version" ]; then
  printf '%s\n' 'Hermes test-version'
  exit 0
fi
if [ "$#" -ne 1 ] || [ "$1" != "acp" ]; then
  exit 40
fi
dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr '\000' x >&2 &
IFS= read -r init
case "$init" in *private-hermes-prompt*|*workspace/project*) exit 41;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"hermes-agent","version":"test"}}}'
IFS= read -r session
case "$session" in *private-hermes-prompt*) exit 42;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"native-hermes-session","models":{"currentModelId":"native-model","availableModels":[]},"modes":{"currentModeId":"default","availableModes":[]}}}'
IFS= read -r model
printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{}}'
IFS= read -r prompt
case "$prompt" in *private-hermes-prompt*) :;; *) exit 43;; esac
printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"native-hermes-session","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"hidden thought"}}}}'
printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"native-hermes-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"native answer"}}}}'
printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
wait
"#,
        );
        let result = execute(
            executable.to_str().unwrap(),
            &json!({"model": "requested-model"}),
            "private-hermes-prompt",
            "",
            Some(&root),
            5_000,
            128 * 1024,
            8 * 1024,
        );
        assert!(result.ok);
        assert_eq!(result.output, "native answer");
        assert_eq!(result.session_id, "native-hermes-session");
        assert_eq!(result.turn_status, "end_turn");
        assert_eq!(result.events.len(), 2);
        assert_eq!(result.effective.model.as_deref(), Some("requested-model"));
        assert_eq!(result.effective.approval_policy, Some(json!("default")));
        assert_eq!(
            cleanup_session(&result.session_id),
            ControlDisposition::Accepted
        );

        let probe = probe(executable.to_str().unwrap(), 2_000, 16 * 1024);
        assert!(probe.available);
        assert!(probe.supported);
        assert!(probe.supports_streaming);
        assert!(probe.supports_model_override);
        assert!(!probe.supports_reasoning_override);
        let _ = fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn fake_child_exact_resume_keeps_native_session_id() {
        use std::sync::{Arc, Mutex};

        let root = unique_temp_dir("hermes-acp-resume");
        let executable = root.join("fake-hermes-resume");
        write_executable(
            &executable,
            r#"#!/bin/sh
if [ "$#" -ne 1 ] || [ "$1" != "acp" ]; then
  exit 40
fi
printf '%s\n' launch >> "$0.launches"
IFS= read -r init
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"hermes-agent","version":"test"}}}'
turn=1
while [ "$turn" -le 2 ]; do
  IFS= read -r session
  if [ "$turn" -eq 1 ]; then
    case "$session" in *'"method":"session/new"'*) :;; *) exit 44;; esac
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"native-hermes-exact"}}'
  else
    case "$session" in *'"method":"session/load"'*native-hermes-exact*) :;; *) exit 45;; esac
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{}}'
  fi
  IFS= read -r prompt
  case "$prompt" in *native-hermes-exact*) :;; *) exit 46;; esac
  printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"native-hermes-exact","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"chunk-a"}}}}'
  sleep 0.05
  printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"native-hermes-exact","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"-chunk-b"}}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
  turn=$((turn + 1))
done
sleep 30
"#,
        );

        let first = execute(
            executable.to_str().unwrap(),
            &json!({}),
            "first-turn-canary",
            "",
            Some(&root),
            5_000,
            64 * 1024,
            8 * 1024,
        );
        assert!(first.ok, "first turn should open a native session");
        assert_eq!(first.session_id, "native-hermes-exact");

        let captured = Arc::new(Mutex::new(Vec::<Value>::new()));
        let sink_target = Arc::clone(&captured);
        super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
            sink_target.lock().unwrap().push(event);
        }));
        let _guard = super::super::turn_event_emit::StreamSinkGuard;

        let follow_up = execute(
            executable.to_str().unwrap(),
            &json!({}),
            "follow-up-canary",
            &first.session_id,
            Some(&root),
            5_000,
            64 * 1024,
            8 * 1024,
        );
        assert!(follow_up.ok, "exact resume follow-up should succeed");
        assert_eq!(follow_up.session_id, first.session_id);
        assert_eq!(follow_up.output, "chunk-a-chunk-b");

        let events = captured.lock().unwrap().clone();
        let chunk_texts: Vec<&str> = events
            .iter()
            .filter(|event| event["event"] == "agent.message.chunk")
            .filter_map(|event| event["payload"]["text"].as_str())
            .collect();
        assert_eq!(chunk_texts, vec!["chunk-a", "-chunk-b"]);
        assert!(
            events
                .iter()
                .any(|event| event["event"] == "agent.message.completed")
        );
        assert!(
            events
                .iter()
                .all(|event| event["sessionId"] == "native-hermes-exact")
        );
        let launch_receipt =
            fs::read_to_string(format!("{}.launches", executable.display())).unwrap();
        assert_eq!(launch_receipt.lines().count(), 1);
        assert_eq!(
            cleanup_session(&first.session_id),
            ControlDisposition::Accepted
        );
        let _ = fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn persistent_turn_can_be_cancelled_without_restarting_the_session() {
        let root = unique_temp_dir("hermes-acp-cancel");
        let executable = root.join("fake-hermes-cancel");
        write_executable(
            &executable,
            r#"#!/bin/sh
if [ "$#" -ne 1 ] || [ "$1" != "acp" ]; then
  exit 40
fi
IFS= read -r init
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"hermes-agent","version":"test"}}}'
IFS= read -r new_session
case "$new_session" in *'"method":"session/new"'*) :;; *) exit 41;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"native-hermes-cancel"}}'
IFS= read -r first_prompt
printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"native-hermes-cancel","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"first"}}}}'
printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
IFS= read -r load_session
case "$load_session" in *'"method":"session/load"'*native-hermes-cancel*) :;; *) exit 42;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{}}'
IFS= read -r second_prompt
IFS= read -r cancel
case "$cancel" in *'"method":"session/cancel"'*native-hermes-cancel*) :;; *) exit 43;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"cancelled"}}'
sleep 30
"#,
        );
        let first = execute(
            executable.to_str().unwrap(),
            &json!({}),
            "first",
            "",
            Some(&root),
            5_000,
            64 * 1024,
            8 * 1024,
        );
        assert!(first.ok);
        let executable_for_turn = executable.clone();
        let root_for_turn = root.clone();
        let session_id = first.session_id.clone();
        let session_for_turn = session_id.clone();
        let turn = thread::spawn(move || {
            execute(
                executable_for_turn.to_str().unwrap(),
                &json!({}),
                "second",
                &session_for_turn,
                Some(&root_for_turn),
                5_000,
                64 * 1024,
                8 * 1024,
            )
        });
        let mut disposition = ControlDisposition::NoActiveTurn;
        for _ in 0..100 {
            disposition = cancel(&session_id);
            if disposition == ControlDisposition::Accepted {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(disposition, ControlDisposition::Accepted);
        let cancelled = turn.join().unwrap();
        assert!(!cancelled.ok);
        let failure = cancelled.error.unwrap();
        assert_eq!(failure.code, "hermes_acp_turn_not_completed");
        assert_eq!(failure.turn_status.as_deref(), Some("cancelled"));
        assert_eq!(failure.session_id.as_deref(), Some(session_id.as_str()));
        assert_eq!(cleanup_session(&session_id), ControlDisposition::Accepted);
        let _ = fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    fn unique_temp_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("lico-{label}-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[cfg(unix)]
    fn write_executable(path: &Path, body: &str) {
        fs::write(path, body).unwrap();
        let mut permissions = fs::metadata(path).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(path, permissions).unwrap();
    }
}
