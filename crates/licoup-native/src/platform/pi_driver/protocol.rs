use super::errors::ProtocolFailure;
use super::events::{processing_evidence_kind, sanitized_event};
use super::model::EffectiveSettings;
use super::params::ProtocolConfig;
use serde_json::{Value, json};

#[derive(Clone, Debug)]
pub(super) struct ProtocolOutcome {
    pub(super) output: String,
    pub(super) events: Vec<Value>,
    pub(super) session_id: String,
    pub(super) turn_id: String,
    pub(super) turn_status: String,
    pub(super) effective: EffectiveSettings,
}

#[derive(Debug)]
pub(super) enum ProtocolEffect {
    Send(Value),
    Complete(ProtocolOutcome),
    Fail(ProtocolFailure),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ProtocolPhase {
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
pub(super) struct PiProtocol {
    pub(super) config: ProtocolConfig,
    pub(super) phase: ProtocolPhase,
    pub(super) session_id: Option<String>,
    pub(super) output: String,
    pub(super) events: Vec<Value>,
    pub(super) effective: EffectiveSettings,
    pub(super) pending_request: Option<&'static str>,
    /// Last provider/turn error observed during the active prompt (not echoed
    /// raw to callers; used only to classify a typed failure when text is empty).
    turn_error: Option<String>,
}

impl PiProtocol {
    pub(super) fn new(config: ProtocolConfig) -> Self {
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
            turn_error: None,
        }
    }

    pub(super) fn initial_request(&mut self) -> Value {
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

    pub(super) fn failure_with_ids(
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

    pub(super) fn active_turn_binding(&self) -> Option<(&str, &str)> {
        if self.phase != ProtocolPhase::AwaitSettled {
            return None;
        }
        Some((self.session_id.as_deref()?, &self.config.turn_id))
    }

    pub(super) fn handle_message(&mut self, message: Value) -> Vec<ProtocolEffect> {
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
                    // Pi returns {"text": null} when the last assistant turn has
                    // no text (for example a provider error). Never wipe streamed
                    // deltas with an empty/null snapshot.
                    if let Some(text) = message.pointer("/data/text").and_then(Value::as_str) {
                        if !text.trim().is_empty() {
                            self.output = text.to_string();
                        }
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
                    return vec![ProtocolEffect::Fail(self.empty_final_failure())];
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
                super::super::turn_event_emit::emit_agent_message_completed(
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
            if let Some(evidence_kind) = processing_evidence_kind(message)
                && let Some(session_id) = self.session_id.as_deref()
            {
                super::super::turn_event_emit::emit_agent_processing(
                    session_id,
                    &self.config.turn_id,
                    evidence_kind,
                    None,
                );
            }
            self.events.extend(
                super::super::skill_invocation_projection::project_skill_invocations(message),
            );
            if let Some(event) = sanitized_event(message) {
                self.events.push(event);
            }
            self.capture_turn_error(message);
            self.capture_assistant_text_event(message);
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

    fn capture_assistant_text_event(&mut self, message: &Value) {
        let Some(event) = message.get("assistantMessageEvent") else {
            return;
        };
        let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");
        match event_type {
            "text_delta" => {
                if let Some(delta) = event.get("delta").and_then(Value::as_str) {
                    self.output.push_str(delta);
                    if let Some(session_id) = self.session_id.as_deref() {
                        super::super::turn_event_emit::emit_agent_message_chunk(
                            session_id,
                            &self.config.turn_id,
                            delta,
                        );
                    }
                }
            }
            "text_end" => {
                // Authoritative block text when deltas were missed.
                if self.output.trim().is_empty() {
                    if let Some(content) = event.get("content").and_then(Value::as_str) {
                        if !content.trim().is_empty() {
                            self.output = content.to_owned();
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn capture_turn_error(&mut self, message: &Value) {
        let message_type = message.get("type").and_then(Value::as_str).unwrap_or("");
        match message_type {
            "message_end" => {
                let Some(assistant) = message.get("message") else {
                    return;
                };
                if assistant.get("role").and_then(Value::as_str) != Some("assistant") {
                    return;
                }
                let stop = assistant
                    .get("stopReason")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if let Some(error) = assistant
                    .get("errorMessage")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                {
                    self.turn_error = Some(error.to_owned());
                } else if stop == "error" {
                    self.turn_error =
                        Some("assistant stopReason=error without errorMessage".to_owned());
                }
            }
            "auto_retry_end" => {
                if message.get("success").and_then(Value::as_bool) == Some(false) {
                    if let Some(error) = message
                        .get("finalError")
                        .or_else(|| message.get("errorMessage"))
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                    {
                        self.turn_error = Some(error.to_owned());
                    }
                }
            }
            "extension_error" => {
                if let Some(error) = message
                    .get("errorMessage")
                    .or_else(|| message.get("message"))
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                {
                    self.turn_error = Some(error.to_owned());
                }
            }
            _ => {}
        }
    }

    fn empty_final_failure(&self) -> ProtocolFailure {
        let detail = self.turn_error.as_deref().unwrap_or("");
        if detail.contains("gateway_credential_unavailable") {
            return self.failure_with_ids(
                "pi_gateway_credentials_unavailable",
                "Pi Agent could not call the model because the LLM Gateway has no authorized API keys. Open LicoUp → Keys and authorize credentials so they are hot-applied to the running Gateway.",
                "prompt/complete",
            );
        }
        if !detail.is_empty() {
            return self.failure_with_ids(
                "pi_provider_turn_failed",
                "Pi Agent finished the turn without an assistant reply after a model or provider error.",
                "prompt/complete",
            );
        }
        self.failure_with_ids(
            "pi_final_message_missing",
            "Pi Agent completed without a final assistant message.",
            "prompt/complete",
        )
    }
}
