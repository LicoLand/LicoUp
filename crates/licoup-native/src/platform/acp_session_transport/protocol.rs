use super::approval_store::permission_request_display_safe;
use super::capabilities::EffectiveSettings;
use super::command::ProtocolConfig;
use super::errors::ProtocolFailure;
use super::events::{request_id_matches, response_is_error};
use crate::core::acp::{
    self, AcpClientCapabilities, AcpImplementation, AcpSessionMethod, AcpSessionOptions,
};
use serde_json::{Value, json};
use std::path::Path;

pub(in crate::platform) const INITIALIZE_REQUEST_ID: i64 = 1;
pub(in crate::platform) const SESSION_REQUEST_ID: i64 = 2;
pub(in crate::platform) const MODEL_REQUEST_ID: i64 = 3;
pub(in crate::platform) const PROMPT_REQUEST_ID: i64 = 4;

#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolOutcome {
    pub(in crate::platform) output: String,
    pub(in crate::platform) events: Vec<Value>,
    pub(in crate::platform) session_id: String,
    pub(in crate::platform) turn_id: String,
    pub(in crate::platform) turn_status: String,
    pub(in crate::platform) effective: EffectiveSettings,
}

#[derive(Debug)]
pub(in crate::platform) enum ProtocolEffect {
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
pub(in crate::platform) enum ProtocolPhase {
    AwaitInitialize,
    AwaitSession,
    AwaitModel,
    AwaitPrompt,
    Finished,
}

#[derive(Debug)]
pub(in crate::platform) struct SessionProtocol {
    pub(in crate::platform) config: ProtocolConfig,
    pub(in crate::platform) phase: ProtocolPhase,
    pub(in crate::platform) session_id: Option<String>,
    pub(in crate::platform) output: String,
    pub(in crate::platform) events: Vec<Value>,
    pub(in crate::platform) effective: EffectiveSettings,
    pub(in crate::platform) interaction_failure: Option<ProtocolFailure>,
}

impl SessionProtocol {
    pub(in crate::platform) fn new(config: ProtocolConfig) -> Self {
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

    pub(in crate::platform) fn new_ready(config: ProtocolConfig) -> Self {
        let mut protocol = Self::new(config);
        protocol.phase = ProtocolPhase::AwaitSession;
        protocol
    }

    pub(in crate::platform) fn initial_request(&self) -> Result<Value, ProtocolFailure> {
        acp::initialize_request(
            INITIALIZE_REQUEST_ID,
            &AcpImplementation::new("lico-up", env!("CARGO_PKG_VERSION")).title("LicoUp"),
            AcpClientCapabilities::default(),
        )
        .map_err(|error| ProtocolFailure::from_acp(error, acp::INITIALIZE_METHOD))
    }

    pub(in crate::platform) fn handle_message(&mut self, message: Value) -> Vec<ProtocolEffect> {
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

    pub(in crate::platform) fn handle_server_request(
        &mut self,
        message: &Value,
    ) -> Option<Vec<ProtocolEffect>> {
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
            match acp::cancel_notification(session_id) {
                Ok(notification) => effects.push(ProtocolEffect::Send(notification)),
                Err(error) => {
                    let mut failure = ProtocolFailure::from_acp(error, acp::SESSION_CANCEL_METHOD);
                    failure.session_id = self.session_id.clone();
                    effects.push(ProtocolEffect::Fail(failure));
                }
            }
        }
        Some(effects)
    }

    pub(in crate::platform) fn fail_closed_permission_denial(
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
            match acp::cancel_notification(session_id) {
                Ok(notification) => effects.push(ProtocolEffect::Send(notification)),
                Err(error) => {
                    let mut failure = ProtocolFailure::from_acp(error, acp::SESSION_CANCEL_METHOD);
                    failure.session_id = self.session_id.clone();
                    effects.push(ProtocolEffect::Fail(failure));
                }
            }
        }
        effects
    }

