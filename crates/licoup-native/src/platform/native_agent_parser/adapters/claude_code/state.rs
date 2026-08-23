use super::events::{partial_text_delta, processing_evidence_kind, processing_tool_name};
use crate::platform::claude_code_driver::command::LaunchIdentity;
use crate::platform::claude_code_driver::errors::ProtocolFailure;
use crate::platform::claude_code_driver::model::EffectiveSettings;
use crate::platform::claude_code_driver::params::DriverConfig;
use serde_json::{Value, json};

#[derive(Debug)]
pub(in crate::platform) struct TurnOutcome {
    pub(in crate::platform) output: String,
    pub(in crate::platform) session_id: String,
    pub(in crate::platform) turn_id: String,
    pub(in crate::platform) effective: EffectiveSettings,
}

pub(in crate::platform) struct ClaudeCodeParser<'a> {
    pub(super) config: &'a DriverConfig,
    pub(in crate::platform) expected_session_id: Option<String>,
    pub(in crate::platform) observed_session_id: Option<String>,
    pub(super) effective: EffectiveSettings,
    started_emitted: bool,
}

impl<'a> ClaudeCodeParser<'a> {
    pub(in crate::platform) fn new(
        config: &'a DriverConfig,
        identity: &LaunchIdentity,
        known_session: Option<String>,
    ) -> Self {
        Self {
            config,
            expected_session_id: known_session,
            observed_session_id: None,
            effective: identity.effective(),
            started_emitted: false,
        }
    }

    pub(in crate::platform) fn handle(
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
        if message.get("type").and_then(Value::as_str) == Some("system")
            && message.get("subtype").and_then(Value::as_str) == Some("permission_denied")
        {
            crate::platform::turn_event_emit::emit_turn_event(
                "permission.denied",
                self.observed_session_id
                    .as_deref()
                    .or(self.expected_session_id.as_deref())
                    .unwrap_or_default(),
                &self.config.turn_id,
                json!({"text": "Claude Code reported a permission denial."}),
            );
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
            crate::platform::turn_event_emit::emit_agent_message_chunk(
                self.observed_session_id
                    .as_deref()
                    .or(self.expected_session_id.as_deref())
                    .unwrap_or_default(),
                &self.config.turn_id,
                text,
            );
        }
        // Real Claude Code 2.x print streams deliver whole assistant messages
        // instead of content_block_delta events: each tool-call round arrives
        // as one assistant message whose content text blocks carry the reply.
        // Surface every text block as a chunk so the client renders progress
        // turn by turn instead of waiting for the final result.
        if message.get("type").and_then(Value::as_str) == Some("assistant")
            && let Some(blocks) = message
                .pointer("/message/content")
                .and_then(Value::as_array)
        {
            for block in blocks {
                if block.get("type").and_then(Value::as_str) == Some("text")
                    && let Some(text) = block
                        .get("text")
                        .and_then(Value::as_str)
                        .filter(|text| !text.trim().is_empty())
                {
                    crate::platform::turn_event_emit::emit_agent_message_chunk(
                        self.observed_session_id
                            .as_deref()
                            .or(self.expected_session_id.as_deref())
                            .unwrap_or_default(),
                        &self.config.turn_id,
                        text,
                    );
                }
            }
        }
        if let Some(evidence_kind) = processing_evidence_kind(&message) {
            crate::platform::turn_event_emit::emit_agent_processing(
                self.observed_session_id
                    .as_deref()
                    .or(self.expected_session_id.as_deref())
                    .unwrap_or_default(),
                &self.config.turn_id,
                evidence_kind,
                processing_tool_name(&message),
            );
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
            crate::platform::turn_event_emit::emit_turn_event(
                "agent.turn.accepted",
                value,
                &self.config.turn_id,
                serde_json::json!({"evidenceKind": "stream-init"}),
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
        // Permission denials are rendered honestly, never failed: the CLI
        // already answered the denial and completed the turn. Each denied
        // tool is surfaced as a permission.denied event so the client can show
        // an approval card with a retry affordance.
        if let Some(denials) = terminal
            .get("permission_denials")
            .and_then(Value::as_array)
            .filter(|values| !values.is_empty())
        {
            for denial in denials {
                let tool_name = denial
                    .get("tool_name")
                    .and_then(Value::as_str)
                    .unwrap_or("tool");
                let tool_use_id = denial
                    .get("tool_use_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let session_id = self
                    .observed_session_id
                    .as_deref()
                    .or(self.expected_session_id.as_deref())
                    .unwrap_or_default();
                crate::platform::turn_event_emit::emit_turn_event(
                    "permission.denied",
                    session_id,
                    &self.config.turn_id,
                    json!({
                        "toolName": tool_name,
                        "toolUseId": tool_use_id,
                        "text": format!("{tool_name} was denied permission."),
                    }),
                );
            }
        }
        let deferred = terminal.get("deferred_tool_use").is_some()
            || terminal
                .get("terminal_reason")
                .or_else(|| terminal.get("stop_reason"))
                .and_then(Value::as_str)
                == Some("tool_deferred");
        if deferred {
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
        // The CLI reports tool errors as `error_during_execution` even when
        // the turn completed with a real reply. Only an explicit is_error
        // (or a missing flag on a plain failure) fails the turn; the honest
        // reply stays visible.
        let is_error = terminal
            .get("is_error")
            .and_then(Value::as_bool)
            .unwrap_or(subtype == "failed");
        if is_error {
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
        crate::platform::turn_event_emit::emit_agent_message_completed(
            &session_id,
            &self.config.turn_id,
            output,
        );
        crate::platform::turn_event_emit::emit_turn_event(
            "dispatch.turn.completed",
            &session_id,
            &self.config.turn_id,
            serde_json::json!({"output": output}),
        );
        Ok(TurnOutcome {
            output: output.to_string(),
            session_id,
            turn_id: self.config.turn_id.clone(),
            effective: self.effective.clone(),
        })
    }

    pub(in crate::platform) fn failure(
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
