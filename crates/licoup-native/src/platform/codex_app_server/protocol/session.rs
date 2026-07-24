use super::CodexProtocol;
use super::helpers::response_is_error;
use crate::platform::codex_app_server::config::spark_default_reasoning_effort;
use crate::platform::codex_app_server::limits::{THREAD_REQUEST_ID, TURN_REQUEST_ID};
use crate::platform::codex_app_server::model::{
    EffectiveSettings, ProtocolEffect, ProtocolFailure, ProtocolPhase,
};
use serde_json::{Map, Value, json};

impl CodexProtocol {
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

    pub(super) fn handle_thread_response(&mut self, message: &Value) -> Vec<ProtocolEffect> {
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
