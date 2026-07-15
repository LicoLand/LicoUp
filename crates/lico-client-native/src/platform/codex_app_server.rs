use super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
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

pub(super) const RUNTIME_PROTOCOL: &str = "codex-app-server-stdio-jsonrpc";

const INITIALIZE_REQUEST_ID: i64 = 1;
const THREAD_REQUEST_ID: i64 = 2;
const TURN_REQUEST_ID: i64 = 3;
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Clone, Debug)]
struct ProtocolConfig {
    prompt: String,
    requested_session_id: String,
    session_path: Option<String>,
    cwd: Option<String>,
    model: Option<String>,
    reasoning_effort: Option<String>,
    sandbox: Option<Value>,
    approval_policy: Option<Value>,
}

impl ProtocolConfig {
    fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        let session_path = text_param(params, &["sessionPath", "sourcePath"]);
        let requested_session_id = if session_id.trim().is_empty() && session_path.is_some() {
            thread_id_from_session_path(session_path.as_deref().unwrap_or_default())
                .unwrap_or_default()
        } else {
            session_id.trim().to_string()
        };
        if session_path.is_some() && requested_session_id.is_empty() {
            return Err(ProtocolFailure::new(
                "codex_invalid_resume_target",
                "Codex could not identify the existing conversation to resume.",
                "thread/resume",
            ));
        }

        let sandbox = params
            .get("sandbox")
            .or_else(|| params.get("sandboxMode"))
            .filter(|value| !value.is_null())
            .cloned();
        if let Some(value) = sandbox.as_ref() {
            let valid = value.as_str().is_some_and(|value| {
                matches!(
                    value,
                    "read-only" | "workspace-write" | "danger-full-access"
                )
            });
            if !valid {
                return Err(ProtocolFailure::new(
                    "codex_invalid_sandbox",
                    "The requested Codex sandbox mode is not supported.",
                    "thread/configure",
                ));
            }
        }

        let approval_policy = params
            .get("approvalPolicy")
            .or_else(|| params.get("approval_policy"))
            .filter(|value| !value.is_null())
            .cloned();

        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id,
            session_path,
            cwd: cwd.map(|path| path.to_string_lossy().to_string()),
            model: text_param(params, &["model", "modelId"]),
            reasoning_effort: text_param(params, &["reasoningEffort", "reasoning_effort"]).or_else(
                || {
                    spark_default_reasoning_effort(
                        text_param(params, &["model", "modelId"]).as_deref(),
                    )
                },
            ),
            sandbox,
            approval_policy,
        })
    }

    fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty() || self.session_path.is_some()
    }
}

