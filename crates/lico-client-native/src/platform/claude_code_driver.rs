use super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, SyncSender, TryRecvError};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub(super) const RUNTIME_PROTOCOL: &str = "claude-code-cli-stream-json";

const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
const CONTROL_ACK_TIMEOUT: Duration = Duration::from_secs(1);
const CONTROL_QUEUE_CAPACITY: usize = 4;
const MAX_PROTOCOL_LINE_BYTES: usize = 8 * 1024 * 1024;
const MAX_POOLED_TRANSPORTS: usize = 8;
const MAX_TRACKED_SESSIONS: usize = 1024;

static NEXT_TRANSPORT_ID: AtomicU64 = AtomicU64::new(1);
static TRANSPORT_POOL: OnceLock<Mutex<HashMap<u64, Arc<ManagedTransport>>>> = OnceLock::new();
static SESSION_TRANSPORTS: OnceLock<Mutex<HashMap<String, Weak<ManagedTransport>>>> =
    OnceLock::new();

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
    pub(super) thread_id: Option<String>,
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
            thread_id: None,
            turn_id: None,
            turn_status: None,
        }
    }

    fn with_session(mut self, session_id: Option<&str>) -> Self {
        self.session_id = session_id.map(str::to_string);
        self.thread_id = self.session_id.clone();
        self
    }

    fn with_turn(mut self, turn_id: &str) -> Self {
        self.turn_id = Some(turn_id.to_string());
        self
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
        stdout_truncated: bool,
        stderr_truncated: bool,
    ) -> Self {
        let session_id = failure.session_id.clone().unwrap_or_default();
        Self {
            ok: false,
            output: String::new(),
            events: Vec::new(),
            thread_id: failure
                .thread_id
                .clone()
                .unwrap_or_else(|| session_id.clone()),
            session_id,
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            error: Some(failure),
            status_code: None,
            stdout_truncated,
            stderr_truncated,
            started_at,
        }
    }
}

/// The official streaming-input lane owns continuation only while the exact
/// supervised process remains alive. The fixed launch disables transcript
/// persistence, and persisted CLI resume is intentionally not used because its
/// public contract places the native session ID on argv.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct CapabilityProbe {
    pub(super) available: bool,
    pub(super) version_command_ok: bool,
    pub(super) help_command_ok: bool,
    pub(super) stdin_prompt: bool,
    pub(super) structured_stream: bool,
    pub(super) new_session: bool,
    pub(super) resume_session: bool,
    pub(super) model: bool,
    pub(super) reasoning_effort: bool,
    pub(super) permission_mode: bool,
    pub(super) interactive_approval_events: bool,
}

impl CapabilityProbe {
    fn official(version_command_ok: bool, help_command_ok: bool) -> Self {
        Self {
            available: version_command_ok || help_command_ok,
            version_command_ok,
            help_command_ok,
            stdin_prompt: true,
            structured_stream: true,
            new_session: true,
            resume_session: true,
            model: true,
            reasoning_effort: true,
            permission_mode: true,
            interactive_approval_events: false,
        }
    }
}

#[derive(Clone, Debug)]
struct DriverConfig {
    prompt: String,
    requested_session_id: String,
    model: Option<String>,
    reasoning_effort: Option<String>,
    permission_mode: Option<String>,
    turn_id: String,
}

impl DriverConfig {
    fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        _cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        if prompt.trim().is_empty() {
            return Err(ProtocolFailure::new(
                "claude_code_empty_prompt",
                "Claude Code requires a non-empty message.",
                "request/validate",
            ));
        }
        let reasoning_effort = text_param(params, &["reasoningEffort", "reasoning_effort"]);
        if reasoning_effort.as_deref().is_some_and(|value| {
            !matches!(
                value,
                "low" | "medium" | "high" | "xhigh" | "max" | "ultracode"
            )
        }) {
            return Err(ProtocolFailure::new(
                "claude_code_invalid_effort",
                "Claude Code does not support the requested effort level.",
                "request/validate",
            ));
        }
        let permission_mode = text_param(
            params,
            &[
                "permissionMode",
                "permission_mode",
                "approvalPolicy",
                "approval_policy",
            ],
        )
        .map(|value| match value.as_str() {
            "manual" => "manual".to_string(),
            "on-request" => "default".to_string(),
            "never" => "dontAsk".to_string(),
            _ => value,
        });
        if permission_mode.as_deref().is_some_and(|value| {
            !matches!(
                value,
                "default"
                    | "manual"
                    | "acceptEdits"
                    | "plan"
                    | "auto"
                    | "dontAsk"
                    | "bypassPermissions"
            )
        }) {
            return Err(ProtocolFailure::new(
                "claude_code_invalid_permission_mode",
                "Claude Code does not support the requested permission mode.",
                "request/validate",
            ));
        }
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id: session_id.trim().to_string(),
            model: text_param(params, &["model", "modelId"]),
            reasoning_effort,
            permission_mode,
            turn_id: Uuid::new_v4().to_string(),
        })
    }

    fn stdin_message(&self) -> io::Result<Value> {
        // No prompt or session identifier is ever placed in LaunchSpec.
        serde_json::to_value(json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": self.prompt}]
            }
        }))
        .map_err(io::Error::other)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct LaunchIdentity {
    executable: String,
    cwd: Option<PathBuf>,
    model: Option<String>,
    reasoning_effort: Option<String>,
    permission_mode: Option<String>,
}

