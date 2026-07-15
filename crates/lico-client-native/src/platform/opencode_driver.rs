use super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub(super) const RUNTIME_PROTOCOL: &str = "opencode-serve-http-v1";
const ACP_PROTOCOL_VERSION: u64 = 1;
const INITIALIZE_REQUEST_ID: i64 = 1;
const SESSION_REQUEST_ID: i64 = 2;
const PROMPT_REQUEST_ID: i64 = 3;
const FIRST_CONFIG_REQUEST_ID: i64 = 10;
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct AcpDriverSpec {
    pub(super) agent_id: &'static str,
    pub(super) error_prefix: &'static str,
    pub(super) runtime_protocol: &'static str,
    pub(super) launch_args: &'static [&'static str],
}

impl AcpDriverSpec {
    pub(super) const fn new(
        runtime_protocol: &'static str,
        launch_args: &'static [&'static str],
    ) -> Self {
        Self {
            agent_id: "acp",
            error_prefix: "acp",
            runtime_protocol,
            launch_args,
        }
    }

    pub(super) const fn with_identity(
        mut self,
        agent_id: &'static str,
        error_prefix: &'static str,
    ) -> Self {
        self.agent_id = agent_id;
        self.error_prefix = error_prefix;
        self
    }
}

const OPENCODE_DRIVER: AcpDriverSpec = AcpDriverSpec::new(RUNTIME_PROTOCOL, &["serve"])
    .with_identity("opencode-serve", "opencode_serve");

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct CapabilityProbe {
    pub(super) protocol_version: Option<u64>,
    pub(super) load_session: bool,
    pub(super) resume_session: bool,
    pub(super) close_session: bool,
    pub(super) list_sessions: bool,
    pub(super) delete_session: bool,
    pub(super) additional_directories: bool,
    pub(super) image_prompts: bool,
    pub(super) audio_prompts: bool,
    pub(super) embedded_context: bool,
}

