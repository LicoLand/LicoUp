use super::errors::ProtocolFailure;
use serde_json::Value;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug)]
pub(in crate::platform) struct RequestedSettings {
    pub(in crate::platform) model: Option<String>,
    pub(in crate::platform) reasoning_effort: Option<String>,
    pub(in crate::platform) mode: Option<String>,
    pub(in crate::platform) runtime_agent: Option<String>,
    pub(in crate::platform) allow_all: Option<bool>,
}

#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolConfig {
    pub(in crate::platform) prompt: String,
    pub(in crate::platform) requested_session_id: String,
    pub(in crate::platform) cwd: String,
    pub(in crate::platform) settings: RequestedSettings,
    pub(in crate::platform) mcp_servers: Vec<Value>,
}

impl ProtocolConfig {
    pub(in crate::platform) fn from_params(
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
            mcp_servers: Vec::new(),
        })
    }

    pub(in crate::platform) fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty()
    }

    pub(in crate::platform) fn load_collaboration_mcp(
        &mut self,
        runtime_id: &str,
    ) -> Result<(), ProtocolFailure> {
        self.mcp_servers = crate::domain::collaboration_plugin::acp_servers_for_runtime(runtime_id)
            .map_err(|_| {
                ProtocolFailure::new(
                    "acp_mcp_registration_invalid",
                    "The optional MCP registration could not be validated safely.",
                    "session/mcp",
                )
            })?;
        Ok(())
    }
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

pub(in crate::platform) fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}
