use super::process_supervisor::{
    BoundedStdinWriter, IO_THREAD_EXIT_GRACE, SupervisedChild, TransportFinishFailure,
    finish_protocol_transport, join_bounded,
};
use serde_json::{Map, Value, json};
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub(super) const RUNTIME_PROTOCOL: &str = "openclaw-acp-stdio-jsonrpc";

const INITIALIZE_REQUEST_ID: i64 = 1;
const SESSION_REQUEST_ID: i64 = 2;
const MODE_REQUEST_ID: i64 = 3;
const PROMPT_REQUEST_ID: i64 = 4;
const ACP_PROTOCOL_VERSION: i64 = 1;
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);

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
            code: "openclaw_user_interaction_required",
            message: "OpenClaw requires explicit user interaction before this turn can continue.",
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
    pub(super) supports_reasoning: bool,
    pub(super) supports_model_override: bool,
}

#[derive(Clone, Debug)]
struct ProtocolConfig {
    prompt: String,
    requested_session_id: String,
    native_session_key: Option<String>,
    cwd: String,
    reasoning_effort: Option<String>,
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
                "openclaw_empty_prompt",
                "OpenClaw requires a non-empty message.",
                "request/validate",
            ));
        }
        if text_param(params, &["model", "modelId"]).is_some() {
            return Err(ProtocolFailure::new(
                "openclaw_acp_model_override_unsupported",
                "OpenClaw ACP does not expose native model selection.",
                "capability/model",
            ));
        }
        if explicit_value(params, &["sandbox", "sandboxMode"]).is_some() {
            return Err(ProtocolFailure::new(
                "openclaw_acp_sandbox_override_unsupported",
                "OpenClaw ACP does not expose a per-turn sandbox override.",
                "capability/sandbox",
            ));
        }
        if explicit_value(params, &["approvalPolicy", "approval_policy"]).is_some() {
            return Err(ProtocolFailure::new(
                "openclaw_acp_approval_override_unsupported",
                "OpenClaw ACP approvals require an explicit client approval response.",
                "capability/approval",
            ));
        }
        let reasoning_effort = text_param(params, &["reasoningEffort", "reasoning_effort"]);
        if reasoning_effort.as_deref().is_some_and(|value| {
            !matches!(
                value,
                "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "adaptive" | "max"
            )
        }) {
            return Err(ProtocolFailure::new(
                "openclaw_acp_invalid_thought_level",
                "The requested OpenClaw thought level is not supported.",
                "request/validate",
            ));
        }
        let cwd = cwd
            .filter(|path| path.is_absolute())
            .map(|path| path.to_string_lossy().to_string())
            .ok_or_else(|| {
                ProtocolFailure::new(
                    "openclaw_acp_absolute_cwd_required",
                    "OpenClaw ACP requires an absolute working directory.",
                    "request/validate",
                )
            })?;
        let requested_session_id = session_id.trim().to_string();
        let runtime_agent_id = text_param(
            params,
            &["openclawAgentId", "runtimeAgentId", "targetAgentId"],
        );
        let normalized_runtime_agent_id = runtime_agent_id.as_deref().map(normalize_agent_id);
        if runtime_agent_id.is_some()
            && normalized_runtime_agent_id
                .as_deref()
                .is_none_or(str::is_empty)
        {
            return Err(ProtocolFailure::new(
                "openclaw_acp_invalid_agent_id",
                "The requested OpenClaw agent identifier is invalid.",
                "request/validate",
            ));
        }
        let explicit_native_session_key = text_param(
            params,
            &["sessionKey", "nativeSessionKey", "openclawSessionKey"],
        );
        if !requested_session_id.is_empty()
            && explicit_native_session_key
                .as_deref()
                .is_some_and(|key| key != requested_session_id)
        {
            return Err(ProtocolFailure::new(
                "openclaw_acp_conflicting_session_id",
                "The requested OpenClaw conversation identifiers do not match.",
                "request/validate",
            ));
        }
        let native_session_key = explicit_native_session_key
            .or_else(|| (!requested_session_id.is_empty()).then(|| requested_session_id.clone()))
            .or_else(|| {
                normalized_runtime_agent_id
                    .map(|agent_id| format!("agent:{agent_id}:acp:{}", Uuid::new_v4()))
            });
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id,
            native_session_key,
            cwd,
            reasoning_effort,
            turn_id: Uuid::new_v4().to_string(),
        })
    }

    fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty()
    }

    fn session_meta(&self) -> Option<Value> {
        if let Some(key) = self.native_session_key.as_ref() {
            return Some(json!({"sessionKey": key, "requireExisting": self.is_resume()}));
        }
        None
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
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ProtocolPhase {
    AwaitInitialize,
    AwaitSession,
    AwaitMode,
    AwaitPrompt,
    Finished,
}

#[derive(Debug)]
struct OpenClawProtocol {
    config: ProtocolConfig,
    phase: ProtocolPhase,
    protocol_session_id: Option<String>,
    native_session_id: Option<String>,
    output: String,
    events: Vec<Value>,
    effective: EffectiveSettings,
}

impl OpenClawProtocol {
    fn new(config: ProtocolConfig) -> Self {
        let effective = EffectiveSettings {
            cwd: Some(config.cwd.clone()),
            reasoning_effort: config.reasoning_effort.clone(),
            ..EffectiveSettings::default()
        };
        let native_session_id = config.native_session_key.clone();
        Self {
            config,
            phase: ProtocolPhase::AwaitInitialize,
            protocol_session_id: None,
            native_session_id,
            output: String::new(),
            events: Vec::new(),
            effective,
        }
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
            self.phase = ProtocolPhase::Finished;
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
            ProtocolPhase::AwaitMode if request_id_matches(&message, MODE_REQUEST_ID) => {
                self.handle_mode_response(&message)
            }
            ProtocolPhase::AwaitPrompt if request_id_matches(&message, PROMPT_REQUEST_ID) => {
                self.handle_prompt_response(&message)
            }
            _ => Vec::new(),
        }
    }

    fn handle_server_request(&self, message: &Value) -> Option<Vec<ProtocolEffect>> {
        let request_id = message.get("id")?;
        let method = message.get("method")?.as_str()?;
        if message.get("result").is_some() || message.get("error").is_some() {
            return None;
        }
        let response = if method == "session/request_permission" {
            json!({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"outcome": {"outcome": "cancelled"}}
            })
        } else {
            json!({
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": "Client method is not available."}
            })
        };
        Some(vec![
            ProtocolEffect::Send(response),
            ProtocolEffect::Fail(ProtocolFailure::user_interaction(
                method,
                self.native_session_id.as_deref(),
                Some(&self.config.turn_id),
            )),
        ])
    }

    fn handle_initialize_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "openclaw_acp_initialize_failed",
                "OpenClaw ACP initialization failed.",
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
                "openclaw_acp_capability_mismatch",
                "OpenClaw ACP does not expose the required conversation lifecycle.",
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
        if let Some(meta) = self.config.session_meta() {
            params.insert("_meta".to_string(), meta);
        }
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
                "openclaw_acp_session_open_failed",
                "OpenClaw ACP could not open the requested conversation.",
                if self.config.is_resume() {
                    "session/load"
                } else {
                    "session/new"
                },
            ))];
        }
        let session_id = message
            .pointer("/result/sessionId")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .or_else(|| {
                self.config
                    .is_resume()
                    .then(|| self.config.requested_session_id.clone())
            })
            .unwrap_or_default();
        if session_id.is_empty() {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "openclaw_acp_session_id_missing",
                "OpenClaw ACP did not return a native conversation identifier.",
                "session/open",
            ))];
        }
        self.protocol_session_id = Some(session_id);
        if self.native_session_id.is_none() {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.failure_with_ids(
                "openclaw_acp_native_session_id_missing",
                "OpenClaw ACP did not expose a resumable Gateway conversation identifier.",
                "session/open",
            ))];
        }
        self.capture_effective_controls(message.get("result"));
        if self.config.reasoning_effort.is_some() {
            self.phase = ProtocolPhase::AwaitMode;
            vec![ProtocolEffect::Send(self.mode_request())]
        } else {
            self.phase = ProtocolPhase::AwaitPrompt;
            vec![ProtocolEffect::Send(self.prompt_request())]
        }
    }

    fn mode_request(&self) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": MODE_REQUEST_ID,
            "method": "session/set_mode",
            "params": {
                "sessionId": self.protocol_session_id,
                "modeId": self.config.reasoning_effort
            }
        })
    }

    fn handle_mode_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.failure_with_ids(
                "openclaw_acp_thought_level_failed",
                "OpenClaw ACP could not apply the requested thought level.",
                "session/set_mode",
            ))];
        }
        self.phase = ProtocolPhase::AwaitPrompt;
        vec![ProtocolEffect::Send(self.prompt_request())]
    }

    fn prompt_request(&self) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": PROMPT_REQUEST_ID,
            "method": "session/prompt",
            "params": {
                "sessionId": self.protocol_session_id,
                "messageId": self.config.turn_id,
                "prompt": [{"type": "text", "text": self.config.prompt}]
            }
        })
    }

    fn handle_prompt_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.failure_with_ids(
                "openclaw_acp_prompt_failed",
                "OpenClaw ACP could not complete the requested turn.",
                "session/prompt",
            ))];
        }
        let stop_reason = message
            .pointer("/result/stopReason")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        self.phase = ProtocolPhase::Finished;
        if !matches!(
            stop_reason.as_str(),
            "end_turn" | "max_tokens" | "max_turn_requests"
        ) {
            let mut failure = self.failure_with_ids(
                "openclaw_acp_turn_not_completed",
                "OpenClaw ACP did not complete the requested turn.",
                "session/prompt",
            );
            failure.turn_status = Some(stop_reason);
            return vec![ProtocolEffect::Fail(failure)];
        }
        if self.output.is_empty() {
            let mut failure = self.failure_with_ids(
                "openclaw_acp_final_message_missing",
                "OpenClaw ACP completed the turn without a final agent message.",
                "session/prompt",
            );
            failure.turn_status = Some(stop_reason);
            return vec![ProtocolEffect::Fail(failure)];
        }
        vec![ProtocolEffect::Complete(ProtocolOutcome {
            output: self.output.clone(),
            events: self.events.clone(),
            session_id: self.native_session_id.clone().unwrap_or_default(),
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
        let Some(update) = params.get("update") else {
            return Vec::new();
        };
        let update_type = update.get("sessionUpdate").and_then(Value::as_str);
        let event_session_id = params.get("sessionId").and_then(Value::as_str);
        if self.phase == ProtocolPhase::AwaitSession && update_type == Some("session_info_update") {
            if self.protocol_session_id.is_none() {
                self.protocol_session_id = event_session_id.map(str::to_string);
            }
            if let Some(key) = update.pointer("/_meta/sessionKey").and_then(Value::as_str) {
                self.native_session_id = Some(key.to_string());
            }
            return Vec::new();
        }
        if event_session_id != self.protocol_session_id.as_deref() {
            return Vec::new();
        }
        if self.phase == ProtocolPhase::AwaitPrompt {
            self.events.push(update.clone());
            if update_type == Some("agent_message_chunk")
                && let Some(text) = update.pointer("/content/text").and_then(Value::as_str)
            {
                self.output.push_str(text);
                let session_for_emit = self
                    .native_session_id
                    .as_deref()
                    .or(self.protocol_session_id.as_deref())
                    .unwrap_or_default();
                super::turn_event_emit::emit_agent_message_chunk(
                    session_for_emit,
                    &self.config.turn_id,
                    text,
                );
            }
        }
        if update_type == Some("current_mode_update")
            && let Some(level) = update.get("currentModeId").and_then(Value::as_str)
        {
            self.effective.reasoning_effort = Some(level.to_string());
        }
        Vec::new()
    }

    fn capture_effective_controls(&mut self, result: Option<&Value>) {
        let Some(result) = result else {
            return;
        };
        if let Some(level) = result
            .pointer("/modes/currentModeId")
            .and_then(Value::as_str)
        {
            self.effective.reasoning_effort = Some(level.to_string());
        }
    }

    fn failure_with_ids(
        &self,
        code: &'static str,
        message: &'static str,
        stage: &'static str,
    ) -> ProtocolFailure {
        let mut failure = ProtocolFailure::new(code, message, stage);
        failure.session_id = self.native_session_id.clone().or_else(|| {
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
    args: Vec<String>,
    cwd: PathBuf,
}

impl LaunchSpec {
    fn for_gateway_attach(executable: &str, cwd: &Path, gateway_ws_url: &str) -> Self {
        Self {
            executable: executable.to_string(),
            args: vec![
                "acp".to_string(),
                "--url".to_string(),
                gateway_ws_url.to_string(),
            ],
            cwd: cwd.to_path_buf(),
        }
    }

    fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(&self.args)
            .current_dir(&self.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        // Prefer env token over argv so process listings do not expose secrets.
        if let Ok(token) = std::env::var("OPENCLAW_GATEWAY_TOKEN")
            && !token.trim().is_empty()
        {
            command.env("OPENCLAW_GATEWAY_TOKEN", token);
        }
        SupervisedChild::spawn(&mut command)
    }
}

#[derive(Debug)]
enum TransportEvent {
    Message(Value),
    InvalidJson,
    StdoutLimitExceeded,
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
    // Gateway-native: ensure/attach before ACP. Prefer vendor 18789 reuse; never
    // steal that port. Tests/remote may pass an explicit gatewayWsUrl to attach.
    let gateway = if let Some(ws_url) = text_param(params, &["gatewayWsUrl", "gatewayUrl", "wsUrl"])
    {
        let trimmed = ws_url.trim().to_string();
        let http = if trimmed.starts_with("ws://") {
            format!("http://{}", trimmed.trim_start_matches("ws://"))
        } else if trimmed.starts_with("wss://") {
            format!("https://{}", trimmed.trim_start_matches("wss://"))
        } else {
            trimmed.replace("ws://", "http://")
        };
        let port = http
            .rsplit(':')
            .next()
            .and_then(|value| value.trim_end_matches('/').parse::<u16>().ok())
            .unwrap_or(super::openclaw_gateway::DEFAULT_PORT);
        super::openclaw_gateway::GatewayEndpoint {
            host: "127.0.0.1".to_string(),
            port,
            attach_url: http,
            ws_url: if trimmed.starts_with("ws") {
                trimmed
            } else {
                format!("ws://{}", trimmed.trim_start_matches("http://"))
            },
        }
    } else {
        match super::openclaw_gateway::ensure_attach_endpoint(executable) {
            Ok(endpoint) => endpoint,
            Err(error) => {
                let code = error.to_string();
                let failure_code = if code.contains("openclaw_executable_missing") {
                    "openclaw_executable_missing"
                } else if code.contains("port_exhausted") {
                    "openclaw_gateway_port_exhausted"
                } else if code.contains("health_failed") {
                    "openclaw_gateway_health_failed"
                } else {
                    "openclaw_gateway_unavailable"
                };
                return RunResult::failed(
                    ProtocolFailure::new(
                        failure_code,
                        "OpenClaw Gateway is not available for attach.",
                        "gateway/ensure",
                    ),
                    started_at,
                    None,
                    false,
                    false,
                );
            }
        }
    };
    super::turn_event_emit::emit_turn_event(
        "dispatch.gateway.attached",
        config.native_session_key.as_deref().unwrap_or(""),
        &config.turn_id,
        json!({
            "wsUrlHostClass": "loopback",
            "port": gateway.port,
            "attachMode": if gateway.port == super::openclaw_gateway::VENDOR_DEFAULT_PORT {
                "vendor-default"
            } else {
                "managed-or-reused"
            }
        }),
    );
    let launch =
        LaunchSpec::for_gateway_attach(executable, Path::new(&config.cwd), &gateway.ws_url);
    let mut child = match launch.spawn() {
        Ok(child) => child,
        Err(error) => {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The OpenClaw executable is not available.",
                io::ErrorKind::PermissionDenied => {
                    "The OpenClaw executable is not permitted to run."
                }
                _ => "OpenClaw ACP could not be started against the Gateway.",
            };
            return RunResult::failed(
                ProtocolFailure::new("openclaw_acp_start_failed", message, "process/start"),
                started_at,
                None,
                false,
                false,
            );
        }
    };
    let Some(stdout) = child.stdout() else {
        return pipe_failure(
            &mut child,
            started_at,
            "OpenClaw ACP stdout is unavailable.",
        );
    };
    let Some(stderr) = child.stderr() else {
        return pipe_failure(
            &mut child,
            started_at,
            "OpenClaw ACP stderr is unavailable.",
        );
    };
    let Some(stdin) = child.stdin() else {
        return pipe_failure(&mut child, started_at, "OpenClaw ACP stdin is unavailable.");
    };
    let mut stdin = BoundedStdinWriter::new(stdin);

    let (sender, receiver) = mpsc::channel();
    let stdout_handle =
        thread::spawn(move || read_protocol_messages(BufReader::new(stdout), max_stdout, sender));
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));

    let mut protocol = OpenClawProtocol::new(config);
    if write_message(&mut stdin, &protocol.initial_request()).is_err() {
        let cleanup =
            finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
        let cleanup_failed = cleanup == Err(TransportFinishFailure::Lifecycle);
        return RunResult::failed(
            ProtocolFailure::new(
                if cleanup_failed {
                    "openclaw_acp_cleanup_failed"
                } else {
                    "openclaw_acp_write_failed"
                },
                if cleanup_failed {
                    "OpenClaw ACP process cleanup could not be completed safely."
                } else {
                    "OpenClaw ACP stopped accepting protocol messages."
                },
                if cleanup_failed {
                    "process/cleanup"
                } else {
                    "initialize"
                },
            ),
            started_at,
            None,
            false,
            stderr_truncated.load(Ordering::Relaxed),
        );
    }

    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let (outcome, failure, status_code, stdout_was_truncated) =
        run_protocol_loop(&mut stdin, &receiver, &mut protocol, deadline);

    let cleanup = finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
    let stderr_was_truncated = stderr_truncated.load(Ordering::Relaxed);

    if cleanup == Err(TransportFinishFailure::Lifecycle) {
        return RunResult::failed(
            ProtocolFailure::new(
                "openclaw_acp_cleanup_failed",
                "OpenClaw ACP process cleanup could not be completed safely.",
                "process/cleanup",
            ),
            started_at,
            status_code,
            stdout_was_truncated,
            stderr_was_truncated,
        );
    }
    if outcome.is_some() && cleanup == Err(TransportFinishFailure::StdinWrite) {
        return RunResult::failed(
            ProtocolFailure::new(
                "openclaw_acp_write_failed",
                "OpenClaw ACP stopped accepting protocol messages.",
                "protocol/write",
            ),
            started_at,
            status_code,
            stdout_was_truncated,
            stderr_was_truncated,
        );
    }

    if let Some(outcome) = outcome {
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
            status_code,
            stdout_truncated: stdout_was_truncated,
            stderr_truncated: stderr_was_truncated,
            started_at,
        };
    }
    RunResult::failed(
        failure.unwrap_or_else(|| {
            ProtocolFailure::new(
                "openclaw_acp_failed",
                "OpenClaw ACP did not complete the request.",
                "protocol",
            )
        }),
        started_at,
        status_code,
        stdout_was_truncated,
        stderr_was_truncated,
    )
}

