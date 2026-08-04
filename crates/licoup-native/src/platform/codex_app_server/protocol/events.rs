use super::CodexProtocol;
use super::helpers::{final_agent_message, matches_current_ids};
use crate::platform::codex_app_server::model::{
    ProtocolEffect, ProtocolFailure, ProtocolOutcome, ProtocolPhase,
};
use serde_json::Value;

impl CodexProtocol {
    pub(super) fn handle_notification(&mut self, message: &Value) -> Vec<ProtocolEffect> {
        match message.get("method").and_then(Value::as_str) {
            Some("item/started") => {
                self.observe_processing_item(message);
                Vec::new()
            }
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
            self.emit_processing_item(item);
            self.completed_items.push(item.clone());
            if item.get("type").and_then(Value::as_str) == Some("agentMessage")
                && let Some(text) = item.get("text").and_then(Value::as_str)
            {
                crate::platform::turn_event_emit::emit_agent_message_completed(
                    self.thread_id.as_deref().unwrap_or_default(),
                    self.turn_id.as_deref().unwrap_or_default(),
                    text,
                );
            }
        }
    }

    fn observe_processing_item(&self, message: &Value) {
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
            self.emit_processing_item(item);
        }
    }

    fn emit_processing_item(&self, item: &Value) {
        let item_type = item.get("type").and_then(Value::as_str).unwrap_or_default();
        if item_type == "agentMessage" {
            return;
        }
        let evidence_kind = if item_type.contains("reason") {
            "reasoning"
        } else if item_type.contains("plan") {
            "plan"
        } else if item_type.contains("command")
            || item_type.contains("tool")
            || item_type.contains("mcp")
        {
            "tool"
        } else {
            "activity"
        };
        crate::platform::turn_event_emit::emit_agent_processing(
            self.thread_id.as_deref().unwrap_or_default(),
            self.turn_id.as_deref().unwrap_or_default(),
            evidence_kind,
        );
    }

    fn emit_agent_message_delta(&self, message: &Value) {
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
            crate::platform::turn_event_emit::emit_agent_message_chunk(
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
            crate::platform::turn_event_emit::emit_turn_event(
                "dispatch.turn.failed",
                self.thread_id.as_deref().unwrap_or_default(),
                self.turn_id.as_deref().unwrap_or_default(),
                serde_json::json!({ "turnStatus": status }),
            );
            let mut failure = self.contextualize(ProtocolFailure::new(
                "codex_turn_not_completed",
                "Codex did not complete the requested turn.",
                "turn/completed",
            ));
            failure.turn_status = Some(status);
            return vec![ProtocolEffect::Fail(failure)];
        }
        crate::platform::turn_event_emit::emit_turn_event(
            "dispatch.turn.completed",
            self.thread_id.as_deref().unwrap_or_default(),
            self.turn_id.as_deref().unwrap_or_default(),
            serde_json::json!({ "turnStatus": "completed" }),
        );
        let Some(output) = final_message else {
            let mut failure = self.contextualize(ProtocolFailure::new(
                "codex_final_message_missing",
                "Codex completed the turn without a final agent message.",
                "turn/completed",
            ));
            failure.turn_status = Some(status);
            return vec![ProtocolEffect::Fail(failure)];
        };

        let mut events = self
            .completed_items
            .iter()
            .filter(|item| item.get("type").and_then(Value::as_str) == Some("agentMessage"))
            .cloned()
            .collect::<Vec<_>>();
        for item in &self.completed_items {
            events.extend(
                crate::platform::skill_invocation_projection::project_skill_invocations(item),
            );
        }
        vec![ProtocolEffect::Complete(ProtocolOutcome {
            output,
            events,
            session_id: self.session_id.clone().unwrap_or_default(),
            thread_id: self.thread_id.clone().unwrap_or_default(),
            turn_id: self.turn_id.clone().unwrap_or_default(),
            turn_status: status,
            effective: self.effective.clone(),
        })]
    }
}