impl LaunchIdentity {
    fn new(executable: &str, config: &DriverConfig, cwd: Option<&Path>) -> Self {
        Self {
            executable: executable.to_string(),
            cwd: cwd.map(Path::to_path_buf),
            model: config.model.clone(),
            reasoning_effort: config.reasoning_effort.clone(),
            permission_mode: config.permission_mode.clone(),
        }
    }

    fn compatible_with(&self, executable: &str, config: &DriverConfig, cwd: Option<&Path>) -> bool {
        self.executable == executable
            && self.cwd.as_deref() == cwd
            && config
                .model
                .as_ref()
                .is_none_or(|value| self.model.as_ref() == Some(value))
            && config
                .reasoning_effort
                .as_ref()
                .is_none_or(|value| self.reasoning_effort.as_ref() == Some(value))
            && config
                .permission_mode
                .as_ref()
                .is_none_or(|value| self.permission_mode.as_ref() == Some(value))
    }

    fn args(&self) -> Vec<String> {
        let mut args = vec![
            "--print".to_string(),
            "--input-format".to_string(),
            "stream-json".to_string(),
            "--output-format".to_string(),
            "stream-json".to_string(),
            "--verbose".to_string(),
            "--include-partial-messages".to_string(),
            "--no-session-persistence".to_string(),
        ];
        if let Some(model) = self.model.as_ref() {
            args.extend(["--model".to_string(), model.clone()]);
        }
        if let Some(effort) = self.reasoning_effort.as_ref() {
            args.extend(["--effort".to_string(), effort.clone()]);
        }
        if let Some(permission_mode) = self.permission_mode.as_ref() {
            args.extend(["--permission-mode".to_string(), permission_mode.clone()]);
        }
        args
    }

    fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(self.args())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(cwd) = self.cwd.as_ref() {
            command.current_dir(cwd);
        }
        SupervisedChild::spawn(&mut command)
    }

    fn effective(&self) -> EffectiveSettings {
        EffectiveSettings {
            cwd: self
                .cwd
                .as_ref()
                .map(|path| path.to_string_lossy().to_string()),
            model: self.model.clone(),
            reasoning_effort: self.reasoning_effort.clone(),
            permission_mode: self.permission_mode.clone(),
            sandbox: None,
            approval_policy: self.permission_mode.clone().map(Value::String),
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
    id: u64,
    identity: LaunchIdentity,
    transport: Mutex<PersistentTransport>,
    control_sender: SyncSender<ControlRequest>,
    native_session_id: Mutex<Option<String>>,
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
        identity: &LaunchIdentity,
        control_receiver: Receiver<ControlRequest>,
        max_stderr: usize,
    ) -> Result<Self, ProtocolFailure> {
        let mut child = identity.spawn().map_err(|error| {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The Claude Code executable is not available.",
                io::ErrorKind::PermissionDenied => {
                    "The Claude Code executable is not permitted to run."
                }
                _ => "Claude Code could not be started.",
            };
            ProtocolFailure::new("claude_code_start_failed", message, "process/start")
        })?;
        let stdout = child.stdout().ok_or_else(|| pipe_failure("stdout"))?;
        let stderr = child.stderr().ok_or_else(|| pipe_failure("stderr"))?;
        let stdin = child.stdin().ok_or_else(|| pipe_failure("stdin"))?;
        let (sender, receiver) = mpsc::channel();
        let stdout_handle =
            thread::spawn(move || read_protocol_messages(BufReader::new(stdout), sender));
        let stderr_truncated = Arc::new(AtomicBool::new(false));
        let stderr_flag = Arc::clone(&stderr_truncated);
        let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));
        Ok(Self {
            child,
            stdin: BoundedStdinWriter::new(stdin),
            receiver,
            control_receiver,
            stdout_handle: Some(stdout_handle),
            stderr_handle: Some(stderr_handle),
            stderr_truncated,
            closed: false,
        })
    }

    fn shutdown(&mut self) -> Result<(), TransportFinishFailure> {
        if self.closed {
            return Ok(());
        }
        self.closed = true;
        let stdout = self
            .stdout_handle
            .take()
            .ok_or(TransportFinishFailure::Lifecycle)?;
        let stderr = self
            .stderr_handle
            .take()
            .ok_or(TransportFinishFailure::Lifecycle)?;
        finish_protocol_transport(&mut self.child, &mut self.stdin, stdout, stderr)
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

#[derive(Debug)]
struct TurnOutcome {
    output: String,
    events: Vec<Value>,
    session_id: String,
    turn_id: String,
    effective: EffectiveSettings,
}

struct TurnState<'a> {
    config: &'a DriverConfig,
    expected_session_id: Option<String>,
    observed_session_id: Option<String>,
    events: Vec<Value>,
    interaction_failure: bool,
    effective: EffectiveSettings,
}

