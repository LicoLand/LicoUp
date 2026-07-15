use super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
};
use serde_json::{Value, json};
use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

/// Official Pi Coding Agent lane: `pi --mode rpc` JSONL over stdin/stdout.
/// Prompts and session identity stay on the stdio channel; launch argv is fixed.
pub(super) const RUNTIME_PROTOCOL: &str = "pi-rpc-stdio-jsonl";
const LAUNCH_ARGS: &[&str] = &["--mode", "rpc", "--offline"];
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
const MAX_SESSION_SCAN_FILES: usize = 4_096;

#[derive(Clone, Debug, Default)]
pub(super) struct EffectiveSettings {
    pub(super) cwd: Option<String>,
    pub(super) model: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) permission_mode: Option<String>,
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

    fn with_session(mut self, session_id: Option<&str>) -> Self {
        let session_id = session_id.map(str::trim).filter(|value| !value.is_empty());
        self.session_id = session_id.map(str::to_string);
        self
    }

    fn user_interaction(method: &str, session_id: Option<&str>, turn_id: Option<&str>) -> Self {
        Self {
            code: "pi_user_interaction_required",
            message: "Pi Agent requires explicit user interaction before this turn can continue.",
            stage: "extension/ui",
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
    pub(super) version_command_ok: bool,
    pub(super) help_command_ok: bool,
    pub(super) error_code: Option<&'static str>,
}

impl CapabilityProbe {
    fn unavailable() -> Self {
        Self {
            available: false,
            supported: false,
            version_command_ok: false,
            help_command_ok: false,
            error_code: Some("pi_executable_unavailable"),
        }
    }

    fn installed(version_command_ok: bool, help_command_ok: bool) -> Self {
        Self {
            available: true,
            supported: true,
            version_command_ok,
            help_command_ok,
            error_code: None,
        }
    }
}

#[derive(Clone, Debug)]
struct ProtocolConfig {
    prompt: String,
    requested_session_id: String,
    resume_session_path: Option<PathBuf>,
    cwd: String,
    model: Option<String>,
    model_provider: Option<String>,
    model_id: Option<String>,
    thinking_level: Option<String>,
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
                "pi_empty_prompt",
                "Pi Agent requires a non-empty message.",
                "request/validate",
            ));
        }
        if explicit_value(params, &["sandbox", "sandboxMode"]).is_some() {
            return Err(ProtocolFailure::new(
                "pi_sandbox_override_unsupported",
                "Pi RPC does not expose a per-turn sandbox override.",
                "capability/sandbox",
            ));
        }
        if explicit_value(params, &["approvalPolicy", "approval_policy"]).is_some() {
            return Err(ProtocolFailure::new(
                "pi_approval_override_unsupported",
                "Pi RPC approvals require an explicit client UI response.",
                "capability/approval",
            ));
        }
        let thinking_level =
            text_param(params, &["reasoningEffort", "reasoning_effort", "thinking"]);
        if thinking_level.as_deref().is_some_and(|value| {
            !matches!(
                value,
                "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max"
            )
        }) {
            return Err(ProtocolFailure::new(
                "pi_invalid_thinking_level",
                "Pi Agent does not support the requested thinking level.",
                "request/validate",
            ));
        }
        let cwd = cwd
            .filter(|path| path.is_absolute())
            .map(|path| path.to_string_lossy().to_string())
            .ok_or_else(|| {
                ProtocolFailure::new(
                    "pi_absolute_cwd_required",
                    "Pi Agent requires an absolute working directory.",
                    "request/validate",
                )
            })?;
        let requested_session_id = session_id.trim().to_string();
        let resume_session_path = if requested_session_id.is_empty() {
            None
        } else {
            Some(resolve_session_path(
                &requested_session_id,
                Path::new(&cwd),
            )?)
        };
        let model = text_param(params, &["model", "modelId"]);
        let (model_provider, model_id) = match model.as_deref() {
            Some(value) => {
                let Some((provider, model_id)) = value.split_once('/') else {
                    return Err(ProtocolFailure::new(
                        "pi_model_provider_required",
                        "Pi RPC model overrides require provider/model identity.",
                        "capability/model",
                    ));
                };
                if provider.trim().is_empty() || model_id.trim().is_empty() {
                    return Err(ProtocolFailure::new(
                        "pi_model_provider_required",
                        "Pi RPC model overrides require provider/model identity.",
                        "capability/model",
                    ));
                }
                (
                    Some(provider.trim().to_string()),
                    Some(model_id.trim().to_string()),
                )
            }
            None => (None, None),
        };
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id,
            resume_session_path,
            cwd,
            model,
            model_provider,
            model_id,
            thinking_level,
            turn_id: Uuid::new_v4().to_string(),
        })
    }

    fn is_resume(&self) -> bool {
        self.resume_session_path.is_some()
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
    AwaitSwitch,
    AwaitInitialState,
    AwaitModel,
    AwaitThinking,
    AwaitPromptAccept,
    AwaitSettled,
    AwaitAssistantText,
    AwaitState,
    Finished,
}