impl CapabilityProbe {
    fn from_initialize(result: &Value) -> Self {
        let capabilities = result
            .get("agentCapabilities")
            .cloned()
            .unwrap_or_else(|| json!({}));
        Self {
            protocol_version: result.get("protocolVersion").and_then(Value::as_u64),
            load_session: capabilities
                .get("loadSession")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            resume_session: capability_object(&capabilities, &["sessionCapabilities", "resume"]),
            close_session: capability_object(&capabilities, &["sessionCapabilities", "close"]),
            list_sessions: capability_object(&capabilities, &["sessionCapabilities", "list"]),
            delete_session: capability_object(&capabilities, &["sessionCapabilities", "delete"]),
            additional_directories: capability_object(
                &capabilities,
                &["sessionCapabilities", "additionalDirectories"],
            ),
            image_prompts: capability_bool(&capabilities, &["promptCapabilities", "image"]),
            audio_prompts: capability_bool(&capabilities, &["promptCapabilities", "audio"]),
            embedded_context: capability_bool(
                &capabilities,
                &["promptCapabilities", "embeddedContext"],
            ),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(super) struct EffectiveSettings {
    pub(super) cwd: Option<String>,
    pub(super) model: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) mode: Option<String>,
    pub(super) runtime_agent: Option<String>,
    pub(super) allow_all: Option<bool>,
    pub(super) sandbox: Option<Value>,
    pub(super) approval_policy: Option<Value>,
}

#[derive(Clone, Debug)]
pub(super) struct ProtocolFailure {
    pub(super) code: String,
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
    pub(super) fn new(code: &'static str, message: &'static str, stage: &'static str) -> Self {
        Self {
            code: code.to_string(),
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

    pub(super) fn with_session(mut self, session_id: Option<&str>) -> Self {
        self.session_id = session_id.map(str::to_string);
        self.thread_id = session_id.map(str::to_string);
        self
    }

    fn user_interaction(method: &str, session_id: Option<&str>) -> Self {
        Self {
            code: "acp_user_interaction_required".to_string(),
            message: "The agent requires explicit user interaction before this turn can continue.",
            stage: "session/request_permission",
            user_interaction_required: true,
            request_method: Some(method.to_string()),
            session_id: session_id.map(str::to_string),
            thread_id: session_id.map(str::to_string),
            turn_id: None,
            turn_status: Some("cancelled".to_string()),
        }
    }

    pub(super) fn namespaced(mut self, driver: AcpDriverSpec) -> Self {
        if driver.error_prefix != "acp"
            && let Some(suffix) = self.code.strip_prefix("acp_")
        {
            self.code = format!("{}_{}", driver.error_prefix, suffix);
        }
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
    pub(super) capabilities: CapabilityProbe,
    pub(super) status_code: Option<i32>,
    pub(super) stdout_truncated: bool,
    pub(super) stderr_truncated: bool,
    pub(super) started_at: String,
    pub(super) runtime_protocol: &'static str,
    pub(super) driver_id: &'static str,
}

impl RunResult {
    pub(super) fn failed(
        driver: AcpDriverSpec,
        failure: ProtocolFailure,
        started_at: String,
        status_code: Option<i32>,
        stdout_truncated: bool,
        stderr_truncated: bool,
        capabilities: CapabilityProbe,
        events: Vec<Value>,
    ) -> Self {
        let failure = failure.namespaced(driver);
        Self {
            ok: false,
            output: String::new(),
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
            runtime_protocol: driver.runtime_protocol,
            driver_id: driver.agent_id,
            capabilities,
            events,
        }
    }
}

#[derive(Clone, Debug)]
struct RequestedSettings {
    model: Option<String>,
    reasoning_effort: Option<String>,
    mode: Option<String>,
    runtime_agent: Option<String>,
    allow_all: Option<bool>,
}

#[derive(Clone, Debug)]
struct ProtocolConfig {
    prompt: String,
    requested_session_id: String,
    cwd: String,
    settings: RequestedSettings,
}

impl ProtocolConfig {
    fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        let Some(cwd) = cwd else {
            return Err(ProtocolFailure::new(
                "acp_working_directory_required",
                "ACP conversation sessions require a working directory.",
                "session/configure",
            ));
        };
        if !cwd.is_absolute() {
            return Err(ProtocolFailure::new(
                "acp_working_directory_invalid",
                "ACP conversation sessions require an absolute working directory.",
                "session/configure",
            ));
        }
        if prompt.is_empty() {
            return Err(ProtocolFailure::new(
                "acp_prompt_required",
                "ACP conversation sessions require a non-empty prompt.",
                "session/configure",
            ));
        }
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id: session_id.trim().to_string(),
            cwd: cwd.to_string_lossy().to_string(),
            settings: RequestedSettings {
                model: text_param(params, &["model", "modelId"]),
                reasoning_effort: text_param(
                    params,
                    &["reasoningEffort", "reasoning_effort", "variant"],
                ),
                mode: text_param(params, &["runtimeMode", "agentMode", "conversationMode"]),
                runtime_agent: text_param(params, &["runtimeAgent", "customAgent"]),
                allow_all: params.get("allowAll").and_then(Value::as_bool),
            },
        })
    }

    fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty()
    }
}

#[derive(Clone, Debug)]
enum ConfigValue {
    Select(String),
    Boolean(bool),
}

#[derive(Clone, Debug)]
struct ConfigChange {
    id: String,
    value: ConfigValue,
}

#[derive(Debug)]
struct ProtocolOutcome {
    output: String,
    events: Vec<Value>,
    session_id: String,
    thread_id: String,
    turn_id: String,
    turn_status: String,
    effective: EffectiveSettings,
    capabilities: CapabilityProbe,
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
    AwaitConfig,
    AwaitPrompt,
    Finished,
}

#[derive(Debug)]
struct AcpProtocol {
    config: ProtocolConfig,
    phase: ProtocolPhase,
    capabilities: CapabilityProbe,
    session_id: Option<String>,
    config_options: Vec<Value>,
    modes: Option<Value>,
    pending_changes: VecDeque<ConfigChange>,
    current_change: Option<ConfigChange>,
    next_config_request_id: i64,
    output: String,
    events: Vec<Value>,
    interaction_failure: Option<ProtocolFailure>,
}

impl AcpProtocol {
    fn new(config: ProtocolConfig) -> Self {
        Self {
            config,
            phase: ProtocolPhase::AwaitInitialize,
            capabilities: CapabilityProbe::default(),
            session_id: None,
            config_options: Vec::new(),
            modes: None,
            pending_changes: VecDeque::new(),
            current_change: None,
            next_config_request_id: FIRST_CONFIG_REQUEST_ID,
            output: String::new(),
            events: Vec::new(),
            interaction_failure: None,
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
                    "terminal": false
                },
                "clientInfo": {
                    "name": "lico-arc",
                    "version": env!("CARGO_PKG_VERSION")
                }
            }
        })
    }

    fn handle_message(&mut self, message: Value) -> Vec<ProtocolEffect> {
        if is_server_request(&message) {
            return self.handle_server_request(&message);
        }
        if message.get("method").is_some() {
            self.handle_notification(&message);
            return Vec::new();
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
            ProtocolPhase::AwaitConfig
                if self.current_change.as_ref().is_some_and(|_| {
                    request_id_matches(&message, self.next_config_request_id - 1)
                }) =>
            {
                self.handle_config_response(&message)
            }
            ProtocolPhase::AwaitPrompt if request_id_matches(&message, PROMPT_REQUEST_ID) => {
                self.handle_prompt_response(&message)
            }
            _ => Vec::new(),
        }
    }

    fn handle_initialize_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if message.get("error").is_some() {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(failure_from_response(
                message,
                "acp_initialize_rejected",
                "The ACP agent rejected protocol initialization.",
                "initialize",
                None,
            ))];
        }
        let Some(result) = message.get("result") else {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "acp_initialize_invalid",
                "The ACP agent returned an invalid initialization response.",
                "initialize",
            ))];
        };
        self.capabilities = CapabilityProbe::from_initialize(result);
        if self.capabilities.protocol_version != Some(ACP_PROTOCOL_VERSION) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "acp_protocol_version_unsupported",
                "The ACP agent did not negotiate the required protocol version.",
                "initialize",
            ))];
        }

        self.phase = ProtocolPhase::AwaitSession;
        if self.config.is_resume() {
            self.session_id = Some(self.config.requested_session_id.clone());
            if self.capabilities.load_session {
                return vec![ProtocolEffect::Send(self.session_request("session/load"))];
            }
            if self.capabilities.resume_session {
                return vec![ProtocolEffect::Send(self.session_request("session/resume"))];
            }
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(
                ProtocolFailure::new(
                    "acp_resume_unsupported",
                    "The ACP agent cannot resume an existing native conversation.",
                    "session/resume",
                )
                .with_session(self.session_id.as_deref()),
            )];
        }
        vec![ProtocolEffect::Send(self.session_request("session/new"))]
    }

    fn session_request(&self, method: &str) -> Value {
        let mut params = json!({
            "cwd": self.config.cwd,
            "mcpServers": []
        });
        if self.config.is_resume() {
            params["sessionId"] = json!(self.config.requested_session_id);
        }
        json!({
            "jsonrpc": "2.0",
            "id": SESSION_REQUEST_ID,
            "method": method,
            "params": params
        })
    }

    fn handle_session_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if message.get("error").is_some() {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(failure_from_response(
                message,
                "acp_session_rejected",
                "The ACP agent rejected the native conversation session.",
                "session/setup",
                self.session_id.as_deref(),
            ))];
        }
        let Some(result) = message.get("result") else {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(
                ProtocolFailure::new(
                    "acp_session_invalid",
                    "The ACP agent returned an invalid session response.",
                    "session/setup",
                )
                .with_session(self.session_id.as_deref()),
            )];
        };
        if !self.config.is_resume() {
            let Some(session_id) = result
                .get("sessionId")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
            else {
                self.phase = ProtocolPhase::Finished;
                return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                    "acp_session_id_missing",
                    "The ACP agent did not return a native conversation identifier.",
                    "session/new",
                ))];
            };
            self.session_id = Some(session_id.to_string());
        }
        self.config_options = result
            .get("configOptions")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        self.modes = result
            .get("modes")
            .filter(|value| !value.is_null())
            .cloned();
        match self.requested_config_changes() {
            Ok(changes) => self.pending_changes = changes,
            Err(failure) => {
                self.phase = ProtocolPhase::Finished;
                return vec![ProtocolEffect::Fail(failure)];
            }
        }
        self.next_config_or_prompt()
    }

    fn requested_config_changes(&self) -> Result<VecDeque<ConfigChange>, ProtocolFailure> {
        let mut changes = VecDeque::new();
        if let Some(model) = self.config.settings.model.as_deref() {
            self.push_select_change(&mut changes, "model", model)?;
        }
        if let Some(reasoning) = self.config.settings.reasoning_effort.as_deref() {
            let id = if self.option("reasoning_effort").is_some() {
                "reasoning_effort"
            } else {
                "variant"
            };
            self.push_select_change(&mut changes, id, reasoning)?;
        }
        if let Some(mode) = self.config.settings.mode.as_deref() {
            self.push_select_change(&mut changes, "mode", mode)?;
        }
        if let Some(runtime_agent) = self.config.settings.runtime_agent.as_deref() {
            self.push_select_change(&mut changes, "agent", runtime_agent)?;
        }
        if let Some(allow_all) = self.config.settings.allow_all {
            self.push_boolean_change(&mut changes, "allow_all", allow_all)?;
        }
        Ok(changes)
    }

    fn push_select_change(
        &self,
        changes: &mut VecDeque<ConfigChange>,
        id: &str,
        requested: &str,
    ) -> Result<(), ProtocolFailure> {
        let Some(option) = self.option(id) else {
            return Err(self.unsupported_setting_failure());
        };
        if option.get("type").and_then(Value::as_str) != Some("select")
            || !select_value_supported(option, requested)
        {
            return Err(self.unsupported_setting_failure());
        }
        if option.get("currentValue").and_then(Value::as_str) != Some(requested) {
            changes.push_back(ConfigChange {
                id: id.to_string(),
                value: ConfigValue::Select(requested.to_string()),
            });
        }
        Ok(())
    }

    fn push_boolean_change(
        &self,
        changes: &mut VecDeque<ConfigChange>,
        id: &str,
        requested: bool,
    ) -> Result<(), ProtocolFailure> {
        let Some(option) = self.option(id) else {
            return Err(self.unsupported_setting_failure());
        };
        if option.get("type").and_then(Value::as_str) != Some("boolean") {
            return Err(self.unsupported_setting_failure());
        }
        if option.get("currentValue").and_then(Value::as_bool) != Some(requested) {
            changes.push_back(ConfigChange {
                id: id.to_string(),
                value: ConfigValue::Boolean(requested),
            });
        }
        Ok(())
    }

    fn option(&self, id: &str) -> Option<&Value> {
        self.config_options
            .iter()
            .find(|option| option.get("id").and_then(Value::as_str) == Some(id))
    }

    fn unsupported_setting_failure(&self) -> ProtocolFailure {
        ProtocolFailure::new(
            "acp_setting_unsupported",
            "The ACP agent cannot preserve one of the requested native session settings.",
            "session/configure",
        )
        .with_session(self.session_id.as_deref())
    }

    fn next_config_or_prompt(&mut self) -> Vec<ProtocolEffect> {
        if let Some(change) = self.pending_changes.pop_front() {
            let request_id = self.next_config_request_id;
            self.next_config_request_id += 1;
            let params = match &change.value {
                ConfigValue::Select(value) => json!({
                    "sessionId": self.session_id,
                    "configId": change.id,
                    "value": value
                }),
                ConfigValue::Boolean(value) => json!({
                    "sessionId": self.session_id,
                    "configId": change.id,
                    "type": "boolean",
                    "value": value
                }),
            };
            self.current_change = Some(change);
            self.phase = ProtocolPhase::AwaitConfig;
            return vec![ProtocolEffect::Send(json!({
                "jsonrpc": "2.0",
                "id": request_id,
                "method": "session/set_config_option",
                "params": params
            }))];
        }
        self.current_change = None;
        self.phase = ProtocolPhase::AwaitPrompt;
        vec![ProtocolEffect::Send(json!({
            "jsonrpc": "2.0",
            "id": PROMPT_REQUEST_ID,
            "method": "session/prompt",
            "params": {
                "sessionId": self.session_id,
                "prompt": [{"type": "text", "text": self.config.prompt}]
            }
        }))]
    }

    fn handle_config_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if message.get("error").is_some() {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(failure_from_response(
                message,
                "acp_setting_rejected",
                "The ACP agent rejected a requested native session setting.",
                "session/set_config_option",
                self.session_id.as_deref(),
            ))];
        }
        let Some(options) = message
            .get("result")
            .and_then(|result| result.get("configOptions"))
            .and_then(Value::as_array)
        else {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(
                ProtocolFailure::new(
                    "acp_setting_response_invalid",
                    "The ACP agent returned an invalid setting response.",
                    "session/set_config_option",
                )
                .with_session(self.session_id.as_deref()),
            )];
        };
        self.config_options = options.clone();
        if let Some(change) = self.current_change.as_ref()
            && !setting_applied(&self.config_options, change)
        {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(
                ProtocolFailure::new(
                    "acp_setting_not_applied",
                    "The ACP agent did not apply a requested native session setting.",
                    "session/set_config_option",
                )
                .with_session(self.session_id.as_deref()),
            )];
        }
        self.current_change = None;
        self.next_config_or_prompt()
    }

    fn handle_notification(&mut self, message: &Value) {
        if message.get("method").and_then(Value::as_str) != Some("session/update") {
            return;
        }
        let Some(params) = message.get("params") else {
            return;
        };
        if params.get("sessionId").and_then(Value::as_str) != self.session_id.as_deref() {
            return;
        }
        let Some(update) = params.get("update") else {
            return;
        };
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("config_option_update") => {
                if let Some(options) = update.get("configOptions").and_then(Value::as_array) {
                    self.config_options = options.clone();
                }
            }
            Some("current_mode_update") => {
                if let Some(mode) = update.get("currentModeId").and_then(Value::as_str)
                    && let Some(modes) = self.modes.as_mut()
                {
                    modes["currentModeId"] = json!(mode);
                }
            }
            _ => {}
        }
        if self.phase != ProtocolPhase::AwaitPrompt {
            return;
        }
        self.events.push(update.clone());
        if update.get("sessionUpdate").and_then(Value::as_str) == Some("agent_message_chunk")
            && let Some(text) = update
                .get("content")
                .and_then(|content| content.get("text"))
                .and_then(Value::as_str)
        {
            self.output.push_str(text);
            super::turn_event_emit::emit_agent_message_chunk(
                self.session_id.as_deref().unwrap_or_default(),
                "",
                text,
            );
        }
    }

    fn handle_server_request(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let id = message.get("id").cloned().unwrap_or(Value::Null);
        if method == "session/request_permission" {
            let request_session = message
                .get("params")
                .and_then(|params| params.get("sessionId"))
                .and_then(Value::as_str);
            if request_session != self.session_id.as_deref() {
                self.phase = ProtocolPhase::Finished;
                return vec![
                    ProtocolEffect::Send(json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "error": {"code": -32602, "message": "Session does not match"}
                    })),
                    ProtocolEffect::Fail(
                        ProtocolFailure::new(
                            "acp_session_mismatch",
                            "The ACP agent requested interaction for a different session.",
                            "session/request_permission",
                        )
                        .with_session(self.session_id.as_deref()),
                    ),
                ];
            }
            self.interaction_failure = Some(ProtocolFailure::user_interaction(
                method,
                self.session_id.as_deref(),
            ));
            return vec![
                ProtocolEffect::Send(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {"outcome": {"outcome": "cancelled"}}
                })),
                ProtocolEffect::Send(json!({
                    "jsonrpc": "2.0",
                    "method": "session/cancel",
                    "params": {"sessionId": self.session_id}
                })),
            ];
        }
        self.phase = ProtocolPhase::Finished;
        vec![
            ProtocolEffect::Send(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {"code": -32601, "message": "Client method is not available"}
            })),
            ProtocolEffect::Fail(
                ProtocolFailure::new(
                    "acp_client_method_unsupported",
                    "The ACP agent requested a client capability that Lico Arc did not advertise.",
                    "client/request",
                )
                .with_session(self.session_id.as_deref()),
            ),
        ]
    }

    fn handle_prompt_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if message.get("error").is_some() {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(failure_from_response(
                message,
                "acp_prompt_rejected",
                "The ACP agent rejected the requested turn.",
                "session/prompt",
                self.session_id.as_deref(),
            ))];
        }
        let stop_reason = message
            .get("result")
            .and_then(|result| result.get("stopReason"))
            .and_then(Value::as_str)
            .unwrap_or("invalid")
            .to_string();
        self.phase = ProtocolPhase::Finished;
        if let Some(mut failure) = self.interaction_failure.take() {
            failure.turn_status = Some(stop_reason);
            return vec![ProtocolEffect::Fail(failure)];
        }
        if stop_reason != "end_turn" {
            let mut failure = ProtocolFailure::new(
                "acp_turn_not_completed",
                "The ACP agent did not complete the requested turn.",
                "session/prompt",
            )
            .with_session(self.session_id.as_deref());
            failure.turn_status = Some(stop_reason);
            return vec![ProtocolEffect::Fail(failure)];
        }
        if self.output.is_empty() {
            let mut failure = ProtocolFailure::new(
                "acp_final_message_missing",
                "The ACP agent completed the turn without a final agent message.",
                "session/prompt",
            )
            .with_session(self.session_id.as_deref());
            failure.turn_status = Some(stop_reason);
            return vec![ProtocolEffect::Fail(failure)];
        }
        vec![ProtocolEffect::Complete(ProtocolOutcome {
            output: std::mem::take(&mut self.output),
            events: std::mem::take(&mut self.events),
            session_id: self.session_id.clone().unwrap_or_default(),
            thread_id: self.session_id.clone().unwrap_or_default(),
            turn_id: String::new(),
            turn_status: stop_reason,
            effective: self.effective_settings(),
            capabilities: self.capabilities.clone(),
        })]
    }

    fn effective_settings(&self) -> EffectiveSettings {
        EffectiveSettings {
            cwd: Some(self.config.cwd.clone()),
            model: current_select(&self.config_options, "model"),
            reasoning_effort: current_select(&self.config_options, "reasoning_effort")
                .or_else(|| current_select(&self.config_options, "variant")),
            mode: current_select(&self.config_options, "mode").or_else(|| {
                self.modes
                    .as_ref()
                    .and_then(|modes| modes.get("currentModeId"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            }),
            runtime_agent: current_select(&self.config_options, "agent"),
            allow_all: current_boolean(&self.config_options, "allow_all"),
            sandbox: None,
            approval_policy: current_boolean(&self.config_options, "allow_all").map(Value::Bool),
        }
    }
}

#[derive(Debug)]
struct LaunchSpec {
    executable: String,
    driver: AcpDriverSpec,
    cwd: PathBuf,
}

impl LaunchSpec {
    fn new(executable: &str, driver: AcpDriverSpec, cwd: &Path) -> Self {
        Self {
            executable: executable.to_string(),
            driver,
            cwd: cwd.to_path_buf(),
        }
    }

    fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(self.driver.launch_args)
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

pub(super) fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    let _ = (max_stdout, max_stderr);
    if !cwd.is_absolute() {
        return Err(ProtocolFailure::new(
            "acp_working_directory_invalid",
            "ACP conversation sessions require an absolute working directory.",
            "initialize",
        )
        .namespaced(OPENCODE_DRIVER));
    }
    let endpoint = super::opencode_serve::ensure_attach_endpoint(executable).map_err(|error| {
        let code = error.to_string();
        ProtocolFailure::new(
            if code.contains("missing") {
                "acp_process_start_failed"
            } else {
                "acp_process_start_failed"
            },
            "The OpenCode serve endpoint is not available for attach.",
            "serve/ensure",
        )
        .namespaced(OPENCODE_DRIVER)
    })?;
    let health_timeout = timeout_ms.max(1_000);
    let deadline = Instant::now() + Duration::from_millis(health_timeout);
    loop {
        match super::opencode_serve::get_json(&format!("{}/global/health", endpoint.attach_url)) {
            Ok(payload)
                if payload
                    .get("healthy")
                    .and_then(Value::as_bool)
                    .unwrap_or(false) =>
            {
                let _ =
                    super::opencode_serve::get_json(&format!("{}/session", endpoint.attach_url))
                        .map_err(|_| {
                            ProtocolFailure::new(
                                "acp_initialize_invalid",
                                "The ACP agent returned an invalid initialization response.",
                                "serve/session",
                            )
                            .namespaced(OPENCODE_DRIVER)
                        })?;
                return Ok(CapabilityProbe {
                    protocol_version: Some(ACP_PROTOCOL_VERSION),
                    load_session: true,
                    resume_session: true,
                    close_session: true,
                    list_sessions: true,
                    delete_session: false,
                    additional_directories: false,
                    image_prompts: false,
                    audio_prompts: false,
                    embedded_context: false,
                });
            }
            _ if Instant::now() >= deadline => {
                return Err(ProtocolFailure::new(
                    "acp_protocol_timeout",
                    "The ACP agent timed out during capability negotiation.",
                    "serve/health",
                )
                .namespaced(OPENCODE_DRIVER));
            }
            _ => thread::sleep(PROCESS_POLL_INTERVAL),
        }
    }
}

pub(super) fn probe_acp(
    driver: AcpDriverSpec,
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    probe_acp_inner(driver, executable, cwd, timeout_ms, max_stdout, max_stderr)
        .map_err(|failure| failure.namespaced(driver))
}

fn probe_acp_inner(
    driver: AcpDriverSpec,
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    if !cwd.is_absolute() {
        return Err(ProtocolFailure::new(
            "acp_working_directory_invalid",
            "ACP conversation sessions require an absolute working directory.",
            "initialize",
        ));
    }
    let launch = LaunchSpec::new(executable, driver, cwd);
    let mut child = launch.spawn().map_err(|error| {
        let message = match error.kind() {
            io::ErrorKind::NotFound => "The requested ACP agent executable is not available.",
            io::ErrorKind::PermissionDenied => {
                "The requested ACP agent executable is not permitted to run."
            }
            _ => "The requested ACP agent could not be started.",
        };
        ProtocolFailure::new("acp_process_start_failed", message, "process/start")
    })?;
    let Some(stdout) = child.stdout() else {
        return Err(acp_pipe_failure(&mut child));
    };
    let Some(stderr) = child.stderr() else {
        return Err(acp_pipe_failure(&mut child));
    };
    let Some(stdin) = child.stdin() else {
        return Err(acp_pipe_failure(&mut child));
    };
    let mut stdin = BoundedStdinWriter::new(stdin);
    let (sender, receiver) = mpsc::channel();
    let stdout_handle =
        thread::spawn(move || read_protocol_messages(BufReader::new(stdout), max_stdout, sender));
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));
    let request = json!({
        "jsonrpc": "2.0",
        "id": INITIALIZE_REQUEST_ID,
        "method": "initialize",
        "params": {
            "protocolVersion": ACP_PROTOCOL_VERSION,
            "clientCapabilities": {
                "fs": {"readTextFile": false, "writeTextFile": false},
                "terminal": false
            },
            "clientInfo": {"name": "lico-arc", "version": env!("CARGO_PKG_VERSION")}
        }
    });
    let result = if write_message(&mut stdin, &request).is_err() {
        Err(ProtocolFailure::new(
            "acp_protocol_write_failed",
            "The ACP agent stopped accepting protocol messages.",
            "initialize",
        ))
    } else {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        loop {
            if stdin.check_health().is_err() {
                break Err(ProtocolFailure::new(
                    "acp_protocol_write_failed",
                    "The ACP agent stopped accepting protocol messages.",
                    "protocol/write",
                ));
            }
            let now = Instant::now();
            if now >= deadline {
                break Err(ProtocolFailure::new(
                    "acp_protocol_timeout",
                    "The ACP agent timed out during capability negotiation.",
                    "initialize",
                ));
            }
            match receiver.recv_timeout((deadline - now).min(PROCESS_POLL_INTERVAL)) {
                Ok(TransportEvent::Message(message))
                    if request_id_matches(&message, INITIALIZE_REQUEST_ID) =>
                {
                    if message.get("error").is_some() {
                        break Err(failure_from_response(
                            &message,
                            "acp_initialize_rejected",
                            "The ACP agent rejected protocol initialization.",
                            "initialize",
                            None,
                        ));
                    }
                    let Some(response) = message.get("result") else {
                        break Err(ProtocolFailure::new(
                            "acp_initialize_invalid",
                            "The ACP agent returned an invalid initialization response.",
                            "initialize",
                        ));
                    };
                    let probe = CapabilityProbe::from_initialize(response);
                    if probe.protocol_version != Some(ACP_PROTOCOL_VERSION) {
                        break Err(ProtocolFailure::new(
                            "acp_protocol_version_unsupported",
                            "The ACP agent did not negotiate the required protocol version.",
                            "initialize",
                        ));
                    }
                    break Ok(probe);
                }
                Ok(TransportEvent::Message(_)) => {}
                Ok(TransportEvent::InvalidJson) => {
                    break Err(ProtocolFailure::new(
                        "acp_protocol_invalid_json",
                        "The ACP agent returned an invalid protocol message.",
                        "protocol/read",
                    ));
                }
                Ok(TransportEvent::StdoutLimitExceeded) => {
                    break Err(ProtocolFailure::new(
                        "acp_protocol_output_limit",
                        "The ACP agent exceeded the configured protocol output limit.",
                        "protocol/read",
                    ));
                }
                Ok(TransportEvent::StdoutReadFailed) => {
                    break Err(ProtocolFailure::new(
                        "acp_protocol_read_failed",
                        "The ACP agent protocol output could not be read.",
                        "protocol/read",
                    ));
                }
                Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                    break Err(ProtocolFailure::new(
                        "acp_process_exited",
                        "The ACP agent exited during capability negotiation.",
                        "process/exit",
                    ));
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
    };
    let cleanup = finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
    if cleanup == Err(TransportFinishFailure::Lifecycle) {
        return Err(ProtocolFailure::new(
            "acp_process_cleanup_failed",
            "The ACP agent process cleanup could not be completed safely.",
            "process/cleanup",
        ));
    }
    if result.is_ok() && cleanup == Err(TransportFinishFailure::StdinWrite) {
        return Err(ProtocolFailure::new(
            "acp_protocol_write_failed",
            "The ACP agent stopped accepting protocol messages.",
            "protocol/write",
        ));
    }
    result
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
    let _ = (max_stdout, max_stderr);
    let started_at = timestamp();
    let config = match ProtocolConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => {
            return RunResult::failed(
                OPENCODE_DRIVER,
                failure,
                started_at,
                None,
                false,
                false,
                CapabilityProbe::default(),
                Vec::new(),
            );
        }
    };

    let endpoint = match super::opencode_serve::ensure_attach_endpoint(executable) {
        Ok(endpoint) => endpoint,
        Err(error) => {
            let missing = error.to_string().contains("missing");
            return RunResult::failed(
                OPENCODE_DRIVER,
                ProtocolFailure::new(
                    "acp_process_start_failed",
                    if missing {
                        "The requested ACP agent executable is not available."
                    } else {
                        "The OpenCode serve endpoint is not available for attach."
                    },
                    "serve/ensure",
                ),
                started_at,
                None,
                false,
                false,
                CapabilityProbe::default(),
                Vec::new(),
            );
        }
    };

    let deadline = Instant::now() + Duration::from_millis(timeout_ms.max(1_000));
    match execute_via_serve(&endpoint, &config, deadline) {
        Ok(outcome) => RunResult {
            ok: true,
            output: outcome.output,
            events: outcome.events,
            error: None,
            session_id: outcome.session_id,
            thread_id: outcome.thread_id,
            turn_id: outcome.turn_id,
            turn_status: outcome.turn_status,
            effective: outcome.effective,
            capabilities: outcome.capabilities,
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at,
            runtime_protocol: OPENCODE_DRIVER.runtime_protocol,
            driver_id: OPENCODE_DRIVER.agent_id,
        },
        Err(failure) => RunResult::failed(
            OPENCODE_DRIVER,
            failure,
            started_at,
            None,
            false,
            false,
            CapabilityProbe::default(),
            Vec::new(),
        ),
    }
}

