use super::errors::ProtocolFailure;
use serde_json::{Value, json};
use std::io;
use std::path::Path;
use uuid::Uuid;

#[derive(Clone, Debug)]
pub(super) struct DriverConfig {
    pub(super) prompt: String,
    pub(super) requested_session_id: String,
    pub(super) model: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) permission_mode: Option<String>,
    pub(super) turn_id: String,
}

impl DriverConfig {
    pub(super) fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        _cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        if prompt.trim().is_empty() {
            return Err(ProtocolFailure::new(
                "claude_code_empty_prompt",
                "Claude Code requires a non-empty message.",
                "request/validate",
            ));
        }
        let reasoning_effort = text_param(params, &["reasoningEffort", "reasoning_effort"]);
        if reasoning_effort.as_deref().is_some_and(|value| {
            !matches!(
                value,
                "low" | "medium" | "high" | "xhigh" | "max" | "ultracode"
            )
        }) {
            return Err(ProtocolFailure::new(
                "claude_code_invalid_effort",
                "Claude Code does not support the requested effort level.",
                "request/validate",
            ));
        }
        let permission_mode = text_param(
            params,
            &[
                "permissionMode",
                "permission_mode",
                "approvalPolicy",
                "approval_policy",
            ],
        )
        .map(|value| match value.as_str() {
            "manual" => "manual".to_string(),
            "on-request" => "default".to_string(),
            "never" => "dontAsk".to_string(),
            _ => value,
        });
        if permission_mode.as_deref().is_some_and(|value| {
            !matches!(
                value,
                "default"
                    | "manual"
                    | "acceptEdits"
                    | "plan"
                    | "auto"
                    | "dontAsk"
                    | "bypassPermissions"
            )
        }) {
            return Err(ProtocolFailure::new(
                "claude_code_invalid_permission_mode",
                "Claude Code does not support the requested permission mode.",
                "request/validate",
            ));
        }
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id: session_id.trim().to_string(),
            model: text_param(params, &["model", "modelId"]),
            reasoning_effort,
            permission_mode,
            turn_id: Uuid::new_v4().to_string(),
        })
    }

    pub(super) fn stdin_message(&self) -> io::Result<Value> {
        // The live process owns continuity; neither prompt nor session ID is argv data.
        serde_json::to_value(json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": self.prompt}]
            }
        }))
        .map_err(io::Error::other)
    }
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}