#[derive(Debug)]
struct PiProtocol {
    config: ProtocolConfig,
    phase: ProtocolPhase,
    session_id: Option<String>,
    output: String,
    events: Vec<Value>,
    effective: EffectiveSettings,
    pending_request: Option<&'static str>,
}

impl PiProtocol {
    fn new(config: ProtocolConfig) -> Self {
        let effective = EffectiveSettings {
            cwd: Some(config.cwd.clone()),
            model: config.model.clone(),
            reasoning_effort: config.thinking_level.clone(),
            ..EffectiveSettings::default()
        };
        let phase = if config.is_resume() {
            ProtocolPhase::AwaitSwitch
        } else {
            ProtocolPhase::AwaitInitialState
        };
        Self {
            config,
            phase,
            session_id: None,
            output: String::new(),
            events: Vec::new(),
            effective,
            pending_request: None,
        }
    }

    fn initial_request(&mut self) -> Value {
        if let Some(path) = self.config.resume_session_path.clone() {
            self.pending_request = Some("switch_session");
            return json!({
                "id": "lico-pi-switch",
                "type": "switch_session",
                "sessionPath": path.to_string_lossy()
            });
        }
        self.state_request("lico-pi-initial-state", ProtocolPhase::AwaitInitialState)
    }

    fn prompt_request(&mut self) -> Value {
        self.pending_request = Some("prompt");
        self.phase = ProtocolPhase::AwaitPromptAccept;
        json!({
            "id": "lico-pi-prompt",
            "type": "prompt",
            "message": self.config.prompt
        })
    }

    fn thinking_request(&mut self) -> Option<Value> {
        let level = self.config.thinking_level.clone()?;
        self.pending_request = Some("set_thinking_level");
        self.phase = ProtocolPhase::AwaitThinking;
        Some(json!({
            "id": "lico-pi-thinking",
            "type": "set_thinking_level",
            "level": level
        }))
    }

    fn state_request(&mut self, id: &'static str, phase: ProtocolPhase) -> Value {
        self.pending_request = Some("get_state");
        self.phase = phase;
        json!({
            "id": id,
            "type": "get_state"
        })
    }

    fn model_request(&mut self) -> Option<Value> {
        let provider = self.config.model_provider.clone()?;
        let model_id = self.config.model_id.clone()?;
        self.pending_request = Some("set_model");
        self.phase = ProtocolPhase::AwaitModel;
        Some(json!({
            "id": "lico-pi-model",
            "type": "set_model",
            "provider": provider,
            "modelId": model_id
        }))
    }

    fn next_configuration_request(&mut self) -> Value {
        if let Some(request) = self.model_request() {
            return request;
        }
        if let Some(request) = self.thinking_request() {
            return request;
        }
        self.prompt_request()
    }

    fn capture_state(&mut self, message: &Value) {
        if let Some(session_id) = message.pointer("/data/sessionId").and_then(Value::as_str) {
            self.session_id = Some(session_id.to_string());
        }
        if let Some(level) = message
            .pointer("/data/thinkingLevel")
            .and_then(Value::as_str)
        {
            self.effective.reasoning_effort = Some(level.to_string());
        }
        if let Some(model) = message.pointer("/data/model") {
            let provider = model.get("provider").and_then(Value::as_str);
            let model_id = model
                .get("id")
                .or_else(|| model.get("modelId"))
                .and_then(Value::as_str);
            if let (Some(provider), Some(model_id)) = (provider, model_id) {
                self.effective.model = Some(format!("{provider}/{model_id}"));
            }
        }
    }

    fn failure_with_ids(
        &self,
        code: &'static str,
        message: &'static str,
        stage: &'static str,
    ) -> ProtocolFailure {
        ProtocolFailure::new(code, message, stage)
            .with_session(
                self.session_id
                    .as_deref()
                    .or(Some(self.config.requested_session_id.as_str())),
            )
            .with_turn(&self.config.turn_id)
    }