fn execute_via_serve(
    endpoint: &super::opencode_serve::ServeEndpoint,
    config: &ProtocolConfig,
    deadline: Instant,
) -> Result<ProtocolOutcome, ProtocolFailure> {
    let session_id = if config.is_resume() {
        let url = format!(
            "{}/session/{}",
            endpoint.attach_url, config.requested_session_id
        );
        match super::opencode_serve::get_json(&url) {
            Ok(payload) if payload.get("id").and_then(Value::as_str).is_some() => {
                config.requested_session_id.clone()
            }
            Err(error) if error.to_string().contains("opencode_serve_not_found") => {
                return Err(ProtocolFailure::new(
                    "acp_native_session_not_found",
                    "The requested native conversation does not exist in the ACP agent.",
                    "session/load",
                )
                .with_session(Some(&config.requested_session_id)));
            }
            Ok(_) | Err(_) => {
                return Err(ProtocolFailure::new(
                    "acp_native_session_not_found",
                    "The requested native conversation does not exist in the ACP agent.",
                    "session/load",
                )
                .with_session(Some(&config.requested_session_id)));
            }
        }
    } else {
        let mut body = json!({});
        if !config.cwd.is_empty() {
            body["directory"] = json!(config.cwd);
        }
        let created = wait_post_json(&format!("{}/session", endpoint.attach_url), &body, deadline)?;
        created
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .ok_or_else(|| {
                ProtocolFailure::new(
                    "acp_session_id_missing",
                    "The ACP agent did not return a native conversation identifier.",
                    "session/new",
                )
            })?
    };

    let mut message_body = json!({
        "parts": [{"type": "text", "text": config.prompt}]
    });
    if let Some(model) = config.settings.model.as_deref() {
        // OpenCode accepts provider/model; when only a bare id is present keep text.
        if let Some((provider, model_id)) = model.split_once('/') {
            message_body["model"] = json!({
                "providerID": provider,
                "modelID": model_id
            });
        }
    }
    if let Some(agent) = config.settings.runtime_agent.as_deref() {
        message_body["agent"] = json!(agent);
    }

    let turn_id = Uuid::new_v4().to_string();
    let watch_stop = Arc::new(AtomicBool::new(false));
    let watch_flag = Arc::clone(&watch_stop);
    let watch_url = endpoint.attach_url.clone();
    let watch_session = session_id.clone();
    let (chunk_sender, chunk_receiver) = mpsc::sync_channel::<String>(64);
    let watch_handle = thread::spawn(move || {
        super::opencode_serve::watch_session_events(
            &watch_url,
            &watch_session,
            &watch_flag,
            &chunk_sender,
        );
    });
    let post_url = format!("{}/session/{}/message", endpoint.attach_url, session_id);
    let post_handle = thread::spawn(move || wait_post_json(&post_url, &message_body, deadline));
    let mut streamed = Vec::new();
    while !post_handle.is_finished() {
        match chunk_receiver.recv_timeout(PROCESS_POLL_INTERVAL) {
            Ok(text) => {
                super::turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &text);
                streamed.push(text);
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    let response = post_handle.join().map_err(|_| {
        ProtocolFailure::new(
            "acp_protocol_read_failed",
            "The OpenCode serve response worker could not be joined.",
            "serve/http",
        )
    })?;
    watch_stop.store(true, Ordering::Relaxed);
    let _ = watch_handle.join();
    for text in chunk_receiver.try_iter() {
        super::turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &text);
        streamed.push(text);
    }
    let response = response?;
    let output = extract_assistant_text(&response);
    if output.is_empty() {
        return Err(ProtocolFailure::new(
            "acp_final_message_missing",
            "The ACP agent completed the turn without a final agent message.",
            "session/prompt",
        )
        .with_session(Some(&session_id)));
    }
    if streamed.is_empty() {
        super::turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &output);
        streamed.push(output.clone());
    }
    super::turn_event_emit::emit_agent_message_completed(&session_id, &turn_id, &output);
    Ok(ProtocolOutcome {
        output: output.clone(),
        events: streamed
            .into_iter()
            .map(|text| {
                json!({
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text}
                })
            })
            .collect(),
        session_id: session_id.clone(),
        thread_id: session_id,
        turn_id,
        turn_status: "end_turn".to_string(),
        effective: EffectiveSettings {
            cwd: Some(config.cwd.clone()),
            model: config.settings.model.clone(),
            reasoning_effort: config.settings.reasoning_effort.clone(),
            mode: config.settings.mode.clone(),
            runtime_agent: config.settings.runtime_agent.clone(),
            allow_all: config.settings.allow_all,
            sandbox: None,
            approval_policy: None,
        },
        capabilities: CapabilityProbe {
            protocol_version: Some(ACP_PROTOCOL_VERSION),
            load_session: true,
            resume_session: true,
            close_session: true,
            list_sessions: true,
            delete_session: false,
            additional_directories: false,
            image_prompts: false,
            audio_prompts: false,
            embedded_context: false,
        },
    })
}