    pub(in crate::platform) fn handle_initialize_response(
        &mut self,
        message: &Value,
    ) -> Vec<ProtocolEffect> {
        let response = match acp::validate_initialize_response(message, INITIALIZE_REQUEST_ID) {
            Ok(response) => response,
            Err(error) if error.is_remote_error() => {
                self.phase = ProtocolPhase::Finished;
                return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                    "hermes_acp_initialize_failed",
                    "Hermes ACP initialization failed.",
                    acp::INITIALIZE_METHOD,
                ))];
            }
            Err(error) => {
                self.phase = ProtocolPhase::Finished;
                return vec![ProtocolEffect::Fail(ProtocolFailure::from_acp(
                    error,
                    acp::INITIALIZE_METHOD,
                ))];
            }
        };
        if !response.capabilities.load_session {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(ProtocolFailure::new(
                "hermes_acp_capability_mismatch",
                "Hermes ACP does not expose the required conversation lifecycle.",
                "initialize/capabilities",
            ))];
        }
        self.phase = ProtocolPhase::AwaitSession;
        let request = self.session_request();
        self.request_effect(request)
    }

    pub(in crate::platform) fn session_request(&self) -> Result<Value, ProtocolFailure> {
        let method = if self.config.is_resume() {
            AcpSessionMethod::Load(&self.config.requested_session_id)
        } else {
            AcpSessionMethod::New
        };
        let stage = method.method_name();
        acp::session_request(
            SESSION_REQUEST_ID,
            method,
            AcpSessionOptions::new(Path::new(&self.config.cwd))
                .mcp_servers(&self.config.mcp_servers),
        )
        .map_err(|error| ProtocolFailure::from_acp(error, stage))
    }

    pub(in crate::platform) fn request_effect(
        &mut self,
        request: Result<Value, ProtocolFailure>,
    ) -> Vec<ProtocolEffect> {
        match request {
            Ok(request) => vec![ProtocolEffect::Send(request)],
            Err(mut failure) => {
                self.phase = ProtocolPhase::Finished;
                failure.session_id = self.session_id.clone();
                vec![ProtocolEffect::Fail(failure)]
            }
        }
    }

    pub(in crate::platform) fn handle_session_response(
        &mut self,
        message: &Value,
    ) -> Vec<ProtocolEffect> {
        let method = if self.config.is_resume() {
            AcpSessionMethod::Load(&self.config.requested_session_id)
        } else {
            AcpSessionMethod::New
        };
        let response = match acp::validate_session_response(message, SESSION_REQUEST_ID, method) {
            Ok(response) => response,
            Err(error) if error.is_remote_error() => {
                self.phase = ProtocolPhase::Finished;
                return vec![ProtocolEffect::Fail(self.failure_with_ids(
                    "hermes_acp_session_open_failed",
                    "Hermes ACP could not open the requested conversation.",
                    method.method_name(),
                ))];
            }
            Err(error) => {
                self.phase = ProtocolPhase::Finished;
                let mut failure = ProtocolFailure::from_acp(error, method.method_name());
                failure.session_id = self
                    .config
                    .is_resume()
                    .then(|| self.config.requested_session_id.clone());
                return vec![ProtocolEffect::Fail(failure)];
            }
        };
        let session_id = if self.config.is_resume() {
            if response
                .session_id
                .as_deref()
                .is_some_and(|returned| returned != self.config.requested_session_id)
            {
                self.phase = ProtocolPhase::Finished;
                return vec![ProtocolEffect::Fail(self.failure_with_ids(
                    "hermes_acp_session_mismatch",
                    "Hermes ACP returned a different conversation than the one requested.",
                    acp::SESSION_LOAD_METHOD,
                ))];
            }
            self.config.requested_session_id.clone()
        } else {
            response.session_id.unwrap_or_default()
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
            let request = self.prompt_request();
            self.request_effect(request)
        }
    }

    pub(in crate::platform) fn model_request(&self) -> Value {
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

    pub(in crate::platform) fn handle_model_response(
        &mut self,
        message: &Value,
    ) -> Vec<ProtocolEffect> {
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
        let request = self.prompt_request();
        self.request_effect(request)
    }

    pub(in crate::platform) fn prompt_request(&self) -> Result<Value, ProtocolFailure> {
        let session_id = self.session_id.as_deref().ok_or_else(|| {
            ProtocolFailure::new(
                "hermes_acp_session_id_missing",
                "Hermes ACP did not return a native conversation identifier.",
                acp::SESSION_PROMPT_METHOD,
            )
        })?;
        acp::text_prompt_request(PROMPT_REQUEST_ID, session_id, &self.config.prompt)
            .map_err(|error| ProtocolFailure::from_acp(error, acp::SESSION_PROMPT_METHOD))
    }

    pub(in crate::platform) fn handle_prompt_response(
        &mut self,
        message: &Value,
    ) -> Vec<ProtocolEffect> {
        let response = match acp::validate_prompt_response(message, PROMPT_REQUEST_ID) {
            Ok(response) => response,
            Err(error) if error.is_remote_error() => {
                self.phase = ProtocolPhase::Finished;
                return vec![ProtocolEffect::Fail(self.failure_with_ids(
                    "hermes_acp_prompt_failed",
                    "Hermes ACP could not complete the requested turn.",
                    acp::SESSION_PROMPT_METHOD,
                ))];
            }
            Err(error) => {
                self.phase = ProtocolPhase::Finished;
                let mut failure = ProtocolFailure::from_acp(error, acp::SESSION_PROMPT_METHOD);
                failure.session_id = self.session_id.clone();
                return vec![ProtocolEffect::Fail(failure)];
            }
        };
        let stop_reason = response.stop_reason.as_str().to_owned();
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
        super::super::turn_event_emit::emit_agent_message_completed(
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

    pub(in crate::platform) fn handle_notification(
        &mut self,
        message: Value,
    ) -> Vec<ProtocolEffect> {
        if message.get("method").and_then(Value::as_str) != Some(acp::SESSION_UPDATE_METHOD) {
            return Vec::new();
        }
        let Some(expected_session_id) = self.session_id.as_deref() else {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.failure_with_ids(
                acp::AcpError::SessionMismatch.code(),
                "Hermes ACP sent an update before establishing its conversation.",
                acp::SESSION_UPDATE_METHOD,
            ))];
        };
        let update = match acp::validate_session_update(&message, Some(expected_session_id)) {
            Ok(update) => update,
            Err(error) => {
                self.phase = ProtocolPhase::Finished;
                let mut failure = ProtocolFailure::from_acp(error, acp::SESSION_UPDATE_METHOD);
                failure.session_id = self.session_id.clone();
                failure.turn_id = Some(self.config.turn_id.clone());
                return vec![ProtocolEffect::Fail(failure)];
            }
        };
        let text = update.agent_message_text().map(str::to_owned);
        let current_mode = update.current_mode_id().map(str::to_owned);
        if self.phase == ProtocolPhase::AwaitPrompt {
            if let Some(evidence_kind) = update.kind().processing_evidence_kind() {
                super::super::turn_event_emit::emit_agent_processing(
                    self.session_id.as_deref().unwrap_or_default(),
                    &self.config.turn_id,
                    evidence_kind,
                );
            }
            let skill_events = super::super::skill_invocation_projection::project_skill_invocations(
                update.payload(),
            );
            if skill_events.is_empty() {
                self.events.push(update.payload().clone());
            } else {
                self.events.extend(skill_events);
            }
            if let Some(text) = text {
                self.output.push_str(&text);
                super::super::turn_event_emit::emit_agent_message_chunk(
                    self.session_id.as_deref().unwrap_or_default(),
                    &self.config.turn_id,
                    &text,
                );
            }
        }
        if let Some(mode) = current_mode {
            self.effective.approval_policy = Some(json!(mode));
        }
        Vec::new()
    }

    pub(in crate::platform) fn capture_effective_controls(&mut self, result: Option<&Value>) {
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

    pub(in crate::platform) fn failure_with_ids(
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