    fn handle_message(&mut self, message: Value) -> Vec<ProtocolEffect> {
        let message_type = message.get("type").and_then(Value::as_str).unwrap_or("");
        if message_type == "extension_ui_request" {
            let method = message
                .get("method")
                .and_then(Value::as_str)
                .unwrap_or("extension_ui");
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::user_interaction(
                method,
                self.session_id.as_deref(),
                Some(&self.config.turn_id),
            ))];
        }
        if message_type == "response" {
            return self.handle_response(&message);
        }
        self.handle_event(&message)
    }

    fn handle_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        let command = message
            .get("command")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let success = message
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        match self.phase {
            ProtocolPhase::AwaitSwitch if command == "switch_session" => {
                if !success {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_session_switch_failed",
                        "Pi Agent could not switch to the requested session.",
                        "session/switch",
                    ))];
                }
                if let Some(cancelled) = message.pointer("/data/cancelled").and_then(Value::as_bool)
                    && cancelled
                {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_session_switch_cancelled",
                        "Pi Agent cancelled the session switch.",
                        "session/switch",
                    ))];
                }
                vec![ProtocolEffect::Send(self.state_request(
                    "lico-pi-switched-state",
                    ProtocolPhase::AwaitInitialState,
                ))]
            }
            ProtocolPhase::AwaitInitialState if command == "get_state" => {
                if !success {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_session_state_failed",
                        "Pi Agent did not expose the active session state.",
                        "session/state",
                    ))];
                }
                self.capture_state(message);
                let Some(active_session_id) = self.session_id.as_deref() else {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_session_id_missing",
                        "Pi Agent did not return a session identifier.",
                        "session/state",
                    ))];
                };
                if !self.config.requested_session_id.is_empty()
                    && active_session_id != self.config.requested_session_id
                {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_session_identity_mismatch",
                        "Pi Agent switched to a different session than requested.",
                        "session/switch",
                    ))];
                }
                vec![ProtocolEffect::Send(self.next_configuration_request())]
            }
            ProtocolPhase::AwaitModel if command == "set_model" => {
                if !success {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_model_override_failed",
                        "Pi Agent could not apply the requested model.",
                        "capability/model",
                    ))];
                }
                if let Some(model) = message.get("data") {
                    let provider = model.get("provider").and_then(Value::as_str);
                    let model_id = model
                        .get("id")
                        .or_else(|| model.get("modelId"))
                        .and_then(Value::as_str);
                    if let (Some(provider), Some(model_id)) = (provider, model_id) {
                        self.effective.model = Some(format!("{provider}/{model_id}"));
                    }
                }
                if let Some(request) = self.thinking_request() {
                    return vec![ProtocolEffect::Send(request)];
                }
                vec![ProtocolEffect::Send(self.prompt_request())]
            }
            ProtocolPhase::AwaitThinking if command == "set_thinking_level" => {
                if !success {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_thinking_override_failed",
                        "Pi Agent could not apply the requested thinking level.",
                        "capability/thinking",
                    ))];
                }
                vec![ProtocolEffect::Send(self.prompt_request())]
            }
            ProtocolPhase::AwaitPromptAccept if command == "prompt" => {
                if !success {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_prompt_rejected",
                        "Pi Agent rejected the prompt before acceptance.",
                        "prompt",
                    ))];
                }
                self.phase = ProtocolPhase::AwaitSettled;
                self.pending_request = None;
                Vec::new()
            }
            ProtocolPhase::AwaitAssistantText if command == "get_last_assistant_text" => {
                if success {
                    if let Some(text) = message.pointer("/data/text").and_then(Value::as_str) {
                        self.output = text.to_string();
                    }
                }
                self.pending_request = Some("get_state");
                self.phase = ProtocolPhase::AwaitState;
                vec![ProtocolEffect::Send(json!({
                    "id": "lico-pi-state",
                    "type": "get_state"
                }))]
            }
            ProtocolPhase::AwaitState if command == "get_state" => {
                if success {
                    self.capture_state(message);
                }
                if self.output.trim().is_empty() {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_final_message_missing",
                        "Pi Agent completed without a final assistant message.",
                        "prompt/complete",
                    ))];
                }
                let session_id = self
                    .session_id
                    .clone()
                    .filter(|value| !value.is_empty())
                    .or_else(|| {
                        (!self.config.requested_session_id.is_empty())
                            .then(|| self.config.requested_session_id.clone())
                    })
                    .unwrap_or_default();
                if session_id.is_empty() {
                    self.phase = ProtocolPhase::Finished;
                    return vec![ProtocolEffect::Fail(self.failure_with_ids(
                        "pi_session_id_missing",
                        "Pi Agent did not return a session identifier.",
                        "session/state",
                    ))];
                }
                self.session_id = Some(session_id.clone());
                super::turn_event_emit::emit_agent_message_completed(
                    &session_id,
                    &self.config.turn_id,
                    &self.output,
                );
                self.phase = ProtocolPhase::Finished;
                vec![ProtocolEffect::Complete(ProtocolOutcome {
                    output: self.output.clone(),
                    events: self.events.clone(),
                    session_id,
                    turn_id: self.config.turn_id.clone(),
                    turn_status: "end_turn".to_string(),
                    effective: self.effective.clone(),
                })]
            }
            _ => Vec::new(),
        }
    }

    fn handle_event(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        let message_type = message.get("type").and_then(Value::as_str).unwrap_or("");
        if self.phase == ProtocolPhase::AwaitSettled {
            if let Some(event) = sanitized_event(message) {
                self.events.push(event);
            }
            if let Some(delta) = message
                .pointer("/assistantMessageEvent/delta")
                .and_then(Value::as_str)
            {
                self.output.push_str(delta);
                if let Some(session_id) = self.session_id.as_deref() {
                    super::turn_event_emit::emit_agent_message_chunk(
                        session_id,
                        &self.config.turn_id,
                        delta,
                    );
                }
            }
            if message_type == "agent_settled" {
                self.pending_request = Some("get_last_assistant_text");
                self.phase = ProtocolPhase::AwaitAssistantText;
                return vec![ProtocolEffect::Send(json!({
                    "id": "lico-pi-assistant",
                    "type": "get_last_assistant_text"
                }))];
            }
        }
        Vec::new()
    }
}