fn wait_post_json(url: &str, body: &Value, deadline: Instant) -> Result<Value, ProtocolFailure> {
    if Instant::now() >= deadline {
        return Err(ProtocolFailure::new(
            "acp_protocol_timeout",
            "The ACP agent timed out before the turn completed.",
            "session/prompt",
        ));
    }
    super::opencode_serve::post_json(url, body).map_err(|_| {
        ProtocolFailure::new(
            "acp_protocol_write_failed",
            "The ACP agent stopped accepting protocol messages.",
            "serve/http",
        )
    })
}

fn extract_assistant_text(response: &Value) -> String {
    let mut chunks = Vec::new();
    if let Some(parts) = response.get("parts").and_then(Value::as_array) {
        for part in parts {
            if part.get("type").and_then(Value::as_str) == Some("text")
                && let Some(text) = part.get("text").and_then(Value::as_str)
            {
                chunks.push(text.to_string());
            }
        }
    }
    if chunks.is_empty()
        && let Some(parts) = response
            .get("info")
            .and_then(|_| response.get("parts"))
            .and_then(Value::as_array)
    {
        for part in parts {
            if let Some(text) = part.get("text").and_then(Value::as_str) {
                chunks.push(text.to_string());
            }
        }
    }
    // Some OpenCode versions return a list of messages.
    if chunks.is_empty()
        && let Some(items) = response.as_array()
    {
        for item in items {
            if item
                .get("info")
                .and_then(|info| info.get("role"))
                .and_then(Value::as_str)
                == Some("assistant")
            {
                chunks.push(extract_assistant_text(item));
            }
        }
    }
    chunks.join("")
}