fn spark_default_reasoning_effort(model: Option<&str>) -> Option<String> {
    let model = model?.to_ascii_lowercase();
    if model.contains("spark") {
        // Codex rejects Spark turns when reasoning.effort is omitted/invalid.
        Some("low".to_string())
    } else {
        None
    }
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

    fn user_interaction(
        method: &str,
        session_id: Option<&str>,
        thread_id: Option<&str>,
        turn_id: Option<&str>,
    ) -> Self {
        Self {
            code: "codex_user_interaction_required",
            message: "Codex requires user interaction before this turn can continue.",
            stage: "server/request",
            user_interaction_required: true,
            request_method: Some(method.to_string()),
            session_id: session_id.map(str::to_string),
            thread_id: thread_id.map(str::to_string),
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
        Self {
            ok: false,
            output: String::new(),
            events: Vec::new(),
            session_id: failure.session_id.clone().unwrap_or_default(),
            thread_id: failure.thread_id.clone().unwrap_or_default(),
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            error: Some(failure),
            status_code,
            stdout_truncated,
            stderr_truncated,
            started_at,
        }
    }
}

#[derive(Clone, Debug)]
struct ProtocolOutcome {
    output: String,
    events: Vec<Value>,
    session_id: String,
    thread_id: String,
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
    AwaitThread,
    AwaitTurnStart,
    AwaitTurnCompleted,
    Finished,
}

#[derive(Debug)]
struct CodexProtocol {
    config: ProtocolConfig,
    phase: ProtocolPhase,
    session_id: Option<String>,
    thread_id: Option<String>,
    turn_id: Option<String>,
    effective: EffectiveSettings,
    completed_items: Vec<Value>,
}

impl CodexProtocol {
    fn new(config: ProtocolConfig) -> Self {
        Self {
            config,
            phase: ProtocolPhase::AwaitInitialize,
            session_id: None,
            thread_id: None,
            turn_id: None,
            effective: EffectiveSettings::default(),
            completed_items: Vec::new(),
        }
    }

    fn initial_request(&self) -> Value {
        json!({
            "id": INITIALIZE_REQUEST_ID,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "lico-arc",
                    "title": "Lico Arc",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": self.config.session_path.is_some()
                }
            }
        })
    }

    fn handle_message(&mut self, message: Value) -> Vec<ProtocolEffect> {
        if let Some(effect) = self.reject_server_request(&message) {
            self.phase = ProtocolPhase::Finished;
            return effect;
        }

        if message.get("method").is_some() {
            return self.handle_notification(&message);
        }

        match self.phase {
            ProtocolPhase::AwaitInitialize
                if request_id_matches(&message, INITIALIZE_REQUEST_ID) =>
            {
                self.handle_initialize_response(&message)
            }
            ProtocolPhase::AwaitThread if request_id_matches(&message, THREAD_REQUEST_ID) => {
                self.handle_thread_response(&message)
            }
            ProtocolPhase::AwaitTurnStart if request_id_matches(&message, TURN_REQUEST_ID) => {
                self.handle_turn_start_response(&message)
            }
            _ => Vec::new(),
        }
    }

    fn reject_server_request(&self, message: &Value) -> Option<Vec<ProtocolEffect>> {
        let request_id = message.get("id")?;
        let method = message.get("method")?.as_str()?;
        if message.get("result").is_some() || message.get("error").is_some() {
            return None;
        }
        let response = json!({
            "id": request_id,
            "error": {
                "code": -32001,
                "message": "User interaction is required and was not approved by this client."
            }
        });
        let failure = ProtocolFailure::user_interaction(
            method,
            self.session_id.as_deref(),
            self.thread_id.as_deref(),
            self.turn_id.as_deref(),
        );
        Some(vec![
            ProtocolEffect::Send(response),
            ProtocolEffect::Fail(failure),
        ])
    }

    fn handle_initialize_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "codex_initialize_failed",
                "Codex app-server initialization failed.",
                "initialize",
            ))];
        }
        if message.get("result").is_none() {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "codex_protocol_error",
                "Codex app-server returned an invalid initialization response.",
                "initialize",
            ))];
        }

        self.phase = ProtocolPhase::AwaitThread;
        vec![
            ProtocolEffect::Send(json!({"method": "initialized"})),
            ProtocolEffect::Send(self.thread_request()),
        ]
    }

    fn thread_request(&self) -> Value {
        let mut params = Map::new();
        if let Some(cwd) = self.config.cwd.as_ref() {
            params.insert("cwd".to_string(), json!(cwd));
        }
        if let Some(sandbox) = self.config.sandbox.as_ref() {
            params.insert("sandbox".to_string(), sandbox.clone());
        }
        if let Some(approval_policy) = self.config.approval_policy.as_ref() {
            params.insert("approvalPolicy".to_string(), approval_policy.clone());
        }

        let method = if self.config.is_resume() {
            params.insert(
                "threadId".to_string(),
                json!(self.config.requested_session_id),
            );
            if let Some(path) = self.config.session_path.as_ref() {
                params.insert("path".to_string(), json!(path));
            }
            "thread/resume"
        } else {
            "thread/start"
        };
        json!({
            "id": THREAD_REQUEST_ID,
            "method": method,
            "params": params
        })
    }

    fn handle_thread_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "codex_thread_open_failed",
                "Codex could not open the requested conversation.",
                if self.config.is_resume() {
                    "thread/resume"
                } else {
                    "thread/start"
                },
            ))];
        }
        let Some(result) = message.get("result") else {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "codex_protocol_error",
                "Codex app-server returned an invalid thread response.",
                "thread/open",
            ))];
        };
        let Some(thread) = result.get("thread") else {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "codex_protocol_error",
                "Codex app-server did not return a conversation identifier.",
                "thread/open",
            ))];
        };
        let Some(thread_id) = thread
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        else {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "codex_protocol_error",
                "Codex app-server did not return a conversation identifier.",
                "thread/open",
            ))];
        };

        self.thread_id = Some(thread_id.to_string());
        // `thread/resume` accepts the app-server thread id.  A distinct
        // transcript/session field is not a valid continuation handle and
        // must never be promoted to the product native-session binding.
        self.session_id = Some(thread_id.to_string());
        self.effective = EffectiveSettings {
            cwd: result
                .get("cwd")
                .or_else(|| thread.get("cwd"))
                .and_then(Value::as_str)
                .map(str::to_string),
            // The official app-server Turn schema does not expose the
            // resolved runtime default model or effort. Preserve only values
            // explicitly bound by this client; optional thread response
            // extensions are not a stable effective-settings authority.
            model: self.config.model.clone(),
            reasoning_effort: self.config.reasoning_effort.clone(),
            sandbox: result.get("sandbox").cloned(),
            approval_policy: result.get("approvalPolicy").cloned(),
        };

        self.phase = ProtocolPhase::AwaitTurnStart;
        vec![ProtocolEffect::Send(self.turn_start_request(thread_id))]
    }

    fn turn_start_request(&self, thread_id: &str) -> Value {
        let mut params = Map::new();
        params.insert("threadId".to_string(), json!(thread_id));
        params.insert(
            "input".to_string(),
            json!([{
                "type": "text",
                "text": self.config.prompt
            }]),
        );
        if let Some(model) = self.config.model.as_ref() {
            params.insert("model".to_string(), json!(model));
        }
        let effort = self
            .config
            .reasoning_effort
            .as_ref()
            .or(self.effective.reasoning_effort.as_ref())
            .cloned()
            .or_else(|| spark_default_reasoning_effort(self.config.model.as_deref()));
        if let Some(effort) = effort {
            params.insert("effort".to_string(), json!(effort));
        }
        json!({
            "id": TURN_REQUEST_ID,
            "method": "turn/start",
            "params": params
        })
    }

    fn handle_turn_start_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            let mut failure = ProtocolFailure::new(
                "codex_turn_start_failed",
                "Codex could not start the requested turn.",
                "turn/start",
            );
            failure.thread_id = self.thread_id.clone();
            failure.session_id = self.session_id.clone();
            return vec![ProtocolEffect::Fail(failure)];
        }
        let Some(turn_id) = message
            .get("result")
            .and_then(|result| result.get("turn"))
            .and_then(|turn| turn.get("id"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        else {
            self.phase = ProtocolPhase::Finished;
            let mut failure = ProtocolFailure::new(
                "codex_protocol_error",
                "Codex app-server did not return a turn identifier.",
                "turn/start",
            );
            failure.thread_id = self.thread_id.clone();
            failure.session_id = self.session_id.clone();
            return vec![ProtocolEffect::Fail(failure)];
        };

        self.turn_id = Some(turn_id.to_string());
        if let Some(model) = self.config.model.as_ref() {
            self.effective.model = Some(model.clone());
        }
        if let Some(effort) = self.config.reasoning_effort.as_ref() {
            self.effective.reasoning_effort = Some(effort.clone());
        }
        self.phase = ProtocolPhase::AwaitTurnCompleted;
        Vec::new()
    }

    fn handle_notification(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        match message.get("method").and_then(Value::as_str) {
            Some("item/completed") => {
                self.capture_completed_item(message);
                Vec::new()
            }
            Some("item/agentMessage/delta") | Some("item/agentMessage/updated") => {
                self.emit_agent_message_delta(message);
                Vec::new()
            }
            Some("turn/completed") => self.handle_turn_completed(message),
            _ => Vec::new(),
        }
    }

    fn capture_completed_item(&mut self, message: &Value) {
        if self.phase != ProtocolPhase::AwaitTurnCompleted {
            return;
        }
        let Some(params) = message.get("params") else {
            return;
        };
        if !matches_current_ids(params, self.thread_id.as_deref(), self.turn_id.as_deref()) {
            return;
        }
        if let Some(item) = params.get("item") {
            self.completed_items.push(item.clone());
            if item.get("type").and_then(Value::as_str) == Some("agentMessage")
                && let Some(text) = item.get("text").and_then(Value::as_str)
            {
                super::turn_event_emit::emit_agent_message_completed(
                    self.thread_id.as_deref().unwrap_or_default(),
                    self.turn_id.as_deref().unwrap_or_default(),
                    text,
                );
            }
        }
    }

    fn emit_agent_message_delta(&mut self, message: &Value) {
        if self.phase != ProtocolPhase::AwaitTurnCompleted {
            return;
        }
        let Some(params) = message.get("params") else {
            return;
        };
        if !matches_current_ids(params, self.thread_id.as_deref(), self.turn_id.as_deref()) {
            return;
        }
        let text = params
            .get("delta")
            .and_then(Value::as_str)
            .or_else(|| params.get("text").and_then(Value::as_str))
            .or_else(|| {
                params
                    .get("item")
                    .and_then(|item| item.get("text"))
                    .and_then(Value::as_str)
            })
            .unwrap_or_default();
        if !text.is_empty() {
            super::turn_event_emit::emit_agent_message_chunk(
                self.thread_id.as_deref().unwrap_or_default(),
                self.turn_id.as_deref().unwrap_or_default(),
                text,
            );
        }
    }

    fn handle_turn_completed(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if self.phase != ProtocolPhase::AwaitTurnCompleted {
            return Vec::new();
        }
        let Some(params) = message.get("params") else {
            return Vec::new();
        };
        let Some(turn) = params.get("turn") else {
            return Vec::new();
        };
        let thread_matches = params
            .get("threadId")
            .and_then(Value::as_str)
            .zip(self.thread_id.as_deref())
            .is_some_and(|(actual, expected)| actual == expected);
        let turn_matches = turn
            .get("id")
            .and_then(Value::as_str)
            .zip(self.turn_id.as_deref())
            .is_some_and(|(actual, expected)| actual == expected);
        if !thread_matches || !turn_matches {
            return Vec::new();
        }

        let status = turn
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("failed")
            .to_string();
        let final_message = turn
            .get("items")
            .and_then(Value::as_array)
            .and_then(|items| final_agent_message(items))
            .or_else(|| final_agent_message(&self.completed_items));

        self.phase = ProtocolPhase::Finished;
        if status != "completed" {
            let mut failure = ProtocolFailure::new(
                "codex_turn_not_completed",
                "Codex did not complete the requested turn.",
                "turn/completed",
            );
            failure.thread_id = self.thread_id.clone();
            failure.session_id = self.session_id.clone();
            failure.turn_id = self.turn_id.clone();
            failure.turn_status = Some(status);
            return vec![ProtocolEffect::Fail(failure)];
        }
        let Some(output) = final_message else {
            let mut failure = ProtocolFailure::new(
                "codex_final_message_missing",
                "Codex completed the turn without a final agent message.",
                "turn/completed",
            );
            failure.thread_id = self.thread_id.clone();
            failure.session_id = self.session_id.clone();
            failure.turn_id = self.turn_id.clone();
            failure.turn_status = Some(status);
            return vec![ProtocolEffect::Fail(failure)];
        };

        vec![ProtocolEffect::Complete(ProtocolOutcome {
            output,
            events: self
                .completed_items
                .iter()
                .filter(|item| item.get("type").and_then(Value::as_str) == Some("agentMessage"))
                .cloned()
                .collect(),
            session_id: self.session_id.clone().unwrap_or_default(),
            thread_id: self.thread_id.clone().unwrap_or_default(),
            turn_id: self.turn_id.clone().unwrap_or_default(),
            turn_status: status,
            effective: self.effective.clone(),
        })]
    }
}