fn sanitized_event(message: &Value) -> Option<Value> {
    let event_type = message.get("type").and_then(Value::as_str)?;
    match event_type {
        "agent_start" | "agent_end" | "agent_settled" | "turn_start" | "turn_end"
        | "message_start" | "message_end" | "queue_update" | "compaction_start"
        | "compaction_end" | "auto_retry_start" | "auto_retry_end" | "extension_error" => {
            Some(json!({ "type": event_type }))
        }
        "message_update" => Some(json!({
            "type": event_type,
            "deltaType": message.pointer("/assistantMessageEvent/type").and_then(Value::as_str).unwrap_or("")
        })),
        "tool_execution_start" | "tool_execution_update" | "tool_execution_end" => Some(json!({
            "type": event_type,
            "toolCallId": message.get("toolCallId").and_then(Value::as_str).unwrap_or(""),
            "toolName": message.get("toolName").and_then(Value::as_str).unwrap_or(""),
            "isError": message.get("isError").and_then(Value::as_bool)
        })),
        _ => None,
    }
}

impl ProtocolFailure {
    fn with_turn(mut self, turn_id: &str) -> Self {
        if !turn_id.is_empty() {
            self.turn_id = Some(turn_id.to_string());
        }
        self
    }
}

#[derive(Clone, Debug)]
struct LaunchSpec {
    executable: String,
    args: Vec<&'static str>,
    cwd: PathBuf,
}

impl LaunchSpec {
    fn new(executable: &str, cwd: &Path) -> Self {
        Self {
            executable: executable.to_string(),
            args: LAUNCH_ARGS.to_vec(),
            cwd: cwd.to_path_buf(),
        }
    }

    fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(self.args.clone())
            .current_dir(&self.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
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

pub(super) fn probe(executable: &str, timeout_ms: u64, _max_output: usize) -> CapabilityProbe {
    let version_ok = run_probe_command(executable, "--version", timeout_ms) == Some(true);
    let help_ok = run_probe_command(executable, "--help", timeout_ms) == Some(true);
    if !version_ok && !help_ok {
        CapabilityProbe::unavailable()
    } else {
        CapabilityProbe::installed(version_ok, help_ok)
    }
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
    let launch = LaunchSpec::new(executable, Path::new(&config.cwd));
    let mut child = match launch.spawn() {
        Ok(child) => child,
        Err(error) => {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The Pi Agent executable is not available.",
                io::ErrorKind::PermissionDenied => {
                    "The Pi Agent executable is not permitted to run."
                }
                _ => "Pi RPC could not be started.",
            };
            return RunResult::failed(
                ProtocolFailure::new("pi_rpc_start_failed", message, "process/start"),
                started_at,
                None,
                false,
                false,
            );
        }
    };
    let Some(stdout) = child.stdout() else {
        return pipe_failure(&mut child, started_at, "Pi RPC stdout is unavailable.");
    };
    let Some(stderr) = child.stderr() else {
        return pipe_failure(&mut child, started_at, "Pi RPC stderr is unavailable.");
    };
    let Some(stdin) = child.stdin() else {
        return pipe_failure(&mut child, started_at, "Pi RPC stdin is unavailable.");
    };
    let mut stdin = BoundedStdinWriter::new(stdin);

    let (sender, receiver) = mpsc::channel();
    let stdout_handle =
        thread::spawn(move || read_protocol_messages(BufReader::new(stdout), max_stdout, sender));
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));

    let mut protocol = PiProtocol::new(config);
    let initial = protocol.initial_request();
    if write_message(&mut stdin, &initial).is_err() {
        let cleanup =
            finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
        let cleanup_failed = cleanup == Err(TransportFinishFailure::Lifecycle);
        return RunResult::failed(
            ProtocolFailure::new(
                if cleanup_failed {
                    "pi_rpc_cleanup_failed"
                } else {
                    "pi_rpc_write_failed"
                },
                if cleanup_failed {
                    "Pi RPC process cleanup could not be completed safely."
                } else {
                    "Pi RPC stopped accepting protocol messages."
                },
                if cleanup_failed {
                    "process/cleanup"
                } else {
                    "protocol/write"
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
                "pi_rpc_cleanup_failed",
                "Pi RPC process cleanup could not be completed safely.",
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
                "pi_rpc_write_failed",
                "Pi RPC stopped accepting protocol messages.",
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
                "pi_rpc_failed",
                "Pi RPC did not complete the request.",
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
    protocol: &mut PiProtocol,
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
                    "pi_rpc_write_failed",
                    "Pi RPC stopped accepting protocol messages.",
                    "protocol/write",
                )),
                None,
                false,
            );
        }
        let now = Instant::now();
        if now >= deadline {
            return (
                None,
                Some(protocol.failure_with_ids(
                    "pi_rpc_timeout",
                    "Pi RPC timed out before the turn completed.",
                    "turn/wait",
                )),
                None,
                false,
            );
        }
        match receiver.recv_timeout((deadline - now).min(PROCESS_POLL_INTERVAL)) {
            Ok(TransportEvent::Message(message)) => {
                for effect in protocol.handle_message(message) {
                    match effect {
                        ProtocolEffect::Send(payload) => {
                            if write_message(stdin, &payload).is_err() {
                                return (
                                    None,
                                    Some(protocol.failure_with_ids(
                                        "pi_rpc_write_failed",
                                        "Pi RPC stopped accepting protocol messages.",
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
                    Some(protocol.failure_with_ids(
                        "pi_rpc_invalid_json",
                        "Pi RPC returned an invalid protocol frame.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutLimitExceeded) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "pi_rpc_output_limit",
                        "Pi RPC exceeded the bounded stdout limit.",
                        "protocol/read",
                    )),
                    None,
                    true,
                );
            }
            Ok(TransportEvent::StdoutReadFailed) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "pi_rpc_read_failed",
                        "Pi RPC stdout could not be read.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "pi_rpc_exited",
                        "Pi RPC exited before the turn completed.",
                        "process/exit",
                    )),
                    None,
                    false,
                );
            }
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "pi_rpc_exited",
                        "Pi RPC exited before the turn completed.",
                        "process/exit",
                    )),
                    None,
                    false,
                );
            }
        }
    }
}