impl<'a> TurnState<'a> {
    fn new(
        config: &'a DriverConfig,
        identity: &LaunchIdentity,
        known_session: Option<String>,
    ) -> Self {
        Self {
            config,
            expected_session_id: known_session,
            observed_session_id: None,
            events: Vec::new(),
            interaction_failure: false,
            effective: identity.effective(),
        }
    }

    fn handle(&mut self, message: Value) -> Result<Option<TurnOutcome>, ProtocolFailure> {
        if let Some(session_id) = message
            .get("session_id")
            .or_else(|| message.get("sessionId"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        {
            self.record_session(session_id)?;
        }
        if message.get("type").and_then(Value::as_str) == Some("control_request") {
            self.interaction_failure = true;
        }
        if message.get("type").and_then(Value::as_str) == Some("system")
            && message.get("subtype").and_then(Value::as_str) == Some("permission_denied")
        {
            self.interaction_failure = true;
        }
        if message.get("type").and_then(Value::as_str) == Some("system")
            && message.get("subtype").and_then(Value::as_str) == Some("init")
        {
            self.effective.cwd = message
                .get("cwd")
                .and_then(Value::as_str)
                .map(str::to_string)
                .or(self.effective.cwd.take());
            self.effective.model = message
                .get("model")
                .and_then(Value::as_str)
                .map(str::to_string)
                .or(self.effective.model.take());
            self.effective.permission_mode = message
                .get("permissionMode")
                .or_else(|| message.get("permission_mode"))
                .and_then(Value::as_str)
                .map(str::to_string)
                .or(self.effective.permission_mode.take());
            self.effective.approval_policy =
                self.effective.permission_mode.clone().map(Value::String);
        }
        if let Some(text) = partial_text_delta(&message) {
            super::turn_event_emit::emit_agent_message_chunk(
                self.observed_session_id
                    .as_deref()
                    .or(self.expected_session_id.as_deref())
                    .unwrap_or_default(),
                &self.config.turn_id,
                text,
            );
        }
        if let Some(projected) = project_event(&message) {
            self.events.push(projected);
        }
        if message.get("type").and_then(Value::as_str) != Some("result") {
            return Ok(None);
        }
        self.finish(message).map(Some)
    }

    fn record_session(&mut self, value: &str) -> Result<(), ProtocolFailure> {
        if self
            .expected_session_id
            .as_deref()
            .is_some_and(|expected| expected != value)
            || self
                .observed_session_id
                .as_deref()
                .is_some_and(|observed| observed != value)
        {
            return Err(self.failure(
                "claude_code_session_mismatch",
                "Claude Code returned a different conversation than requested.",
                "session/resume",
            ));
        }
        self.observed_session_id = Some(value.to_string());
        Ok(())
    }

    fn finish(&self, terminal: Value) -> Result<TurnOutcome, ProtocolFailure> {
        let session_id = self
            .observed_session_id
            .clone()
            .or_else(|| self.expected_session_id.clone())
            .ok_or_else(|| {
                self.failure(
                    "claude_code_session_id_missing",
                    "Claude Code did not return the native conversation identifier.",
                    "session/open",
                )
            })?;
        let denied = terminal
            .get("permission_denials")
            .and_then(Value::as_array)
            .is_some_and(|values| !values.is_empty());
        let deferred = terminal.get("deferred_tool_use").is_some()
            || terminal
                .get("terminal_reason")
                .or_else(|| terminal.get("stop_reason"))
                .and_then(Value::as_str)
                == Some("tool_deferred");
        if self.interaction_failure || denied || deferred {
            let mut failure = self.failure(
                "claude_code_user_interaction_required",
                "Claude Code requires user interaction before this turn can continue.",
                "permission/request",
            );
            failure.user_interaction_required = true;
            failure.request_method = Some("can_use_tool".to_string());
            failure.turn_status = Some("userInteractionRequired".to_string());
            return Err(failure.with_session(Some(&session_id)));
        }
        let subtype = terminal
            .get("subtype")
            .and_then(Value::as_str)
            .unwrap_or("failed");
        let is_error = terminal
            .get("is_error")
            .and_then(Value::as_bool)
            .unwrap_or(subtype != "success");
        if is_error || subtype != "success" {
            let mut failure = self.failure(
                "claude_code_turn_failed",
                "Claude Code reported that the requested turn failed.",
                "turn/completed",
            );
            failure.turn_status = Some(subtype.to_string());
            return Err(failure.with_session(Some(&session_id)));
        }
        let output = terminal
            .get("result")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                self.failure(
                    "claude_code_final_message_missing",
                    "Claude Code completed without a final assistant message.",
                    "turn/completed",
                )
                .with_session(Some(&session_id))
            })?;
        super::turn_event_emit::emit_agent_message_completed(
            &session_id,
            &self.config.turn_id,
            output,
        );
        Ok(TurnOutcome {
            output: output.to_string(),
            events: self.events.clone(),
            session_id,
            turn_id: self.config.turn_id.clone(),
            effective: self.effective.clone(),
        })
    }

