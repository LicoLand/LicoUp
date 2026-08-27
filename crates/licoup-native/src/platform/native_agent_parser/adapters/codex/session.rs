use super::CodexParser;
use super::helpers::response_is_error;
use crate::platform::codex_app_server::config::spark_default_reasoning_effort;
use crate::platform::codex_app_server::limits::{
    THREAD_REQUEST_ID, THREAD_UNARCHIVE_REQUEST_ID, TURN_REQUEST_ID,
};
use crate::platform::codex_app_server::model::{
    EffectiveSettings, ProtocolEffect, ProtocolFailure, ProtocolPhase,
};
use serde_json::{Map, Value, json};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum RolloutIdentityError {
    Unavailable,
    Missing,
}

/// Resolve the native identity from the rollout record itself. A source path is
/// only a locator: its file name never authorizes a resume.
pub(in crate::platform) fn rollout_record_identity(
    path: &Path,
) -> Result<String, RolloutIdentityError> {
    let file = File::open(path).map_err(|_| RolloutIdentityError::Unavailable)?;
    for line in BufReader::new(file).lines() {
        let line = line.map_err(|_| RolloutIdentityError::Unavailable)?;
        if line.trim().is_empty() {
            continue;
        }
        let value: Value =
            serde_json::from_str(&line).map_err(|_| RolloutIdentityError::Unavailable)?;
        if value.get("type").and_then(Value::as_str) != Some("session_meta") {
            continue;
        }
        return value
            .pointer("/payload/id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|identity| !identity.is_empty())
            .map(str::to_string)
            .ok_or(RolloutIdentityError::Missing);
    }
    Err(RolloutIdentityError::Missing)
}

fn response_error_message(message: &Value) -> Option<&str> {
    message.get("error")?.get("message")?.as_str()
}

fn resume_target_is_archived(message: &Value, thread_id: &str) -> bool {
    response_error_message(message).is_some_and(|error| {
        error == format!("session {thread_id} is archived")
            || error
                == format!(
                    "session {thread_id} is archived. Run `codex unarchive {thread_id}` to unarchive it first."
                )
    })
}

impl CodexParser {
    pub(super) fn handle_initialize_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
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
        if let Some(instructions) = self.config.private_instructions.as_ref() {
            params.insert("developerInstructions".to_string(), json!(instructions));
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

    fn thread_unarchive_request(&self) -> Value {
        json!({
            "id": THREAD_UNARCHIVE_REQUEST_ID,
            "method": "thread/unarchive",
            "params": {"threadId": self.config.requested_session_id}
        })
    }

    fn requested_thread_failure(&self, mut failure: ProtocolFailure) -> ProtocolFailure {
        if !self.config.requested_session_id.is_empty() {
            failure.session_id = Some(self.config.requested_session_id.clone());
            failure.thread_id = Some(self.config.requested_session_id.clone());
        }
        failure
    }

    pub(super) fn handle_thread_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            if self.config.is_resume() {
                let requested_thread_id = self.config.requested_session_id.clone();
                if !self.unarchive_attempted
                    && resume_target_is_archived(message, &requested_thread_id)
                {
                    self.unarchive_attempted = true;
                    self.phase = ProtocolPhase::AwaitThreadUnarchive;
                    return vec![ProtocolEffect::Send(self.thread_unarchive_request())];
                }
            }
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.requested_thread_failure(
                ProtocolFailure::new(
                    "codex_thread_open_failed",
                    "Codex could not open the requested conversation.",
                    if self.config.is_resume() {
                        "thread/resume"
                    } else {
                        "thread/start"
                    },
                ),
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
        if self.config.is_resume() && thread_id != self.config.requested_session_id {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.requested_thread_failure(
                ProtocolFailure::new(
                    "codex_thread_resume_identity_mismatch",
                    "Codex resumed a different conversation than the one requested.",
                    "thread/resume",
                ),
            ))];
        }

        self.thread_id = Some(thread_id.to_string());
        // Native continuation authority is the app-server thread id. A
        // transcript/session extension must never replace that binding.
        self.session_id = Some(thread_id.to_string());
        self.effective = EffectiveSettings {
            cwd: result
                .get("cwd")
                .or_else(|| thread.get("cwd"))
                .and_then(Value::as_str)
                .map(str::to_string),
            model: self.config.model.clone(),
            reasoning_effort: self.config.reasoning_effort.clone(),
            sandbox: result.get("sandbox").cloned(),
            approval_policy: result.get("approvalPolicy").cloned(),
        };

        self.phase = ProtocolPhase::AwaitTurnStart;
        vec![ProtocolEffect::Send(self.turn_start_request(thread_id))]
    }

    pub(super) fn handle_thread_unarchive_response(
        &mut self,
        message: &Value,
    ) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.requested_thread_failure(
                ProtocolFailure::new(
                    "codex_thread_unarchive_failed",
                    "Codex could not restore the archived conversation.",
                    "thread/unarchive",
                ),
            ))];
        }

        let returned_thread_id = message
            .get("result")
            .and_then(|result| result.get("thread"))
            .and_then(|thread| thread.get("id"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty());
        if returned_thread_id != Some(self.config.requested_session_id.as_str()) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.requested_thread_failure(
                ProtocolFailure::new(
                    "codex_thread_unarchive_identity_mismatch",
                    "Codex restored a different conversation than the one requested.",
                    "thread/unarchive",
                ),
            ))];
        }

        self.phase = ProtocolPhase::AwaitThread;
        vec![ProtocolEffect::Send(self.thread_request())]
    }

    fn turn_start_request(&self, thread_id: &str) -> Value {
        let mut params = Map::new();
        params.insert("threadId".to_string(), json!(thread_id));
        let mut input = Vec::new();
        if !self.config.prompt.is_empty() {
            input.push(json!({
                "type": "text",
                "text": self.config.prompt
            }));
        }
        for image in &self.config.local_images {
            input.push(json!({
                "type": "localImage",
                "path": image.path,
                "mediaType": image.media_type,
                "name": image.name
            }));
        }
        params.insert("input".to_string(), json!(input));
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

    pub(super) fn handle_turn_start_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        if response_is_error(message) {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.contextualize(
                ProtocolFailure::new(
                    "codex_turn_start_failed",
                    "Codex could not start the requested turn.",
                    "turn/start",
                ),
            ))];
        }
        let Some(turn_id) = message
            .get("result")
            .and_then(|result| result.get("turn"))
            .and_then(|turn| turn.get("id"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        else {
            self.phase = ProtocolPhase::Finished;
            return vec![ProtocolEffect::Fail(self.contextualize(
                ProtocolFailure::new(
                    "codex_protocol_error",
                    "Codex app-server did not return a turn identifier.",
                    "turn/start",
                ),
            ))];
        };

        self.turn_id = Some(turn_id.to_string());
        crate::platform::turn_event_emit::emit_turn_event(
            "agent.turn.accepted",
            self.thread_id.as_deref().unwrap_or_default(),
            turn_id,
            json!({ "evidenceKind": "turn-start-ack" }),
        );
        if let Some(model) = self.config.model.as_ref() {
            self.effective.model = Some(model.clone());
        }
        if let Some(effort) = self.config.reasoning_effort.as_ref() {
            self.effective.reasoning_effort = Some(effort.clone());
        }
        self.phase = ProtocolPhase::AwaitTurnCompleted;
        Vec::new()
    }
}