fn resolve_session_path(session_id: &str, cwd: &Path) -> Result<PathBuf, ProtocolFailure> {
    let trimmed = session_id.trim();
    if trimmed.is_empty() {
        return Err(ProtocolFailure::new(
            "pi_session_id_missing",
            "Pi Agent resume requires a native session identifier.",
            "session/resume",
        ));
    }
    let mut scanned = 0usize;
    let mut matches = Vec::new();
    for root in session_roots() {
        find_session_files(&root, trimmed, &mut scanned, &mut matches);
        if scanned >= MAX_SESSION_SCAN_FILES {
            break;
        }
    }
    if matches.len() > 1 {
        return Err(ProtocolFailure::new(
            "pi_session_identity_ambiguous",
            "Pi Agent found more than one session with the requested identity.",
            "session/resume",
        )
        .with_session(Some(trimmed)));
    }
    if let Some(path) = matches.pop() {
        return Ok(path);
    }
    let _ = cwd;
    Err(ProtocolFailure::new(
        "pi_session_not_found",
        "Pi Agent could not resolve the requested session without placing identity on argv.",
        "session/resume",
    )
    .with_session(Some(trimmed)))
}

fn session_roots() -> Vec<PathBuf> {
    if let Ok(dir) = env::var("PI_CODING_AGENT_SESSION_DIR") {
        let path = PathBuf::from(dir.trim());
        if !path.as_os_str().is_empty() {
            return vec![path];
        }
    }
    if let Ok(dir) = env::var("PI_CODING_AGENT_DIR") {
        let path = PathBuf::from(dir.trim()).join("sessions");
        if !path.as_os_str().is_empty() {
            return vec![path];
        }
    }
    if let Some(home) = env::var_os("HOME").or_else(|| env::var_os("USERPROFILE")) {
        return vec![
            PathBuf::from(home)
                .join(".pi")
                .join("agent")
                .join("sessions"),
        ];
    }
    Vec::new()
}

fn find_session_files(
    root: &Path,
    session_id: &str,
    scanned: &mut usize,
    matches: &mut Vec<PathBuf>,
) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            if *scanned >= MAX_SESSION_SCAN_FILES {
                return;
            }
            *scanned += 1;
            let path = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                stack.push(path);
                continue;
            }
            if !file_type.is_file() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
                continue;
            };
            if !name.ends_with(".jsonl") {
                continue;
            }
            if session_header_matches(&path, session_id) {
                matches.push(path);
            }
        }
    }
}

fn session_header_matches(path: &Path, session_id: &str) -> bool {
    const MAX_HEADER_BYTES: u64 = 64 * 1024;
    let Ok(file) = fs::File::open(path) else {
        return false;
    };
    let mut bytes = Vec::with_capacity(MAX_HEADER_BYTES as usize);
    if file.take(MAX_HEADER_BYTES).read_to_end(&mut bytes).is_err() {
        return false;
    }
    let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') else {
        return false;
    };
    let Ok(line) = std::str::from_utf8(&bytes[..newline]) else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<Value>(line.trim_end_matches('\r')) else {
        return false;
    };
    value.get("type").and_then(Value::as_str) == Some("session")
        && value.get("id").and_then(Value::as_str) == Some(session_id)
}