    fn failure(
        &self,
        code: &'static str,
        message: &'static str,
        stage: &'static str,
    ) -> ProtocolFailure {
        ProtocolFailure::new(code, message, stage)
            .with_session(
                self.observed_session_id
                    .as_deref()
                    .or(self.expected_session_id.as_deref()),
            )
            .with_turn(&self.config.turn_id)
    }
}

pub(super) fn probe(executable: &str, timeout_ms: u64, max_output: usize) -> CapabilityProbe {
    let version = run_probe_command(executable, "--version", timeout_ms, max_output);
    let help = run_probe_command(executable, "--help", timeout_ms, max_output);
    if version.is_none() && help.is_none() {
        CapabilityProbe::default()
    } else {
        CapabilityProbe::official(version == Some(true), help == Some(true))
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
    let config = match DriverConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => return RunResult::failed(failure, started_at, false, false),
    };
    let managed = if config.requested_session_id.is_empty() {
        match spawn_transport(executable, &config, cwd, max_stderr) {
            Ok(managed) => managed,
            Err(failure) => return RunResult::failed(failure, started_at, false, false),
        }
    } else {
        let Some(managed) = lookup_session_transport(&config.requested_session_id) else {
            return RunResult::failed(
                ProtocolFailure::new(
                    "claude_code_live_session_unavailable",
                    "The exact Claude Code streaming process is no longer available in this client process.",
                    "session/resume",
                )
                .with_session(Some(&config.requested_session_id))
                .with_turn(&config.turn_id),
                started_at,
                false,
                false,
            );
        };
        if !managed.identity.compatible_with(executable, &config, cwd) {
            return RunResult::failed(
                ProtocolFailure::new(
                    "claude_code_session_configuration_mismatch",
                    "The requested controls do not match the live Claude Code streaming process.",
                    "session/resume",
                )
                .with_session(Some(&config.requested_session_id))
                .with_turn(&config.turn_id),
                started_at,
                false,
                false,
            );
        }
        managed
    };
    let mut transport = match managed.transport.lock() {
        Ok(transport) => transport,
        Err(_) => {
            remove_transport(&managed, false);
            return RunResult::failed(supervisor_failure(), started_at, false, false);
        }
    };
    let known_session = managed
        .native_session_id
        .lock()
        .ok()
        .and_then(|value| value.clone());
    if !config.requested_session_id.is_empty()
        && known_session.as_deref() != Some(config.requested_session_id.as_str())
    {
        drop(transport);
        remove_transport(&managed, true);
        return RunResult::failed(
            ProtocolFailure::new(
                "claude_code_session_mismatch",
                "The live Claude Code process is not bound to the requested conversation.",
                "session/resume",
            )
            .with_session(Some(&config.requested_session_id))
            .with_turn(&config.turn_id),
            started_at,
            false,
            false,
        );
    }
    set_active_session(&managed, Some(known_session.clone().unwrap_or_default()));
    let message = match config.stdin_message() {
        Ok(message) => message,
        Err(_) => {
            set_active_session(&managed, None);
            return RunResult::failed(
                ProtocolFailure::new(
                    "claude_code_input_encode_failed",
                    "Claude Code input could not be encoded.",
                    "request/encode",
                )
                .with_turn(&config.turn_id),
                started_at,
                false,
                false,
            );
        }
    };
    let initial_write = write_message(&mut transport.stdin, &message);
    let (outcome, failure, stdout_truncated) = if initial_write.is_err() {
        (
            None,
            Some(
                ProtocolFailure::new(
                    "claude_code_write_failed",
                    "Claude Code stopped accepting streamed user messages.",
                    "protocol/write",
                )
                .with_session(known_session.as_deref())
                .with_turn(&config.turn_id),
            ),
            false,
        )
    } else {
        run_turn_loop(
            &mut transport,
            &managed,
            &config,
            known_session,
            Instant::now() + Duration::from_millis(timeout_ms),
            max_stdout,
        )
    };
    let stderr_truncated = transport.stderr_truncated.load(Ordering::Relaxed);
    set_active_session(&managed, None);
    drop(transport);
    if let Some(outcome) = outcome {
        bind_session(&managed, &outcome.session_id);
        return RunResult {
            ok: true,
            output: outcome.output,
            events: outcome.events,
            error: None,
            thread_id: outcome.session_id.clone(),
            session_id: outcome.session_id,
            turn_id: outcome.turn_id,
            turn_status: "completed".to_string(),
            effective: outcome.effective,
            status_code: None,
            stdout_truncated,
            stderr_truncated,
            started_at,
        };
    }
    let failure = failure.unwrap_or_else(|| {
        ProtocolFailure::new(
            "claude_code_turn_failed",
            "Claude Code did not complete the requested turn.",
            "turn/completed",
        )
        .with_turn(&config.turn_id)
    });
    if failure_requires_transport_reset(&failure) {
        remove_transport(&managed, true);
    }
    RunResult::failed(failure, started_at, stdout_truncated, stderr_truncated)
}