#[derive(Debug)]
struct CodexLaunchSpec {
    executable: String,
    args: Vec<String>,
    cwd: Option<PathBuf>,
}

impl CodexLaunchSpec {
    /// Use the official stdio app-server. Thread continuity is carried by the
    /// app-server `thread.id`, so no parallel socket daemon is required.
    fn new(executable: &str, cwd: Option<&Path>) -> Self {
        Self {
            executable: executable.to_string(),
            args: vec!["app-server".to_string(), "--stdio".to_string()],
            cwd: cwd.map(Path::to_path_buf),
        }
    }

    fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(cwd) = self.cwd.as_ref() {
            command.current_dir(cwd);
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
        Err(failure) => {
            return RunResult::failed(failure, started_at, None, false, false);
        }
    };
    let launch = CodexLaunchSpec::new(executable, cwd);
    let mut child = match launch.spawn() {
        Ok(child) => child,
        Err(error) => {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The Codex executable is not available.",
                io::ErrorKind::PermissionDenied => "The Codex executable is not permitted to run.",
                _ => "Codex app-server could not be started.",
            };
            return RunResult::failed(
                ProtocolFailure::new("codex_app_server_start_failed", message, "process/start"),
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
            "Codex app-server stdout is unavailable.",
        );
    };
    let Some(stderr) = child.stderr() else {
        return pipe_failure(
            &mut child,
            started_at,
            "Codex app-server stderr is unavailable.",
        );
    };
    let Some(stdin) = child.stdin() else {
        return pipe_failure(
            &mut child,
            started_at,
            "Codex app-server stdin is unavailable.",
        );
    };
    let mut stdin = BoundedStdinWriter::new(stdin);