fn run_probe_command(executable: &str, argument: &str, timeout_ms: u64) -> Option<bool> {
    let mut command = Command::new(executable);
    command
        .arg(argument)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = SupervisedChild::spawn(&mut command).ok()?;
    let status = child
        .finish_or_terminate_tree(Duration::from_millis(timeout_ms))
        .ok()?;
    Some(status.map(|value| value.success()).unwrap_or(false))
}

fn write_message(stdin: &mut BoundedStdinWriter, message: &Value) -> io::Result<()> {
    let mut payload = serde_json::to_vec(message).map_err(io::Error::other)?;
    payload.push(b'\n');
    stdin
        .enqueue(payload)
        .map_err(|_| io::Error::other("native agent protocol write failed"))
}

fn read_protocol_messages<R: Read>(
    mut reader: BufReader<R>,
    max_stdout: usize,
    sender: Sender<TransportEvent>,
) {
    let mut total = 0usize;
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => {
                let _ = sender.send(TransportEvent::StdoutClosed);
                return;
            }
            Ok(read) => {
                total = total.saturating_add(read);
                if total > max_stdout {
                    let _ = sender.send(TransportEvent::StdoutLimitExceeded);
                    return;
                }
                let trimmed = line.trim_end_matches(['\r', '\n']);
                if trimmed.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(trimmed) {
                    Ok(message) => {
                        if sender.send(TransportEvent::Message(message)).is_err() {
                            return;
                        }
                    }
                    Err(_) => {
                        let _ = sender.send(TransportEvent::InvalidJson);
                        return;
                    }
                }
            }
            Err(_) => {
                let _ = sender.send(TransportEvent::StdoutReadFailed);
                return;
            }
        }
    }
}

fn drain_stderr<R: Read>(reader: R, max_bytes: usize, truncated: &Arc<AtomicBool>) {
    let mut reader = reader;
    let mut buffer = [0_u8; 8 * 1024];
    let mut kept = 0usize;
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return,
            Ok(read) => {
                kept = kept.saturating_add(read);
                if kept > max_bytes {
                    truncated.store(true, Ordering::Relaxed);
                    return;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => {
                truncated.store(true, Ordering::Relaxed);
                return;
            }
        }
    }
}