fn run_protocol_loop(
    stdin: &mut BoundedStdinWriter,
    receiver: &Receiver<TransportEvent>,
    protocol: &mut OpenClawProtocol,
    deadline: Instant,
) -> (
    Option<ProtocolOutcome>,
    Option<ProtocolFailure>,
    Option<i32>,
    bool,
) {
    loop {
        if stdin.check_health().is_err() {
            return (
                None,
                Some(protocol.failure_with_ids(
                    "openclaw_acp_write_failed",
                    "OpenClaw ACP stopped accepting protocol messages.",
                    "protocol/write",
                )),
                None,
                false,
            );
        }
        let now = Instant::now();
        if now >= deadline {
            let mut failure = protocol.failure_with_ids(
                "openclaw_acp_timeout",
                "OpenClaw ACP timed out before the turn completed.",
                "turn/wait",
            );
            failure.turn_status = Some("timeout".to_string());
            return (None, Some(failure), None, false);
        }
        match receiver.recv_timeout((deadline - now).min(PROCESS_POLL_INTERVAL)) {
            Ok(TransportEvent::Message(message)) => {
                for effect in protocol.handle_message(message) {
                    match effect {
                        ProtocolEffect::Send(message) => {
                            if write_message(stdin, &message).is_err() {
                                return (
                                    None,
                                    Some(protocol.failure_with_ids(
                                        "openclaw_acp_write_failed",
                                        "OpenClaw ACP stopped accepting protocol messages.",
                                        "protocol/write",
                                    )),
                                    None,
                                    false,
                                );
                            }
                        }
                        ProtocolEffect::Complete(outcome) => {
                            return (Some(outcome), None, None, false);
                        }
                        ProtocolEffect::Fail(failure) => {
                            return (None, Some(failure), None, false);
                        }
                    }
                }
            }
            Ok(TransportEvent::InvalidJson) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "openclaw_acp_invalid_json",
                        "OpenClaw ACP returned an invalid protocol message.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutLimitExceeded) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "openclaw_acp_output_limit",
                        "OpenClaw ACP exceeded the configured protocol output limit.",
                        "protocol/read",
                    )),
                    None,
                    true,
                );
            }
            Ok(TransportEvent::StdoutReadFailed) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "openclaw_acp_read_failed",
                        "OpenClaw ACP protocol output could not be read.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "openclaw_acp_exited",
                        "OpenClaw ACP exited before the turn completed.",
                        "process/exit",
                    )),
                    None,
                    false,
                );
            }
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