pub(super) fn execute_acp(
    driver: AcpDriverSpec,
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
            return RunResult::failed(
                driver,
                failure,
                started_at,
                None,
                false,
                false,
                CapabilityProbe::default(),
                Vec::new(),
            );
        }
    };
    let launch = LaunchSpec::new(executable, driver, Path::new(&config.cwd));
    let mut child = match launch.spawn() {
        Ok(child) => child,
        Err(error) => {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The requested ACP agent executable is not available.",
                io::ErrorKind::PermissionDenied => {
                    "The requested ACP agent executable is not permitted to run."
                }
                _ => "The requested ACP agent could not be started.",
            };
            return RunResult::failed(
                driver,
                ProtocolFailure::new("acp_process_start_failed", message, "process/start"),
                started_at,
                None,
                false,
                false,
                CapabilityProbe::default(),
                Vec::new(),
            );
        }
    };

    let Some(stdout) = child.stdout() else {
        return pipe_failure(driver, &mut child, started_at);
    };
    let Some(stderr) = child.stderr() else {
        return pipe_failure(driver, &mut child, started_at);
    };
    let Some(stdin) = child.stdin() else {
        return pipe_failure(driver, &mut child, started_at);
    };
    let mut stdin = BoundedStdinWriter::new(stdin);

    let (sender, receiver) = mpsc::channel();
    let stdout_handle =
        thread::spawn(move || read_protocol_messages(BufReader::new(stdout), max_stdout, sender));
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));

    let mut protocol = AcpProtocol::new(config);
    if write_message(&mut stdin, &protocol.initial_request()).is_err() {
        let cleanup =
            finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
        let cleanup_failed = cleanup == Err(TransportFinishFailure::Lifecycle);
        return RunResult::failed(
            driver,
            ProtocolFailure::new(
                if cleanup_failed {
                    "acp_process_cleanup_failed"
                } else {
                    "acp_protocol_write_failed"
                },
                if cleanup_failed {
                    "The ACP agent process cleanup could not be completed safely."
                } else {
                    "The ACP agent stopped accepting protocol messages."
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
            CapabilityProbe::default(),
            Vec::new(),
        );
    }

    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let (outcome, failure, status_code, stdout_was_truncated) =
        run_protocol_loop(&mut stdin, &receiver, &mut protocol, deadline);
    let capabilities = protocol.capabilities.clone();
    let events = std::mem::take(&mut protocol.events);

    let cleanup = finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
    let stderr_was_truncated = stderr_truncated.load(Ordering::Relaxed);

    if cleanup == Err(TransportFinishFailure::Lifecycle) {
        return RunResult::failed(
            driver,
            ProtocolFailure::new(
                "acp_process_cleanup_failed",
                "The ACP agent process cleanup could not be completed safely.",
                "process/cleanup",
            ),
            started_at,
            status_code,
            stdout_was_truncated,
            stderr_was_truncated,
            capabilities,
            events,
        );
    }
    if outcome.is_some() && cleanup == Err(TransportFinishFailure::StdinWrite) {
        return RunResult::failed(
            driver,
            ProtocolFailure::new(
                "acp_protocol_write_failed",
                "The ACP agent stopped accepting protocol messages.",
                "protocol/write",
            ),
            started_at,
            status_code,
            stdout_was_truncated,
            stderr_was_truncated,
            capabilities,
            events,
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
            capabilities: outcome.capabilities,
            status_code,
            stdout_truncated: stdout_was_truncated,
            stderr_truncated: stderr_was_truncated,
            started_at,
            runtime_protocol: driver.runtime_protocol,
            driver_id: driver.agent_id,
        };
    }

    RunResult::failed(
        driver,
        failure.unwrap_or_else(|| {
            ProtocolFailure::new(
                "acp_protocol_failed",
                "The ACP agent did not complete the request.",
                "protocol",
            )
            .with_session(protocol.session_id.as_deref())
        }),
        started_at,
        status_code,
        stdout_was_truncated,
        stderr_was_truncated,
        capabilities,
        events,
    )
}

fn pipe_failure(
    driver: AcpDriverSpec,
    child: &mut SupervisedChild,
    started_at: String,
) -> RunResult {
    let cleanup_ok = child.terminate_tree().is_ok();
    RunResult::failed(
        driver,
        ProtocolFailure::new(
            if cleanup_ok {
                "acp_process_pipe_failed"
            } else {
                "acp_process_cleanup_failed"
            },
            if cleanup_ok {
                "The ACP agent protocol pipes are unavailable."
            } else {
                "The ACP agent process cleanup could not be completed safely."
            },
            if cleanup_ok {
                "process/start"
            } else {
                "process/cleanup"
            },
        ),
        started_at,
        None,
        false,
        false,
        CapabilityProbe::default(),
        Vec::new(),
    )
}

fn run_protocol_loop(
    stdin: &mut BoundedStdinWriter,
    receiver: &Receiver<TransportEvent>,
    protocol: &mut AcpProtocol,
    deadline: Instant,
) -> (
    Option<ProtocolOutcome>,
    Option<ProtocolFailure>,
    Option<i32>,
    bool,
) {
    loop {
        if stdin.check_health().is_err() {
            let failure = ProtocolFailure::new(
                "acp_protocol_write_failed",
                "The ACP agent stopped accepting protocol messages.",
                "protocol/write",
            )
            .with_session(protocol.session_id.as_deref());
            return (None, Some(failure), None, false);
        }
        let now = Instant::now();
        if now >= deadline {
            let failure = ProtocolFailure::new(
                "acp_protocol_timeout",
                "The ACP agent timed out before the turn completed.",
                "session/prompt",
            )
            .with_session(protocol.session_id.as_deref());
            return (None, Some(failure), None, false);
        }
        let wait = (deadline - now).min(PROCESS_POLL_INTERVAL);
        match receiver.recv_timeout(wait) {
            Ok(TransportEvent::Message(message)) => {
                for effect in protocol.handle_message(message) {
                    match effect {
                        ProtocolEffect::Send(message) => {
                            if write_message(stdin, &message).is_err() {
                                let failure = ProtocolFailure::new(
                                    "acp_protocol_write_failed",
                                    "The ACP agent stopped accepting protocol messages.",
                                    "protocol/write",
                                )
                                .with_session(protocol.session_id.as_deref());
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
                        "acp_protocol_invalid_json",
                        "The ACP agent returned an invalid protocol message.",
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
                        "acp_protocol_output_limit",
                        "The ACP agent exceeded the configured protocol output limit.",
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
                        "acp_protocol_read_failed",
                        "The ACP agent protocol output could not be read.",
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
                        "acp_process_exited",
                        "The ACP agent exited before the turn completed.",
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
    let mut total = 0usize;
    let mut buffer = [0u8; 8192];
    loop {
        match stderr.read(&mut buffer) {
            Ok(0) => return,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
            Ok(count) => {
                total = total.saturating_add(count);
                if total > max_bytes {
                    truncated.store(true, Ordering::Relaxed);
                }
            }
        }
    }
}

fn acp_pipe_failure(child: &mut SupervisedChild) -> ProtocolFailure {
    if child.terminate_tree().is_ok() {
        ProtocolFailure::new(
            "acp_process_pipe_failed",
            "The ACP agent protocol pipes are unavailable.",
            "process/start",
        )
    } else {
        ProtocolFailure::new(
            "acp_process_cleanup_failed",
            "The ACP agent process cleanup could not be completed safely.",
            "process/cleanup",
        )
    }
}

fn request_id_matches(message: &Value, id: i64) -> bool {
    message.get("id").and_then(Value::as_i64) == Some(id)
}

fn is_server_request(message: &Value) -> bool {
    message.get("id").is_some() && message.get("method").and_then(Value::as_str).is_some()
}

fn failure_from_response(
    message: &Value,
    fallback_code: &'static str,
    fallback_message: &'static str,
    stage: &'static str,
    session_id: Option<&str>,
) -> ProtocolFailure {
    match message
        .get("error")
        .and_then(|error| error.get("code"))
        .and_then(Value::as_i64)
    {
        Some(-32000) => {
            let mut failure = ProtocolFailure::new(
                "acp_authentication_required",
                "The ACP agent requires native authentication before this request can continue.",
                stage,
            )
            .with_session(session_id);
            failure.user_interaction_required = true;
            failure.request_method = Some("authenticate".to_string());
            failure
        }
        Some(-32002) => ProtocolFailure::new(
            "acp_native_session_not_found",
            "The requested native conversation does not exist in the ACP agent.",
            stage,
        )
        .with_session(session_id),
        Some(-32800) => {
            let mut failure = ProtocolFailure::new(
                "acp_request_cancelled",
                "The ACP agent cancelled the request.",
                stage,
            )
            .with_session(session_id);
            failure.turn_status = Some("cancelled".to_string());
            failure
        }
        _ => ProtocolFailure::new(fallback_code, fallback_message, stage).with_session(session_id),
    }
}

fn capability_bool(value: &Value, path: &[&str]) -> bool {
    path.iter()
        .try_fold(value, |current, key| current.get(*key))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn capability_object(value: &Value, path: &[&str]) -> bool {
    path.iter()
        .try_fold(value, |current, key| current.get(*key))
        .is_some_and(Value::is_object)
}

fn select_value_supported(option: &Value, requested: &str) -> bool {
    fn contains(options: &[Value], requested: &str) -> bool {
        options.iter().any(|item| {
            item.get("value").and_then(Value::as_str) == Some(requested)
                || item
                    .get("options")
                    .and_then(Value::as_array)
                    .is_some_and(|nested| contains(nested, requested))
        })
    }
    option
        .get("options")
        .and_then(Value::as_array)
        .is_some_and(|options| contains(options, requested))
}

fn setting_applied(options: &[Value], change: &ConfigChange) -> bool {
    options
        .iter()
        .find(|option| option.get("id").and_then(Value::as_str) == Some(change.id.as_str()))
        .is_some_and(|option| match &change.value {
            ConfigValue::Select(value) => {
                option.get("currentValue").and_then(Value::as_str) == Some(value.as_str())
            }
            ConfigValue::Boolean(value) => {
                option.get("currentValue").and_then(Value::as_bool) == Some(*value)
            }
        })
}

fn current_select(options: &[Value], id: &str) -> Option<String> {
    options
        .iter()
        .find(|option| option.get("id").and_then(Value::as_str) == Some(id))
        .and_then(|option| option.get("currentValue"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn current_boolean(options: &[Value], id: &str) -> Option<bool> {
    options
        .iter()
        .find(|option| option.get("id").and_then(Value::as_str) == Some(id))
        .and_then(|option| option.get("currentValue"))
        .and_then(Value::as_bool)
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        params
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
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
    use std::fs;
    use std::process::Command;

    fn absolute_test_cwd() -> PathBuf {
        std::env::current_dir().expect("test working directory")
    }

    fn initialize_response(load: bool, resume: bool) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": INITIALIZE_REQUEST_ID,
            "result": {
                "protocolVersion": ACP_PROTOCOL_VERSION,
                "agentCapabilities": {
                    "loadSession": load,
                    "sessionCapabilities": if resume { json!({"resume": {}}) } else { json!({}) },
                    "promptCapabilities": {"image": true}
                }
            }
        })
    }

    fn new_protocol(params: Value, prompt: &str, session: &str) -> AcpProtocol {
        AcpProtocol::new(
            ProtocolConfig::from_params(
                &params,
                prompt,
                session,
                Some(absolute_test_cwd().as_path()),
            )
            .unwrap(),
        )
    }

    #[test]
    fn new_session_applies_settings_then_collects_only_matching_agent_output() {
        let mut protocol = new_protocol(json!({"model": "provider/model"}), "private", "");
        let effects = protocol.handle_message(initialize_response(true, true));
        assert!(matches!(effects[0], ProtocolEffect::Send(_)));
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0",
            "id": SESSION_REQUEST_ID,
            "result": {
                "sessionId": "native-session",
                "configOptions": [{
                    "id": "model", "name": "Model", "type": "select",
                    "currentValue": "default", "options": [
                        {"value": "default", "name": "Default"},
                        {"value": "provider/model", "name": "Requested"}
                    ]
                }]
            }
        }));
        let ProtocolEffect::Send(setting) = &effects[0] else {
            panic!("expected setting request")
        };
        assert_eq!(setting["method"], "session/set_config_option");
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0", "id": FIRST_CONFIG_REQUEST_ID,
            "result": {"configOptions": [{
                "id": "model", "name": "Model", "type": "select",
                "currentValue": "provider/model", "options": []
            }]}
        }));
        let ProtocolEffect::Send(prompt) = &effects[0] else {
            panic!("expected prompt request")
        };
        assert_eq!(prompt["method"], "session/prompt");
        assert_eq!(prompt["params"]["prompt"][0]["text"], "private");
        protocol.handle_message(json!({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "other", "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "wrong"}
            }}
        }));
        protocol.handle_message(json!({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "native-session", "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "final"}
            }}
        }));
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0", "id": PROMPT_REQUEST_ID,
            "result": {"stopReason": "end_turn"}
        }));
        let ProtocolEffect::Complete(outcome) = &effects[0] else {
            panic!("expected completion")
        };
        assert_eq!(outcome.output, "final");
        assert_eq!(outcome.session_id, "native-session");
        assert_eq!(outcome.effective.model.as_deref(), Some("provider/model"));
        assert_eq!(outcome.events.len(), 1);
    }

    #[test]
    fn resume_uses_load_when_advertised_and_keeps_native_id() {
        let mut protocol = new_protocol(json!({}), "next", "existing-native");
        let effects = protocol.handle_message(initialize_response(true, true));
        let ProtocolEffect::Send(request) = &effects[0] else {
            panic!("expected load request")
        };
        assert_eq!(request["method"], "session/load");
        assert_eq!(request["params"]["sessionId"], "existing-native");
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0", "id": SESSION_REQUEST_ID,
            "result": {"configOptions": []}
        }));
        assert!(matches!(effects[0], ProtocolEffect::Send(_)));
        assert_eq!(protocol.session_id.as_deref(), Some("existing-native"));
    }

    #[test]
    fn resume_fails_closed_when_agent_does_not_advertise_it() {
        let mut protocol = new_protocol(json!({}), "next", "existing-native");
        let effects = protocol.handle_message(initialize_response(false, false));
        let ProtocolEffect::Fail(failure) = &effects[0] else {
            panic!("expected failure")
        };
        assert_eq!(failure.code, "acp_resume_unsupported");
    }

    #[test]
    fn rejected_native_resume_never_falls_back_to_a_new_session() {
        let mut protocol = new_protocol(json!({}), "next", "missing-native");
        let effects = protocol.handle_message(initialize_response(true, true));
        let ProtocolEffect::Send(load) = &effects[0] else {
            panic!("expected load request")
        };
        assert_eq!(load["method"], "session/load");
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0", "id": SESSION_REQUEST_ID,
            "error": {"code": -32002, "message": "not found"}
        }));
        assert_eq!(effects.len(), 1);
        let ProtocolEffect::Fail(failure) = &effects[0] else {
            panic!("expected resume failure")
        };
        assert_eq!(failure.code, "acp_native_session_not_found");
        assert_eq!(protocol.phase, ProtocolPhase::Finished);
    }

    #[test]
    fn native_authentication_error_is_structured_user_interaction() {
        let failure = failure_from_response(
            &json!({"error": {"code": -32000, "message": "private runtime detail"}}),
            "acp_session_rejected",
            "fallback",
            "session/setup",
            Some("native"),
        );
        assert_eq!(failure.code, "acp_authentication_required");
        assert!(failure.user_interaction_required);
        assert_eq!(failure.request_method.as_deref(), Some("authenticate"));
        assert!(!failure.message.contains("private"));
    }

    #[test]
    fn permission_request_is_cancelled_and_reported_as_user_interaction() {
        let mut protocol = new_protocol(json!({}), "prompt", "");
        protocol.handle_message(initialize_response(true, true));
        protocol.handle_message(json!({
            "jsonrpc": "2.0", "id": SESSION_REQUEST_ID,
            "result": {"sessionId": "native", "configOptions": []}
        }));
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0", "id": 91, "method": "session/request_permission",
            "params": {"sessionId": "native", "options": []}
        }));
        assert_eq!(effects.len(), 2);
        let ProtocolEffect::Send(response) = &effects[0] else {
            panic!("expected permission response")
        };
        assert_eq!(response["result"]["outcome"]["outcome"], "cancelled");
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0", "id": PROMPT_REQUEST_ID,
            "result": {"stopReason": "cancelled"}
        }));
        let ProtocolEffect::Fail(failure) = &effects[0] else {
            panic!("expected interaction failure")
        };
        assert!(failure.user_interaction_required);
    }

    #[test]
    fn launch_arguments_are_fixed_and_do_not_contain_prompt_or_path() {
        let cwd = absolute_test_cwd();
        let launch = LaunchSpec::new("opencode", OPENCODE_DRIVER, &cwd);
        assert_eq!(launch.driver.launch_args, &["serve"]);
        assert!(
            !launch
                .driver
                .launch_args
                .iter()
                .any(|arg| *arg == "private")
        );
        assert!(
            !launch
                .driver
                .launch_args
                .iter()
                .any(|arg| *arg == cwd.to_string_lossy())
        );
        assert!(
            !launch
                .driver
                .launch_args
                .iter()
                .any(|arg| *arg == "native-session" || *arg == "provider/model")
        );
    }

    #[test]
    fn wrapper_namespaces_structured_failures_without_exposing_private_values() {
        let result = execute(
            "unused",
            &json!({}),
            "private-prompt",
            "private-session",
            Some(Path::new("relative")),
            10,
            10,
            10,
        );
        assert_eq!(result.driver_id, "opencode-serve");
        let failure = result.error.unwrap();
        assert_eq!(failure.code, "opencode_serve_working_directory_invalid");
        assert!(!failure.message.contains("private"));
    }

    #[test]
    fn extract_assistant_text_reads_parts_without_private_leak_markers() {
        let text = extract_assistant_text(&json!({
            "parts": [{"type": "text", "text": "final answer"}]
        }));
        assert_eq!(text, "final answer");
    }

    #[test]
    fn fake_child_transport_proves_stdin_session_id_and_concurrent_stderr_drain() {
        let dir = std::env::temp_dir().join(format!("lico-acp-fake-{}", timestamp()));
        fs::create_dir_all(&dir).unwrap();
        let source = dir.join("fake_agent.rs");
        let executable = dir.join(format!("fake-agent{}", std::env::consts::EXE_SUFFIX));
        fs::write(&source, FAKE_AGENT_SOURCE).unwrap();
        let status = Command::new("rustc")
            .args(["--edition", "2021"])
            .arg(&source)
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap();
        assert!(status.success());
        let acp_driver = AcpDriverSpec::new("test-acp", &["acp"]).with_identity("test-acp", "acp");
        let result = execute_acp(
            acp_driver,
            executable.to_string_lossy().as_ref(),
            &json!({}),
            "private-stdin-prompt",
            "",
            Some(dir.as_path()),
            10_000,
            1024 * 1024,
            1024,
        );
        assert!(result.ok, "fake ACP failure: {:?}", result.error);
        assert_eq!(result.output, "fake final");
        assert_eq!(result.session_id, "native-fake-session");
        assert_eq!(result.turn_status, "end_turn");
        assert_eq!(result.capabilities.protocol_version, Some(1));
        assert!(result.stderr_truncated);
        let _ = fs::remove_dir_all(dir);
    }

    const FAKE_AGENT_SOURCE: &str = r#"