fn pipe_failure(child: &mut SupervisedChild, started_at: String, _message: &str) -> RunResult {
    let _ = child.terminate_tree();
    RunResult::failed(
        ProtocolFailure::new(
            "pi_rpc_pipe_failed",
            "Pi RPC pipes are unavailable.",
            "process/start",
        ),
        started_at,
        None,
        false,
        false,
    )
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
    use std::sync::Mutex;
    use std::time::{SystemTime, UNIX_EPOCH};

    static SESSION_ENV_LOCK: Mutex<()> = Mutex::new(());

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn launch_args_are_fixed_rpc_without_prompt_or_session() {
        let launch = LaunchSpec::new("pi", Path::new("/workspace/project"));
        assert_eq!(launch.args, LAUNCH_ARGS);
        assert!(
            !launch
                .args
                .iter()
                .any(|argument| argument.contains("prompt") || argument.contains("session"))
        );
        assert_eq!(RUNTIME_PROTOCOL, "pi-rpc-stdio-jsonl");
    }

    #[test]
    fn empty_prompt_fails_closed() {
        let failure = ProtocolConfig::from_params(
            &json!({}),
            "   ",
            "",
            Some(Path::new("/workspace/project")),
        )
        .unwrap_err();
        assert_eq!(failure.code, "pi_empty_prompt");
    }

    #[test]
    fn relative_cwd_fails_closed() {
        let failure =
            ProtocolConfig::from_params(&json!({}), "hello", "", Some(Path::new("relative")))
                .unwrap_err();
        assert_eq!(failure.code, "pi_absolute_cwd_required");
    }

    #[test]
    fn missing_resume_session_fails_without_argv_identity() {
        let failure = ProtocolConfig::from_params(
            &json!({}),
            "hello",
            "missing-session-id",
            Some(Path::new("/workspace/project")),
        )
        .unwrap_err();
        assert_eq!(failure.code, "pi_session_not_found");
    }

    #[test]
    fn new_session_prompt_stays_on_stdio_channel() {
        let config = ProtocolConfig::from_params(
            &json!({}),
            "private-pi-prompt",
            "",
            Some(Path::new("/workspace/project")),
        )
        .unwrap();
        let mut protocol = PiProtocol::new(config);
        let request = protocol.initial_request();
        assert_eq!(request["type"], "get_state");
        let effects = protocol.handle_message(json!({
            "id": "lico-pi-initial-state",
            "type": "response",
            "command": "get_state",
            "success": true,
            "data": {"sessionId": "new-session"}
        }));
        let ProtocolEffect::Send(prompt) = &effects[0] else {
            panic!("initial state must advance to prompt");
        };
        assert_eq!(prompt["type"], "prompt");
        assert_eq!(prompt["message"], "private-pi-prompt");
        let launch = LaunchSpec::new("pi", Path::new("/workspace/project"));
        assert!(
            !launch
                .args
                .iter()
                .any(|arg| arg.contains("private-pi-prompt"))
        );
    }

    #[test]
    fn model_override_requires_provider_and_uses_rpc() {
        let failure = ProtocolConfig::from_params(
            &json!({"model": "model-without-provider"}),
            "hello",
            "",
            Some(Path::new("/workspace/project")),
        )
        .unwrap_err();
        assert_eq!(failure.code, "pi_model_provider_required");

        let config = ProtocolConfig::from_params(
            &json!({"model": "provider/model"}),
            "hello",
            "",
            Some(Path::new("/workspace/project")),
        )
        .unwrap();
        let mut protocol = PiProtocol::new(config);
        let _ = protocol.initial_request();
        let effects = protocol.handle_message(json!({
            "id": "lico-pi-initial-state",
            "type": "response",
            "command": "get_state",
            "success": true,
            "data": {"sessionId": "session-model"}
        }));
        let ProtocolEffect::Send(request) = &effects[0] else {
            panic!("initial state must advance to model configuration");
        };
        assert_eq!(request["type"], "set_model");
        assert_eq!(request["provider"], "provider");
        assert_eq!(request["modelId"], "model");
    }

    #[test]
    fn exact_resume_uses_switch_session_over_rpc() {
        let _environment_guard = SESSION_ENV_LOCK.lock().unwrap();
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let root = std::env::temp_dir().join(format!("lico-pi-session-{stamp}"));
        let project = root.join("--path--");
        fs::create_dir_all(&project).unwrap();
        let session_path = project.join("20260101_abc-session.jsonl");
        fs::write(
            &session_path,
            r#"{"type":"session","version":3,"id":"abc-session","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/workspace/project"}
"#,
        )
        .unwrap();
        unsafe {
            env::set_var("PI_CODING_AGENT_SESSION_DIR", &root);
        }
        let config = ProtocolConfig::from_params(
            &json!({}),
            "continue please",
            "abc-session",
            Some(Path::new("/workspace/project")),
        )
        .unwrap();
        unsafe {
            env::remove_var("PI_CODING_AGENT_SESSION_DIR");
        }
        let mut protocol = PiProtocol::new(config);
        let request = protocol.initial_request();
        assert_eq!(request["type"], "switch_session");
        assert_eq!(
            request["sessionPath"].as_str().unwrap(),
            session_path.to_string_lossy()
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn duplicate_exact_session_identity_fails_closed() {
        let _environment_guard = SESSION_ENV_LOCK.lock().unwrap();
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let root = std::env::temp_dir().join(format!("lico-pi-ambiguous-{stamp}"));
        fs::create_dir_all(root.join("a")).unwrap();
        fs::create_dir_all(root.join("b")).unwrap();
        let header = r#"{"type":"session","version":3,"id":"duplicate-session"}
"#;
        fs::write(root.join("a/first.jsonl"), header).unwrap();
        fs::write(root.join("b/second.jsonl"), header).unwrap();
        unsafe {
            env::set_var("PI_CODING_AGENT_SESSION_DIR", &root);
        }
        let failure = ProtocolConfig::from_params(
            &json!({}),
            "continue",
            "duplicate-session",
            Some(Path::new("/workspace/project")),
        )
        .unwrap_err();
        unsafe {
            env::remove_var("PI_CODING_AGENT_SESSION_DIR");
        }
        assert_eq!(failure.code, "pi_session_identity_ambiguous");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn switched_state_must_confirm_requested_identity() {
        let config = ProtocolConfig {
            prompt: "continue".to_string(),
            requested_session_id: "expected-session".to_string(),
            resume_session_path: Some(PathBuf::from("/tmp/session.jsonl")),
            cwd: "/workspace/project".to_string(),
            model: None,
            model_provider: None,
            model_id: None,
            thinking_level: None,
            turn_id: "turn".to_string(),
        };
        let mut protocol = PiProtocol::new(config);
        let _ = protocol.initial_request();
        let switch = protocol.handle_message(json!({
            "id": "lico-pi-switch",
            "type": "response",
            "command": "switch_session",
            "success": true,
            "data": {"cancelled": false}
        }));
        assert!(matches!(switch[0], ProtocolEffect::Send(_)));
        let state = protocol.handle_message(json!({
            "id": "lico-pi-switched-state",
            "type": "response",
            "command": "get_state",
            "success": true,
            "data": {"sessionId": "wrong-session"}
        }));
        assert!(matches!(
            state[0],
            ProtocolEffect::Fail(ProtocolFailure {
                code: "pi_session_identity_mismatch",
                ..
            })
        ));
    }

    #[test]
    fn extension_ui_request_fails_closed() {
        let config = ProtocolConfig::from_params(
            &json!({}),
            "hello",
            "",
            Some(Path::new("/workspace/project")),
        )
        .unwrap();
        let mut protocol = PiProtocol::new(config);
        let effects = protocol.handle_message(json!({
            "type": "extension_ui_request",
            "id": "ui-1",
            "method": "confirm"
        }));
        assert!(matches!(
            effects[0],
            ProtocolEffect::Fail(ProtocolFailure {
                code: "pi_user_interaction_required",
                user_interaction_required: true,
                ..
            })
        ));
    }

    #[test]
    fn fake_child_completes_new_session_over_rpc() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let dir = std::env::temp_dir().join(format!("lico-pi-rpc-fake-{stamp}"));
        fs::create_dir_all(&dir).unwrap();
        let script = dir.join("fake-pi");
        fs::write(
            &script,
            r#"#!/usr/bin/env python3
import json, sys
assert sys.argv[1:] == ["--mode", "rpc", "--offline"]
assert not any("private-pi" in arg for arg in sys.argv)
for line in sys.stdin:
    cmd = json.loads(line)
    if cmd.get("type") == "prompt":
        assert cmd["message"] == "private-pi-prompt"
        print(json.dumps({"id": cmd["id"], "type": "response", "command": "prompt", "success": True}), flush=True)
        print(json.dumps({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "delta": "pi-ok"}}), flush=True)
        print(json.dumps({"type": "agent_settled"}), flush=True)
    elif cmd.get("type") == "get_last_assistant_text":
        print(json.dumps({"id": cmd["id"], "type": "response", "command": "get_last_assistant_text", "success": True, "data": {"text": "pi-ok"}}), flush=True)
    elif cmd.get("type") == "get_state":
        print(json.dumps({"id": cmd["id"], "type": "response", "command": "get_state", "success": True, "data": {"sessionId": "pi-native-1"}}), flush=True)
"#,
        )
        .unwrap();
        #[cfg(unix)]
        {
            let mut perms = fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&script, perms).unwrap();
        }
        let result = execute(
            script.to_string_lossy().as_ref(),
            &json!({}),
            "private-pi-prompt",
            "",
            Some(dir.as_path()),
            10_000,
            1024 * 1024,
            1024,
        );
        assert!(result.ok, "pi rpc failure: {:?}", result.error);
        assert_eq!(result.output, "pi-ok");
        assert_eq!(result.session_id, "pi-native-1");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn fake_child_emits_incremental_text_with_bound_session_identity() {
        use std::sync::{Arc, Mutex};

        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let dir = std::env::temp_dir().join(format!("lico-pi-rpc-stream-{stamp}"));
        fs::create_dir_all(&dir).unwrap();
        let script = dir.join("fake-pi");
        fs::write(
            &script,
            r#"#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    cmd = json.loads(line)
    if cmd.get("type") == "get_state":
        print(json.dumps({"id": cmd["id"], "type": "response", "command": "get_state", "success": True, "data": {"sessionId": "pi-stream-1"}}), flush=True)
    elif cmd.get("type") == "prompt":
        print(json.dumps({"id": cmd["id"], "type": "response", "command": "prompt", "success": True}), flush=True)
        print(json.dumps({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "delta": "one"}}), flush=True)
        print(json.dumps({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "delta": "-two"}}), flush=True)
        print(json.dumps({"type": "agent_settled"}), flush=True)
    elif cmd.get("type") == "get_last_assistant_text":
        print(json.dumps({"id": cmd["id"], "type": "response", "command": "get_last_assistant_text", "success": True, "data": {"text": "one-two"}}), flush=True)
"#,
        )
        .unwrap();
        #[cfg(unix)]
        {
            let mut perms = fs::metadata(&script).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&script, perms).unwrap();
        }
        let captured = Arc::new(Mutex::new(Vec::<Value>::new()));
        let target = Arc::clone(&captured);
        super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
            target.lock().unwrap().push(event);
        }));
        let _guard = super::super::turn_event_emit::StreamSinkGuard;
        let result = execute(
            script.to_string_lossy().as_ref(),
            &json!({}),
            "stream",
            "",
            Some(dir.as_path()),
            10_000,
            1024 * 1024,
            1024,
        );
        assert!(result.ok, "pi rpc failure: {:?}", result.error);
        let events = captured.lock().unwrap();
        let chunks = events
            .iter()
            .filter(|event| event["event"] == "agent.message.chunk")
            .collect::<Vec<_>>();
        assert_eq!(chunks.len(), 2);
        assert!(
            chunks
                .iter()
                .all(|event| event["sessionId"] == "pi-stream-1")
        );
        assert_eq!(chunks[0]["payload"]["text"], "one");
        assert_eq!(chunks[1]["payload"]["text"], "-two");
        let _ = fs::remove_dir_all(dir);
    }
}
