use super::AdapterContract;
use crate::platform::claude_code_driver::approval::PermissionRequest;
use crate::platform::claude_code_driver::errors::ProtocolFailure;
use crate::platform::native_agent_parser::{LifecycleStage, Transition, TransitionReducer};
use serde_json::Value;
use std::io;

pub(in crate::platform) mod events;
mod state;

pub(in crate::platform) use state::{ClaudeCodeParser, TurnOutcome};
pub(super) const CONTRACT: AdapterContract = AdapterContract::new("claude-code", "lf-ndjson");

pub(in crate::platform) fn encode_message(message: &Value) -> io::Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(message).map_err(io::Error::other)?;
    bytes.push(b'\n');
    Ok(bytes)
}

pub(in crate::platform) fn user_message(prompt: &str) -> Value {
    serde_json::json!({
        "type": "user",
        "message": {"role": "user", "content": [{"type": "text", "text": prompt}]}
    })
}

pub(in crate::platform) fn interrupt_request() -> Value {
    serde_json::json!({
        "type": "control_request",
        "request_id": uuid::Uuid::new_v4().to_string(),
        "request": {"subtype": "interrupt"}
    })
}

pub(in crate::platform) fn steer_message(text: &str) -> Option<Value> {
    (!text.trim().is_empty()).then(|| user_message(text))
}

pub(in crate::platform) fn permission_response(
    request_id: &str,
    tool_use_id: Option<&str>,
    allow: bool,
) -> Value {
    let mut response = serde_json::Map::new();
    response.insert(
        "subtype".to_owned(),
        serde_json::json!("permission_response"),
    );
    response.insert("request_id".to_owned(), serde_json::json!(request_id));
    if let Some(tool_use_id) = tool_use_id {
        response.insert("tool_use_id".to_owned(), serde_json::json!(tool_use_id));
    }
    response.insert(
        "response".to_owned(),
        serde_json::json!(if allow { "allow" } else { "deny" }),
    );
    serde_json::json!({"type": "control_response", "response": response})
}

pub(in crate::platform) fn completed_transitions(output: &str) -> Vec<Transition> {
    terminal_transitions("claude-code:reply", output)
}

pub(in crate::platform) fn failure_transitions(
    code: &str,
    stage: &str,
    message: &str,
) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Submitted);
    if let Some(failure) = reducer.fail(code, stage, message) {
        transitions.push(failure);
    }
    transitions
}

fn terminal_transitions(unit_id: &str, output: &str) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Responding);
    if !output.is_empty() {
        transitions.push(Transition::Text {
            unit_id: unit_id.to_owned(),
            text: output.to_owned(),
        });
    }
    transitions.extend(reducer.advance(LifecycleStage::Completed));
    transitions
}

pub(in crate::platform) enum ClaudeEffect {
    Permission(PermissionRequest),
    Control { response: Option<Value> },
    Progress { session_id: Option<String> },
    Complete(TurnOutcome),
}

/// Sole ingress for one Claude Code stream-json wire line.
impl ClaudeCodeParser<'_> {
    pub(in crate::platform) fn parse_line(
        &mut self,
        line: &[u8],
    ) -> Result<Option<ClaudeEffect>, ProtocolFailure> {
        let trimmed = line
            .iter()
            .copied()
            .skip_while(|byte| byte.is_ascii_whitespace())
            .collect::<Vec<_>>();
        if trimmed.iter().all(|byte| byte.is_ascii_whitespace()) {
            return Ok(None);
        }
        let message: Value = serde_json::from_slice(&trimmed).map_err(|_| {
            self.failure(
                "claude_code_invalid_json",
                "Claude Code returned an invalid stream event.",
                "protocol/read",
            )
        })?;
        if message.get("type").and_then(Value::as_str) == Some("control_request") {
            if let Some(session_id) = message
                .get("session_id")
                .or_else(|| message.get("sessionId"))
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
            {
                self.record_session(session_id)?;
            }
            if let Some(permission) = permission_request_details(&message) {
                return Ok(Some(ClaudeEffect::Permission(permission)));
            }
            let request_method = message
                .pointer("/request/subtype")
                .or_else(|| message.pointer("/request/type"))
                .and_then(Value::as_str)
                .unwrap_or("control_request")
                .chars()
                .take(64)
                .collect::<String>();
            crate::platform::turn_event_emit::emit_turn_event(
                "agent.interaction.unsupported",
                self.observed_session_id
                    .as_deref()
                    .or(self.expected_session_id.as_deref())
                    .unwrap_or_default(),
                &self.config.turn_id,
                serde_json::json!({"requestMethod": request_method}),
            );
            let response = message
                .get("request_id")
                .and_then(Value::as_str)
                .map(denied_control_response);
            return Ok(Some(ClaudeEffect::Control { response }));
        }
        Ok(Some(match self.handle(message)? {
            Some(outcome) => ClaudeEffect::Complete(outcome),
            None => ClaudeEffect::Progress {
                session_id: self.observed_session_id.clone(),
            },
        }))
    }
}

fn denied_control_response(request_id: &str) -> Value {
    serde_json::json!({
        "type": "control_response",
        "response": {
            "subtype": "error",
            "request_id": request_id,
            "error": "Client interaction is unavailable."
        }
    })
}

fn permission_request_details(message: &Value) -> Option<PermissionRequest> {
    let request_id = message.get("request_id").and_then(Value::as_str)?;
    let request = message.get("request")?;
    let subtype = request
        .get("subtype")
        .or_else(|| request.get("type"))
        .and_then(Value::as_str)?;
    if subtype != "permission_request" {
        return None;
    }
    let tool_use = request.get("toolUse").or_else(|| request.get("tool_use"));
    let tool_use_id = tool_use
        .and_then(|value| value.get("id"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let tool_name = tool_use
        .and_then(|value| value.get("name"))
        .and_then(Value::as_str)
        .map(|name| name.chars().take(64).collect::<String>());
    let prompt = request
        .get("prompt")
        .or_else(|| request.get("message"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let summary = prompt
        .or_else(|| {
            tool_name
                .as_ref()
                .map(|name| format!("Claude Code requests permission for: {name}"))
        })
        .unwrap_or_else(|| "Claude Code requests permission to continue.".to_owned());
    Some(PermissionRequest {
        request_id: request_id.to_owned(),
        tool_use_id,
        tool_name,
        summary,
    })
}