use std::io::{self, BufRead, Write};
fn id(line: &str) -> i64 {
    let marker = "\"id\":";
    let start = line.find(marker).unwrap() + marker.len();
    line[start..].chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().unwrap()
}
fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    assert_eq!(args, vec!["acp"]);
    std::thread::spawn(|| { let mut e=io::stderr(); let _=e.write_all(&vec![b'x'; 128*1024]); });
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    let first = lines.next().unwrap().unwrap();
    assert!(first.contains("\"method\":\"initialize\""));
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":true}}}}}}", id(&first));
    io::stdout().flush().unwrap();
    let second = lines.next().unwrap().unwrap();
    assert!(second.contains("\"method\":\"session/new\""));
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"sessionId\":\"native-fake-session\",\"configOptions\":[]}}}}", id(&second));
    io::stdout().flush().unwrap();
    let third = lines.next().unwrap().unwrap();
    assert!(third.contains("private-stdin-prompt"));
    assert!(third.contains("\"method\":\"session/prompt\""));
    println!("{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"native-fake-session\",\"update\":{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"text\",\"text\":\"fake final\"}}}}}}}}");
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"stopReason\":\"end_turn\"}}}}", id(&third));
    io::stdout().flush().unwrap();
    std::thread::sleep(std::time::Duration::from_secs(1));
}
"#;
}