fn run_turn_loop(
    transport: &mut PersistentTransport,
    managed: &Arc<ManagedTransport>,
    config: &DriverConfig,
    known_session: Option<String>,
    deadline: Instant,
    max_stdout: usize,
) -> (Option<TurnOutcome>, Option<ProtocolFailure>, bool) {
    let mut state = TurnState::new(config, &managed.identity, known_session);
    let mut observed_bytes = 0usize;
    loop {
        if let Some(failure) = handle_control_requests(transport, &state) {
            return (None, Some(failure), false);
        }
        if transport.stdin.check_health().is_err() {
            return (
                None,
                Some(state.failure(
                    "claude_code_write_failed",
                    "Claude Code stopped accepting streamed messages.",
                    "protocol/write",
                )),
                false,
            );
        }
        let now = Instant::now();
        if now >= deadline {
            let mut failure = state.failure(
                "claude_code_timeout",
                "Claude Code timed out before the turn completed.",
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
                        Some(state.failure(
                            "claude_code_output_limit",
                            "Claude Code exceeded the configured structured output limit.",
                            "protocol/read",
                        )),
                        true,
                    );
                }
                if message.get("type").and_then(Value::as_str) == Some("control_request") {
                    state.interaction_failure = true;
                    if deny_control_request(&mut transport.stdin, &message).is_err() {
                        return (
                            None,
                            Some(state.failure(
                                "claude_code_write_failed",
                                "Claude Code stopped accepting control responses.",
                                "permission/response",
                            )),
                            false,
                        );
                    }
                }
                match state.handle(message) {
                    Ok(Some(outcome)) => return (Some(outcome), None, false),
                    Ok(None) => {
                        if let Some(session_id) = state.observed_session_id.as_deref() {
                            bind_session(managed, session_id);
                            set_active_session(managed, Some(session_id.to_string()));
                        }
                    }
                    Err(failure) => return (None, Some(failure), false),
                }
            }
            Ok(TransportEvent::InvalidJson) => {
                return (
                    None,
                    Some(state.failure(
                        "claude_code_invalid_json",
                        "Claude Code returned an invalid stream event.",
                        "protocol/read",
                    )),
                    false,
                );
            }
            Ok(TransportEvent::LineLimitExceeded) => {
                return (
                    None,
                    Some(state.failure(
                        "claude_code_output_limit",
                        "Claude Code exceeded the hard structured-event limit.",
                        "protocol/read",
                    )),
                    true,
                );
            }
            Ok(TransportEvent::StdoutReadFailed) => {
                return (
                    None,
                    Some(state.failure(
                        "claude_code_read_failed",
                        "Claude Code structured output could not be read.",
                        "protocol/read",
                    )),
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(state.failure(
                        "claude_code_exited",
                        "Claude Code exited before the turn completed.",
                        "process/exit",
                    )),
                    false,
                );
            }
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

fn spawn_transport(
    executable: &str,
    config: &DriverConfig,
    cwd: Option<&Path>,
    max_stderr: usize,
) -> Result<Arc<ManagedTransport>, ProtocolFailure> {
    let mut pool = transport_pool().lock().map_err(|_| supervisor_failure())?;
    pool.retain(|_, transport| Arc::strong_count(transport) > 0);
    if pool.len() >= MAX_POOLED_TRANSPORTS {
        return Err(ProtocolFailure::new(
            "claude_code_transport_capacity",
            "Claude Code reached the bounded persistent transport capacity.",
            "process/supervisor",
        ));
    }
    let identity = LaunchIdentity::new(executable, config, cwd);
    let (control_sender, control_receiver) = mpsc::sync_channel(CONTROL_QUEUE_CAPACITY);
    let transport = PersistentTransport::spawn(&identity, control_receiver, max_stderr)?;
    let id = NEXT_TRANSPORT_ID.fetch_add(1, Ordering::Relaxed);
    let managed = Arc::new(ManagedTransport {
        id,
        identity,
        transport: Mutex::new(transport),
        control_sender,
        native_session_id: Mutex::new(None),
        active_session: Mutex::new(None),
    });
    pool.insert(id, Arc::clone(&managed));
    Ok(managed)
}

fn bind_session(managed: &Arc<ManagedTransport>, session_id: &str) {
    if session_id.is_empty() {
        return;
    }
    if let Ok(mut native) = managed.native_session_id.lock() {
        if native
            .as_deref()
            .is_some_and(|existing| existing != session_id)
        {
            return;
        }
        *native = Some(session_id.to_string());
    }
    if let Ok(mut sessions) = session_transports().lock() {
        sessions.retain(|_, transport| transport.strong_count() > 0);
        if sessions.len() >= MAX_TRACKED_SESSIONS
            && !sessions.contains_key(session_id)
            && let Some(key) = sessions.keys().next().cloned()
        {
            sessions.remove(&key);
        }
        sessions.insert(session_id.to_string(), Arc::downgrade(managed));
    }
}

fn transport_pool() -> &'static Mutex<HashMap<u64, Arc<ManagedTransport>>> {
    TRANSPORT_POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn session_transports() -> &'static Mutex<HashMap<String, Weak<ManagedTransport>>> {
    SESSION_TRANSPORTS.get_or_init(|| Mutex::new(HashMap::new()))
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

pub(super) fn has_live_session(session_id: &str) -> bool {
    lookup_session_transport(session_id).is_some()
}

fn remove_transport(managed: &Arc<ManagedTransport>, cleanup: bool) {
    if let Ok(mut pool) = transport_pool().lock() {
        pool.remove(&managed.id);
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

fn set_active_session(managed: &ManagedTransport, session_id: Option<String>) {
    if let Ok(mut active) = managed.active_session.lock() {
        *active = session_id;
    }
}

fn supervisor_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "claude_code_supervisor_unavailable",
        "Claude Code supervisor state is unavailable.",
        "process/supervisor",
    )
}

fn failure_requires_transport_reset(failure: &ProtocolFailure) -> bool {
    matches!(
        failure.code,
        "claude_code_write_failed"
            | "claude_code_timeout"
            | "claude_code_invalid_json"
            | "claude_code_output_limit"
            | "claude_code_read_failed"
            | "claude_code_exited"
            | "claude_code_cleanup_requested"
            | "claude_code_session_mismatch"
    )
}

fn handle_control_requests(
    transport: &mut PersistentTransport,
    state: &TurnState<'_>,
) -> Option<ProtocolFailure> {
    loop {
        match transport.control_receiver.try_recv() {
            Ok(ControlRequest::Cancel {
                session_id,
                acknowledged,
            }) => {
                let current = state
                    .observed_session_id
                    .as_deref()
                    .or(state.expected_session_id.as_deref());
                let matches = current == Some(session_id.as_str());
                let written = matches
                    && write_message(
                        &mut transport.stdin,
                        &json!({
                            "type": "control_request",
                            "request_id": Uuid::new_v4().to_string(),
                            "request": {"subtype": "interrupt"}
                        }),
                    )
                    .is_ok();
                let _ = acknowledged.send(written);
                if matches && !written {
                    return Some(state.failure(
                        "claude_code_write_failed",
                        "Claude Code stopped accepting an interrupt request.",
                        "turn/cancel",
                    ));
                }
            }
            Ok(ControlRequest::Cleanup { acknowledged }) => {
                let _ = write_message(
                    &mut transport.stdin,
                    &json!({
                        "type": "control_request",
                        "request_id": Uuid::new_v4().to_string(),
                        "request": {"subtype": "interrupt"}
                    }),
                );
                let _ = acknowledged.send(true);
                return Some(state.failure(
                    "claude_code_cleanup_requested",
                    "Claude Code transport cleanup was requested.",
                    "process/cleanup",
                ));
            }
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => {
                return Some(state.failure(
                    "claude_code_supervisor_unavailable",
                    "Claude Code supervisor control channel is unavailable.",
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
    let Some(managed) = lookup_session_transport(session_id) else {
        return ControlDisposition::SessionUnavailable;
    };
    let active = managed
        .active_session
        .lock()
        .ok()
        .and_then(|value| value.clone());
    if active.as_deref() != Some(session_id) {
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
    let Some(managed) = lookup_session_transport(session_id) else {
        return ControlDisposition::SessionUnavailable;
    };
    let active = managed
        .active_session
        .lock()
        .ok()
        .is_some_and(|value| value.is_some());
    if active {
        let (acknowledged, receiver) = mpsc::sync_channel(1);
        if managed
            .control_sender
            .try_send(ControlRequest::Cleanup { acknowledged })
            .is_err()
            || receiver.recv_timeout(CONTROL_ACK_TIMEOUT) != Ok(true)
        {
            return ControlDisposition::TransportUnavailable;
        }
    }
    remove_transport(&managed, true);
    ControlDisposition::Accepted
}

fn deny_control_request(stdin: &mut BoundedStdinWriter, message: &Value) -> io::Result<()> {
    let Some(request_id) = message.get("request_id").and_then(Value::as_str) else {
        return Ok(());
    };
    write_message(
        stdin,
        &json!({
            "type": "control_response",
            "response": {
                "subtype": "error",
                "request_id": request_id,
                "error": "Client interaction is unavailable."
            }
        }),
    )
}

fn partial_text_delta(message: &Value) -> Option<&str> {
    (message.get("type").and_then(Value::as_str) == Some("stream_event"))
        .then(|| message.pointer("/event/delta/text").and_then(Value::as_str))
        .flatten()
}

fn project_event(message: &Value) -> Option<Value> {
    match message.get("type").and_then(Value::as_str)? {
        "stream_event" => partial_text_delta(message).map(|text| {
            json!({
                "type": "stream_event",
                "event": {
                    "type": "content_block_delta",
                    "delta": {"type": "text_delta", "text": text}
                }
            })
        }),
        "assistant" => Some(json!({"type": "assistant", "contentAvailable": true})),
        "result" => Some(json!({
            "type": "result",
            "subtype": message.get("subtype").and_then(Value::as_str).unwrap_or("unknown"),
            "isError": message.get("is_error").and_then(Value::as_bool).unwrap_or(false)
        })),
        "system" => Some(json!({
            "type": "system",
            "subtype": message.get("subtype").and_then(Value::as_str).unwrap_or("unknown")
        })),
        "control_request" => Some(json!({
            "type": "control_request",
            "subtype": message.pointer("/request/subtype").and_then(Value::as_str).unwrap_or("unknown")
        })),
        _ => None,
    }
}

fn write_message(stdin: &mut BoundedStdinWriter, message: &Value) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(message).map_err(io::Error::other)?;
    bytes.push(b'\n');
    stdin
        .enqueue(bytes)
        .map_err(|_| io::Error::other("Claude Code protocol write failed"))
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
            .map_or(available.len(), |index| index + 1);
        if line.len().saturating_add(consumed) > MAX_PROTOCOL_LINE_BYTES {
            let _ = sender.send(TransportEvent::LineLimitExceeded);
            return;
        }
        line.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        if line.last() == Some(&b'\n') {
            if send_protocol_line(&line, &sender).is_err() {
                return;
            }
            line.clear();
        }
    }
}

fn send_protocol_line(line: &[u8], sender: &Sender<TransportEvent>) -> Result<(), ()> {
    let trimmed = line
        .iter()
        .copied()
        .skip_while(|byte| byte.is_ascii_whitespace())
        .collect::<Vec<_>>();
    if trimmed.iter().all(|byte| byte.is_ascii_whitespace()) {
        return Ok(());
    }
    let message = serde_json::from_slice(&trimmed).map_err(|_| {
        let _ = sender.send(TransportEvent::InvalidJson);
    })?;
    sender
        .send(TransportEvent::Message {
            message,
            bytes: line.len(),
        })
        .map_err(|_| ())
}

fn drain_stderr(mut stderr: impl Read, max_bytes: usize, truncated: &AtomicBool) {
    let mut retained = 0usize;
    let mut buffer = [0u8; 8192];
    loop {
        match stderr.read(&mut buffer) {
            Ok(0) => return,
            Ok(read) => {
                let keep = max_bytes.saturating_sub(retained).min(read);
                retained = retained.saturating_add(keep);
                if keep < read {
                    truncated.store(true, Ordering::Relaxed);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        }
    }
}

fn run_probe_command(
    executable: &str,
    argument: &str,
    timeout_ms: u64,
    max_output: usize,
) -> Option<bool> {
    let mut command = Command::new(executable);
    command
        .arg(argument)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = SupervisedChild::spawn(&mut command).ok()?;
    let stdout = child.stdout()?;
    let stderr = child.stderr()?;
    let stdout_handle = thread::spawn(move || read_bounded(stdout, max_output));
    let stderr_handle = thread::spawn(move || read_bounded(stderr, max_output));
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    while !stdout_handle.is_finished() && Instant::now() < deadline {
        thread::sleep(PROCESS_POLL_INTERVAL);
    }
    let timed_out = !stdout_handle.is_finished();
    let status = child.terminate_tree().ok().flatten();
    let stdout = stdout_handle.join().ok()?;
    let stderr = stderr_handle.join().ok()?;
    Some(!timed_out && status.is_some_and(|value| value.success()) && !stdout && !stderr)
}

fn read_bounded(mut reader: impl Read, max_bytes: usize) -> bool {
    let mut observed = 0usize;
    let mut truncated = false;
    let mut buffer = [0u8; 8192];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return truncated,
            Ok(read) => {
                observed = observed.saturating_add(read);
                truncated |= observed > max_bytes;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return true,
        }
    }
}

fn pipe_failure(_stream: &'static str) -> ProtocolFailure {
    ProtocolFailure::new(
        "claude_code_pipe_failed",
        "Claude Code standard I/O is unavailable.",
        "process/start",
    )
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
    use std::fs as test_fs;
    use std::process::Command as TestCommand;

    fn config(params: Value, prompt: &str, session_id: &str) -> DriverConfig {
        DriverConfig::from_params(
            &params,
            prompt,
            session_id,
            Some(Path::new("/workspace/project")),
        )
        .unwrap()
    }

    #[test]
    fn fixed_launch_arguments_exclude_prompt_and_session() {
        let prompt = "private prompt must stay out of argv";
        let session = "private session must stay out of argv";
        let config = config(
            json!({
                "model": "claude-test-model",
                "reasoningEffort": "xhigh",
                "permissionMode": "plan"
            }),
            prompt,
            session,
        );
        let identity = LaunchIdentity::new(
            "claude-test",
            &config,
            Some(Path::new("/workspace/project")),
        );
        let args = identity.args();
        assert!(args.contains(&"--include-partial-messages".to_string()));
        assert!(args.contains(&"--no-session-persistence".to_string()));
        assert!(
            args.iter()
                .all(|argument| !argument.contains(prompt) && !argument.contains(session))
        );
        let input = config.stdin_message().unwrap();
        assert_eq!(
            input
                .pointer("/message/content/0/text")
                .and_then(Value::as_str),
            Some(prompt)
        );
        assert!(!input.to_string().contains(session));
    }

    #[test]
    fn invalid_native_settings_fail_closed_before_spawn() {
        assert_eq!(
            DriverConfig::from_params(
                &json!({"reasoningEffort": "unsupported"}),
                "hello",
                "",
                None
            )
            .unwrap_err()
            .code,
            "claude_code_invalid_effort"
        );
        assert_eq!(
            DriverConfig::from_params(&json!({"permissionMode": "unsupported"}), "hello", "", None)
                .unwrap_err()
                .code,
            "claude_code_invalid_permission_mode"
        );
    }

    #[test]
    fn second_turn_uses_same_live_process_and_exact_native_session() {
        let fixture =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_claude_code.rs");
        let temp_dir = std::env::temp_dir().join(format!("lico-claude-stream-{}", timestamp()));
        test_fs::create_dir_all(&temp_dir).unwrap();
        let executable = temp_dir.join(format!("fake-claude{}", std::env::consts::EXE_SUFFIX));
        let compile =
            TestCommand::new(std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string()))
                .arg("--edition=2024")
                .arg(&fixture)
                .arg("-o")
                .arg(&executable)
                .status()
                .unwrap();
        assert!(compile.success());
        let params = json!({"model":"fake-model","reasoningEffort":"high","permissionMode":"plan"});
        let first = execute(
            &executable.to_string_lossy(),
            &params,
            "fake-claude-private-prompt-1",
            "",
            Some(&temp_dir),
            10_000,
            1024 * 1024,
            1024,
        );
        assert!(first.ok, "first turn failed: {:?}", first.error);
        assert_eq!(first.output, "fake Claude final answer 1");
        assert_eq!(first.session_id, "fake-claude-session");
        assert!(
            first
                .events
                .iter()
                .any(|event| event.get("type").and_then(Value::as_str) == Some("stream_event"))
        );
        let opened = super::super::conversation_lane::open_or_resume(&json!({
            "agent": "claude-code",
            "sessionId": first.session_id
        }))
        .unwrap();
        assert_eq!(opened["ok"], true);
        assert_eq!(opened["openMode"], "resume");
        let second = execute(
            &executable.to_string_lossy(),
            &json!({}),
            "fake-claude-private-prompt-2",
            &first.session_id,
            Some(&temp_dir),
            10_000,
            1024 * 1024,
            1024,
        );
        assert!(second.ok, "second turn failed: {:?}", second.error);
        assert_eq!(second.output, "fake Claude final answer 2");
        assert_eq!(second.session_id, first.session_id);
        assert_eq!(
            cleanup_session(&second.session_id),
            ControlDisposition::Accepted
        );
        let after_cleanup = execute(
            &executable.to_string_lossy(),
            &json!({}),
            "third",
            &second.session_id,
            Some(&temp_dir),
            1_000,
            1024,
            1024,
        );
        assert_eq!(
            after_cleanup.error.unwrap().code,
            "claude_code_live_session_unavailable"
        );
        let _ = test_fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn unknown_process_local_session_fails_before_spawn() {
        let result = execute(
            "must-not-launch",
            &json!({}),
            "hello",
            "unknown-session",
            None,
            1,
            1,
            1,
        );
        assert_eq!(
            result.error.unwrap().code,
            "claude_code_live_session_unavailable"
        );
    }

    #[test]
    fn active_turn_cancel_uses_streaming_control_request() {
        let fixture =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_claude_code.rs");
        let temp_dir = std::env::temp_dir().join(format!("lico-claude-cancel-{}", timestamp()));
        test_fs::create_dir_all(&temp_dir).unwrap();
        let executable = temp_dir.join(format!("fake-claude{}", std::env::consts::EXE_SUFFIX));
        let compile =
            TestCommand::new(std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string()))
                .arg("--edition=2024")
                .arg(&fixture)
                .arg("-o")
                .arg(&executable)
                .status()
                .unwrap();
        assert!(compile.success());
        let executable_text = executable.to_string_lossy().to_string();
        let working_dir = temp_dir.clone();
        let run = thread::spawn(move || {
            execute(
                &executable_text,
                &json!({
                    "model":"fake-model",
                    "reasoningEffort":"high",
                    "permissionMode":"plan"
                }),
                "fake-claude-cancel-prompt",
                "",
                Some(&working_dir),
                10_000,
                1024 * 1024,
                1024,
            )
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        let disposition = loop {
            let disposition = cancel("fake-claude-session");
            if disposition == ControlDisposition::Accepted || Instant::now() >= deadline {
                break disposition;
            }
            thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(disposition, ControlDisposition::Accepted);
        let result = run.join().unwrap();
        assert_eq!(result.error.unwrap().code, "claude_code_turn_failed");
        assert_eq!(
            cleanup_session("fake-claude-session"),
            ControlDisposition::Accepted
        );
        let _ = test_fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn output_and_protocol_lines_are_bounded() {
        let (sender, receiver) = mpsc::channel();
        read_protocol_messages(
            BufReader::new(std::io::Cursor::new(vec![
                b'x';
                MAX_PROTOCOL_LINE_BYTES + 1
            ])),
            sender,
        );
        assert!(matches!(
            receiver.recv().unwrap(),
            TransportEvent::LineLimitExceeded
        ));
        assert!(read_bounded(std::io::Cursor::new(vec![b'x'; 2048]), 1024));
    }
}