    let (sender, receiver) = mpsc::channel();
    let stdout_handle =
        thread::spawn(move || read_protocol_messages(BufReader::new(stdout), max_stdout, sender));
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));

    let mut protocol = CodexProtocol::new(config);
    if write_message(&mut stdin, &protocol.initial_request()).is_err() {
        let cleanup =
            finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
        let cleanup_failed = cleanup == Err(TransportFinishFailure::Lifecycle);
        return RunResult::failed(
            ProtocolFailure::new(
                if cleanup_failed {
                    "codex_app_server_cleanup_failed"
                } else {
                    "codex_app_server_write_failed"
                },
                if cleanup_failed {
                    "Codex app-server process cleanup could not be completed safely."
                } else {
                    "Codex app-server stopped accepting protocol messages."
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
                "codex_app_server_cleanup_failed",
                "Codex app-server process cleanup could not be completed safely.",
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
                "codex_app_server_write_failed",
                "Codex app-server stopped accepting protocol messages.",
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
            session_id: outcome.session_id,
            thread_id: outcome.thread_id,
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
                "codex_app_server_failed",
                "Codex app-server did not complete the request.",
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
    protocol: &mut CodexProtocol,
    deadline: Instant,
) -> (
    Option<ProtocolOutcome>,
    Option<ProtocolFailure>,
    Option<i32>,
    bool,
) {
    loop {
        if stdin.check_health().is_err() {
            let mut failure = ProtocolFailure::new(
                "codex_app_server_write_failed",
                "Codex app-server stopped accepting protocol messages.",
                "protocol/write",
            );
            failure.thread_id = protocol.thread_id.clone();
            failure.session_id = protocol.session_id.clone();
            failure.turn_id = protocol.turn_id.clone();
            return (None, Some(failure), None, false);
        }
        let now = Instant::now();
        if now >= deadline {
            let mut failure = ProtocolFailure::new(
                "codex_app_server_timeout",
                "Codex app-server timed out before the turn completed.",
                "turn/wait",
            );
            failure.thread_id = protocol.thread_id.clone();
            failure.session_id = protocol.session_id.clone();
            failure.turn_id = protocol.turn_id.clone();
            return (None, Some(failure), None, false);
        }
        let wait = (deadline - now).min(PROCESS_POLL_INTERVAL);
        match receiver.recv_timeout(wait) {
            Ok(TransportEvent::Message(message)) => {
                for effect in protocol.handle_message(message) {
                    match effect {
                        ProtocolEffect::Send(message) => {
                            if write_message(stdin, &message).is_err() {
                                let mut failure = ProtocolFailure::new(
                                    "codex_app_server_write_failed",
                                    "Codex app-server stopped accepting protocol messages.",
                                    "protocol/write",
                                );
                                failure.thread_id = protocol.thread_id.clone();
                                failure.session_id = protocol.session_id.clone();
                                failure.turn_id = protocol.turn_id.clone();
                                return (None, Some(failure), None, false);
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
                        "codex_app_server_invalid_json",
                        "Codex app-server returned an invalid protocol message.",
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
                        "codex_app_server_output_limit",
                        "Codex app-server exceeded the configured protocol output limit.",
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
                        "codex_app_server_read_failed",
                        "Codex app-server protocol output could not be read.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "codex_app_server_exited",
                        "Codex app-server exited before the turn completed.",
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

fn pipe_failure(
    child: &mut SupervisedChild,
    started_at: String,
    message: &'static str,
) -> RunResult {
    let failure = if child.terminate_tree().is_ok() {
        ProtocolFailure::new("codex_app_server_pipe_failed", message, "process/start")
    } else {
        ProtocolFailure::new(
            "codex_app_server_cleanup_failed",
            "Codex app-server process cleanup could not be completed safely.",
            "process/cleanup",
        )
    };
    RunResult::failed(failure, started_at, None, false, false)
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

fn matches_current_ids(params: &Value, thread_id: Option<&str>, turn_id: Option<&str>) -> bool {
    params.get("threadId").and_then(Value::as_str) == thread_id
        && params.get("turnId").and_then(Value::as_str) == turn_id
}

fn final_agent_message(items: &[Value]) -> Option<String> {
    items.iter().rev().find_map(|item| {
        (item.get("type").and_then(Value::as_str) == Some("agentMessage"))
            .then(|| item.get("text").and_then(Value::as_str).map(str::to_string))
            .flatten()
    })
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn thread_id_from_session_path(path: &str) -> Option<String> {
    let stem = Path::new(path).file_stem()?.to_str()?;
    stem.split(|character: char| !character.is_ascii_hexdigit() && character != '-')
        .flat_map(|part| part.as_bytes().windows(36))
        .filter_map(|window| std::str::from_utf8(window).ok())
        .find(|candidate| looks_like_uuid(candidate))
        .map(str::to_string)
}

fn looks_like_uuid(value: &str) -> bool {
    value.len() == 36
        && value
            .chars()
            .enumerate()
            .all(|(index, character)| match index {
                8 | 13 | 18 | 23 => character == '-',
                _ => character.is_ascii_hexdigit(),
            })
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
    use std::io::Cursor;
    use std::process::Command as TestCommand;

    fn config(params: Value, prompt: &str, session_id: &str) -> ProtocolConfig {
        ProtocolConfig::from_params(
            &params,
            prompt,
            session_id,
            Some(Path::new("/workspace/project")),
        )
        .unwrap()
    }

    fn initialize(protocol: &mut CodexProtocol) -> Vec<ProtocolEffect> {
        protocol.handle_message(json!({
            "id": INITIALIZE_REQUEST_ID,
            "result": {
                "userAgent": "codex-test",
                "platformFamily": "test",
                "platformOs": "test",
                "codexHome": "/redacted"
            }
        }))
    }

    fn open_thread(protocol: &mut CodexProtocol) -> Vec<ProtocolEffect> {
        protocol.handle_message(json!({
            "id": THREAD_REQUEST_ID,
            "result": {
                "thread": {
                    "id": "thread-1",
                    "sessionId": "session-1",
                    "cwd": "/workspace/project"
                },
                "cwd": "/workspace/project",
                "model": "default-model",
                "reasoningEffort": "medium",
                "sandbox": {"type": "workspaceWrite", "writableRoots": []},
                "approvalPolicy": "on-request"
            }
        }))
    }

    fn start_turn(protocol: &mut CodexProtocol) {
        let effects = protocol.handle_message(json!({
            "id": TURN_REQUEST_ID,
            "result": {
                "turn": {"id": "turn-1", "status": "inProgress", "items": []}
            }
        }));
        assert!(effects.is_empty());
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

    #[test]
    fn new_thread_protocol_sends_prompt_only_in_turn_start_stdin_message() {
        let prompt = "private prompt that must not enter argv";
        let mut protocol = CodexProtocol::new(config(
            json!({
                "model": "explicit-model",
                "reasoningEffort": "high"
            }),
            prompt,
            "",
        ));

        let initialize_request = protocol.initial_request();
        assert_eq!(initialize_request["method"], "initialize");
        assert!(!initialize_request.to_string().contains(prompt));

        let thread_messages = sent_messages(initialize(&mut protocol));
        assert_eq!(thread_messages[0], json!({"method": "initialized"}));
        assert_eq!(thread_messages[1]["method"], "thread/start");
        assert!(!thread_messages[1].to_string().contains(prompt));
        assert!(thread_messages[1]["params"].get("sandbox").is_none());

        let turn_messages = sent_messages(open_thread(&mut protocol));
        assert_eq!(turn_messages.len(), 1);
        assert_eq!(turn_messages[0]["method"], "turn/start");
        assert_eq!(turn_messages[0]["params"]["threadId"], "thread-1");
        assert_eq!(turn_messages[0]["params"]["input"][0]["type"], "text");
        assert_eq!(turn_messages[0]["params"]["input"][0]["text"], prompt);
        assert_eq!(turn_messages[0]["params"]["model"], "explicit-model");
        assert_eq!(turn_messages[0]["params"]["effort"], "high");
    }

    #[test]
    fn resume_protocol_accepts_session_path_and_source_path() {
        for key in ["sessionPath", "sourcePath"] {
            let mut params = Map::new();
            params.insert(
                key.to_string(),
                json!("/sessions/rollout-2026-01-01-01234567-89ab-cdef-0123-456789abcdef.jsonl"),
            );
            let mut protocol = CodexProtocol::new(config(Value::Object(params), "hello", ""));
            let thread_messages = sent_messages(initialize(&mut protocol));
            let resume = &thread_messages[1];
            assert_eq!(resume["method"], "thread/resume");
            assert_eq!(
                resume["params"]["threadId"],
                "01234567-89ab-cdef-0123-456789abcdef"
            );
            assert!(resume["params"]["path"].as_str().is_some());
        }
    }

    #[test]
    fn matching_turn_completed_uses_last_completed_agent_message_and_metadata() {
        let mut protocol = CodexProtocol::new(config(
            json!({"model": "explicit-model", "reasoningEffort": "high"}),
            "hello",
            "",
        ));
        initialize(&mut protocol);
        open_thread(&mut protocol);
        start_turn(&mut protocol);

        assert!(
            protocol
                .handle_message(json!({
                    "method": "turn/completed",
                    "params": {
                        "threadId": "another-thread",
                        "turn": {"id": "turn-1", "status": "completed", "items": []}
                    }
                }))
                .is_empty()
        );

        let effects = protocol.handle_message(json!({
            "method": "turn/completed",
            "params": {
                "threadId": "thread-1",
                "turn": {
                    "id": "turn-1",
                    "status": "completed",
                    "items": [
                        {"id": "agent-1", "type": "agentMessage", "text": "draft"},
                        {"id": "reasoning-1", "type": "reasoning", "summary": []},
                        {"id": "agent-2", "type": "agentMessage", "text": "final answer"}
                    ]
                }
            }
        }));
        let outcome = effects.into_iter().find_map(|effect| match effect {
            ProtocolEffect::Complete(outcome) => Some(outcome),
            ProtocolEffect::Send(_) | ProtocolEffect::Fail(_) => None,
        });
        let outcome = outcome.expect("matching completion should finish the protocol");
        assert_eq!(outcome.output, "final answer");
        assert_eq!(outcome.session_id, "thread-1");
        assert_eq!(outcome.thread_id, "thread-1");
        assert_eq!(outcome.turn_id, "turn-1");
        assert_eq!(outcome.turn_status, "completed");
        assert_eq!(outcome.effective.model.as_deref(), Some("explicit-model"));
        assert_eq!(outcome.effective.reasoning_effort.as_deref(), Some("high"));
        assert_eq!(outcome.effective.cwd.as_deref(), Some("/workspace/project"));
        assert_eq!(outcome.effective.approval_policy, Some(json!("on-request")));
    }

    #[test]
    fn server_request_is_declined_and_requires_user_interaction() {
        let mut protocol = CodexProtocol::new(config(json!({}), "hello", ""));
        initialize(&mut protocol);
        open_thread(&mut protocol);
        start_turn(&mut protocol);

        let effects = protocol.handle_message(json!({
            "id": "approval-1",
            "method": "item/commandExecution/requestApproval",
            "params": {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "command": "sensitive command"
            }
        }));
        assert_eq!(effects.len(), 2);
        match &effects[0] {
            ProtocolEffect::Send(response) => {
                assert_eq!(response["id"], "approval-1");
                assert_eq!(response["error"]["code"], -32001);
                assert!(response.get("result").is_none());
            }
            _ => panic!("server request must be explicitly declined"),
        }
        match &effects[1] {
            ProtocolEffect::Fail(failure) => {
                assert_eq!(failure.code, "codex_user_interaction_required");
                assert!(failure.user_interaction_required);
                assert_eq!(
                    failure.request_method.as_deref(),
                    Some("item/commandExecution/requestApproval")
                );
                assert_eq!(failure.thread_id.as_deref(), Some("thread-1"));
                assert_eq!(failure.turn_id.as_deref(), Some("turn-1"));
            }
            _ => panic!("server request must stop autonomous dispatch"),
        }
    }

    #[test]
    fn launch_spec_has_no_prompt_channel_and_uses_official_stdio() {
        let prompt = "must-not-appear-in-process-metadata";
        let launch = CodexLaunchSpec::new("codex-test", Some(Path::new("/workspace/project")));
        assert_eq!(launch.executable, "codex-test");
        assert_eq!(launch.args, ["app-server", "--stdio"]);
        assert!(!launch.executable.contains(prompt));
        assert!(
            launch
                .args
                .iter()
                .all(|argument| !argument.contains(prompt))
        );
    }

    #[test]
    fn stdout_reader_is_line_framed_and_enforces_total_limit() {
        let input = b"{\"id\":1,\"result\":{}}\n{\"method\":\"initialized\"}\n";
        let (sender, receiver) = mpsc::channel();
        read_protocol_messages(Cursor::new(input), input.len(), sender);
        assert!(matches!(
            receiver.recv().unwrap(),
            TransportEvent::Message(_)
        ));
        assert!(matches!(
            receiver.recv().unwrap(),
            TransportEvent::Message(_)
        ));
        assert!(matches!(
            receiver.recv().unwrap(),
            TransportEvent::StdoutClosed
        ));

        let (sender, receiver) = mpsc::channel();
        read_protocol_messages(Cursor::new(input), input.len() - 1, sender);
        assert!(matches!(
            receiver.recv().unwrap(),
            TransportEvent::Message(_)
        ));
        assert!(matches!(
            receiver.recv().unwrap(),
            TransportEvent::StdoutLimitExceeded
        ));
    }

    #[test]
    fn stderr_drain_never_retains_content_and_marks_truncation() {
        let truncated = AtomicBool::new(false);
        drain_stderr(Cursor::new(vec![b'x'; 64 * 1024]), 1024, &truncated);
        assert!(truncated.load(Ordering::Relaxed));
    }

    #[test]
    fn fake_child_transport_proves_spawn_stdin_concurrent_drain_and_completion() {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join("fake_codex_app_server.rs");
        let temp_dir = std::env::temp_dir().join(format!("lico-codex-fake-{}", timestamp()));
        test_fs::create_dir_all(&temp_dir).unwrap();
        let executable = temp_dir.join(format!("fake-codex{}", std::env::consts::EXE_SUFFIX));
        let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
        let compile = TestCommand::new(rustc)
            .arg("--edition=2024")
            .arg(&fixture)
            .arg("-o")
            .arg(&executable)
            .status()
            .expect("fake Codex fixture should compile with the active Rust toolchain");
        assert!(compile.success());

        let result = execute(
            &executable.to_string_lossy(),
            &json!({"model": "fake-explicit", "reasoningEffort": "high"}),
            "fake-child-private-prompt",
            "",
            Some(&temp_dir),
            10_000,
            1024 * 1024,
            1024,
        );

        assert!(result.ok, "fake child protocol failed: {:?}", result.error);
        assert_eq!(result.output, "fake child final answer");
        assert_eq!(result.session_id, "fake-thread");
        assert_eq!(result.thread_id, "fake-thread");
        assert_eq!(result.turn_id, "fake-turn");
        assert_eq!(result.turn_status, "completed");
        assert_eq!(result.effective.model.as_deref(), Some("fake-explicit"));
        assert_eq!(result.effective.reasoning_effort.as_deref(), Some("high"));
        assert!(result.stderr_truncated);

        let _ = test_fs::remove_dir_all(temp_dir);
    }
}
