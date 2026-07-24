use super::command::LaunchIdentity;
use super::errors::ProtocolFailure;
use super::events::{partial_text_delta, project_event};
use super::model::EffectiveSettings;
use super::params::DriverConfig;
use serde_json::Value;

#[derive(Debug)]
pub(super) struct TurnOutcome {
    pub(super) output: String,
    pub(super) events: Vec<Value>,
    pub(super) session_id: String,
    pub(super) turn_id: String,
    pub(super) effective: EffectiveSettings,
}

pub(super) struct TurnState<'a> {
    pub(super) config: &'a DriverConfig,
    pub(super) expected_session_id: Option<String>,
    pub(super) observed_session_id: Option<String>,
    pub(super) events: Vec<Value>,
    pub(super) interaction_failure: bool,
    pub(super) effective: EffectiveSettings,
    started_emitted: bool,
}

impl<'a> TurnState<'a> {
    pub(super) fn new(
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
            started_emitted: false,
        }
    }

    pub(super) fn handle(
        &mut self,
        message: Value,
    ) -> Result<Option<TurnOutcome>, ProtocolFailure> {
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
            super::super::turn_event_emit::emit_agent_message_chunk(
                self.observed_session_id
                    .as_deref()
                    .or(self.expected_session_id.as_deref())
                    .unwrap_or_default(),
                &self.config.turn_id,
                text,
            );
        }
        self.events
            .extend(super::super::skill_invocation_projection::project_skill_invocations(&message));
        if let Some(projected) = project_event(&message) {
            self.events.push(projected);
        }
        if message.get("type").and_then(Value::as_str) != Some("result") {
            return Ok(None);
        }
        self.finish(message).map(Some)
    }

    pub(super) fn record_session(&mut self, value: &str) -> Result<(), ProtocolFailure> {
        if value.len() > 512 || value.chars().any(char::is_control) {
            return Err(self.failure(
                "claude_code_session_id_invalid",
                "Claude Code returned an invalid native conversation identifier.",
                "session/open",
            ));
        }
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
        if !self.started_emitted {
            super::super::turn_event_emit::emit_turn_event(
                "dispatch.turn.started",
                value,
                &self.config.turn_id,
                serde_json::json!({"transport": "claude-code-cli-stream-json"}),
            );
            self.started_emitted = true;
        }
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
            if matches!(subtype, "authentication_required" | "authentication_failed") {
                return Err(self
                    .failure(
                        "claude_code_authentication_required",
                        "Claude Code authentication is required before this turn can continue.",
                        "authentication/runtime",
                    )
                    .with_session(Some(&session_id)));
            }
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
        super::super::turn_event_emit::emit_agent_message_completed(
            &session_id,
            &self.config.turn_id,
            output,
        );
        super::super::turn_event_emit::emit_turn_event(
            "dispatch.turn.completed",
            &session_id,
            &self.config.turn_id,
            serde_json::json!({"output": output}),
        );
        Ok(TurnOutcome {
            output: output.to_string(),
            events: self.events.clone(),
            session_id,
            turn_id: self.config.turn_id.clone(),
            effective: self.effective.clone(),
        })
    }

    pub(super) fn failure(
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