pub(super) fn probe(executable: &str, timeout_ms: u64, max_output: usize) -> CapabilityProbe {
    let help = run_probe_command(executable, &["acp", "--help"], timeout_ms, max_output);
    let Ok(help) = help else {
        return CapabilityProbe {
            error_code: Some("openclaw_acp_probe_failed"),
            ..CapabilityProbe::default()
        };
    };
    let text = String::from_utf8_lossy(&help);
    let supported = text.contains("ACP") || text.contains("Gateway");
    let version = run_probe_command(executable, &["--version"], timeout_ms, max_output)
        .ok()
        .and_then(|bytes| first_nonempty_line(&bytes));
    CapabilityProbe {
        available: true,
        supported,
        version,
        error_code: (!supported).then_some("openclaw_acp_capability_missing"),
        supports_streaming: true,
        supports_tools: true,
        supports_approvals: true,
        supports_reasoning: true,
        supports_model_override: false,
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

fn pipe_failure(
    child: &mut SupervisedChild,
    started_at: String,
    message: &'static str,
) -> RunResult {
    let failure = if child.terminate_tree().is_ok() {
        ProtocolFailure::new("openclaw_acp_pipe_failed", message, "process/start")
    } else {
        ProtocolFailure::new(
            "openclaw_acp_cleanup_failed",
            "OpenClaw ACP process cleanup could not be completed safely.",
            "process/cleanup",
        )
    };
    RunResult::failed(failure, started_at, None, false, false)
}

fn write_message(stdin: &mut BoundedStdinWriter, message: &Value) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(message).map_err(io::Error::other)?;
    bytes.push(b'\n');
    stdin
        .enqueue(bytes)
        .map_err(|_| io::Error::other("native agent protocol write failed"))
}

fn read_protocol_messages<R: BufRead>(
    mut reader: R,
    max_bytes: usize,
    sender: Sender<TransportEvent>,
) {
    let mut total_bytes = 0usize;
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
        if total_bytes.saturating_add(consumed) > max_bytes {
            let _ = sender.send(TransportEvent::StdoutLimitExceeded);
            return;
        }
        let completed_line = available.get(consumed.saturating_sub(1)) == Some(&b'\n');
        line.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        total_bytes += consumed;
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
            .send(TransportEvent::Message(message))
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

fn normalize_agent_id(value: &str) -> String {
    let normalized = value
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
                character
            } else {
                '-'
            }
        })
        .collect::<String>();
    normalized.trim_matches('-').to_string()
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
                ProtocolEffect::Complete(_) | ProtocolEffect::Fail(_) => None,
            })
            .collect()
    }

    fn initialize(protocol: &mut OpenClawProtocol) -> Vec<ProtocolEffect> {
        protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "id": INITIALIZE_REQUEST_ID,
            "result": {
                "protocolVersion": 1,
                "agentCapabilities": {"loadSession": true, "sessionCapabilities": {"resume": {}}},
                "agentInfo": {"name": "openclaw-acp", "version": "test"}
            }
        }))
    }

    #[test]
    fn new_session_uses_only_acp_stdin_for_private_values() {
        let prompt = "private-openclaw-prompt";
        let mut protocol = OpenClawProtocol::new(config(
            json!({"reasoningEffort": "high", "openclawAgentId": "ops"}),
            prompt,
            "",
        ));
        let launch = LaunchSpec::for_gateway_attach(
            "openclaw",
            Path::new("/workspace/project"),
            "ws://127.0.0.1:24189",
        );
        assert_eq!(launch.args[0], "acp");
        assert_eq!(launch.args[1], "--url");
        assert_eq!(launch.args[2], "ws://127.0.0.1:24189");
        assert!(!launch.args.iter().any(|arg| arg.contains(prompt)));
        assert!(!launch.args.iter().any(|arg| arg.contains("workspace")));
        assert!(!launch.args[2].contains(prompt));

        let session = sent_messages(initialize(&mut protocol));
        assert_eq!(session[0]["method"], "session/new");
        assert_eq!(session[0]["params"]["cwd"], "/workspace/project");
        assert!(
            session[0]["params"]["_meta"]["sessionKey"]
                .as_str()
                .is_some_and(|key| key.starts_with("agent:ops:acp:"))
        );
        assert!(!session[0].to_string().contains(prompt));
    }

    #[test]
    fn exact_resume_uses_session_load_inside_json_rpc() {
        let mut protocol = OpenClawProtocol::new(config(json!({}), "hello", "native-session"));
        let session = sent_messages(initialize(&mut protocol));
        assert_eq!(session[0]["method"], "session/load");
        assert_eq!(session[0]["params"]["sessionId"], "native-session");
        assert_eq!(session[0]["params"]["mcpServers"], json!([]));
        assert_eq!(
            session[0]["params"]["_meta"]["sessionKey"],
            "native-session"
        );
        assert_eq!(session[0]["params"]["_meta"]["requireExisting"], true);
    }

    #[test]
    fn new_session_fails_if_gateway_session_key_is_not_exposed() {
        let mut protocol = OpenClawProtocol::new(config(json!({}), "hello", ""));
        initialize(&mut protocol);
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "id": SESSION_REQUEST_ID,
            "result": {"sessionId": "process-local-acp-session"}
        }));
        assert_eq!(effects.len(), 1);
        match &effects[0] {
            ProtocolEffect::Fail(failure) => {
                assert_eq!(failure.code, "openclaw_acp_native_session_id_missing");
            }
            _ => panic!("a process-local ACP id must not be reported as resumable"),
        }
    }

    #[test]
    fn permission_request_is_denied_and_requires_user_interaction() {
        let mut protocol = OpenClawProtocol::new(config(json!({}), "hello", "native-session"));
        initialize(&mut protocol);
        protocol.handle_message(json!({"id": SESSION_REQUEST_ID, "result": {}}));
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "id": "approval-1",
            "method": "session/request_permission",
            "params": {"sessionId": "native-session", "options": []}
        }));
        assert_eq!(effects.len(), 2);
        match &effects[0] {
            ProtocolEffect::Send(message) => {
                assert_eq!(message["result"]["outcome"]["outcome"], "cancelled");
            }
            _ => panic!("permission request must receive an explicit denial"),
        }
        match &effects[1] {
            ProtocolEffect::Fail(failure) => {
                assert!(failure.user_interaction_required);
                assert_eq!(failure.code, "openclaw_user_interaction_required");
            }
            _ => panic!("permission request must stop autonomous dispatch"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn fake_child_e2e_streams_final_and_drains_stderr() {
        let root = unique_temp_dir("openclaw-acp-e2e");
        let executable = root.join("fake-openclaw");
        write_executable(
            &executable,
            r#"#!/bin/sh
if [ "$1" = "acp" ] && [ "$2" = "--help" ]; then
  printf '%s\n' 'Run an ACP bridge backed by the Gateway'
  exit 0
fi
if [ "$1" = "--version" ]; then
  printf '%s\n' 'OpenClaw test-version'
  exit 0
fi
if [ "$1" != "acp" ]; then
  exit 40
fi
# Gateway-native attach passes --url ws://…; ignore remaining argv.
dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr '\000' x >&2 &
IFS= read -r init
case "$init" in *private-openclaw-prompt*|*workspace/project*) exit 41;; esac
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"openclaw-acp","version":"test"}}}'
IFS= read -r session
case "$session" in *private-openclaw-prompt*) exit 42;; esac
	printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"openclaw-acp-session","update":{"sessionUpdate":"session_info_update","_meta":{"sessionKey":"agent:main:acp:native-session"}}}}'
	printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"openclaw-acp-session","modes":{"currentModeId":"medium","availableModes":[]}}}'
	IFS= read -r mode
	case "$mode" in *'"sessionId":"openclaw-acp-session"'*) :;; *) exit 44;; esac
	printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{}}'
	IFS= read -r prompt
	case "$prompt" in *private-openclaw-prompt*) :;; *) exit 43;; esac
	case "$prompt" in *'"sessionId":"openclaw-acp-session"'*) :;; *) exit 45;; esac
printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"openclaw-acp-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"native "}}}}'
printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"openclaw-acp-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"answer"}}}}'
printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
wait
"#,
        );
        let result = execute(
            executable.to_str().unwrap(),
            &json!({
                "reasoningEffort": "medium",
                "gatewayWsUrl": "ws://127.0.0.1:9"
            }),
            "private-openclaw-prompt",
            "",
            Some(&root),
            5_000,
            128 * 1024,
            8 * 1024,
        );
        assert!(result.ok);
        assert_eq!(result.output, "native answer");
        assert_eq!(result.session_id, "agent:main:acp:native-session");
        assert_eq!(result.turn_status, "end_turn");
        assert_eq!(result.events.len(), 2);
        assert!(result.stderr_truncated);

        let probe = probe(executable.to_str().unwrap(), 2_000, 16 * 1024);
        assert!(probe.available);
        assert!(probe.supported);
        assert!(probe.supports_approvals);
        assert!(!probe.supports_model_override);
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
