use super::super::virtual_machine::is_absolute_acp_working_directory;
use super::errors::ProtocolFailure;
use serde_json::{Map, Value};
use std::path::Path;
use uuid::Uuid;

#[derive(Clone, Debug)]
pub(super) struct ProtocolConfig {
    pub(super) prompt: String,
    pub(super) requested_session_id: String,
    pub(super) native_session_key: Option<String>,
    pub(super) cwd: String,
    pub(super) reasoning_effort: Option<String>,
    pub(super) turn_id: String,
    pub(super) mcp_servers: Vec<Value>,
}

impl ProtocolConfig {
    pub(super) fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        Self::from_params_with_local_mcp(params, prompt, session_id, cwd, true)
    }

    pub(super) fn from_params_without_local_mcp(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        Self::from_params_with_local_mcp(params, prompt, session_id, cwd, false)
    }

    fn from_params_with_local_mcp(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
        include_local_mcp: bool,
    ) -> Result<Self, ProtocolFailure> {
        if prompt.trim().is_empty() {
            return Err(ProtocolFailure::new(
                "openclaw_empty_prompt",
                "OpenClaw requires a non-empty message.",
                "request/validate",
            ));
        }
        if params
            .get("privateInstructions")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
        {
            return Err(ProtocolFailure::new(
                "openclaw_acp_private_instructions_unsupported",
                "OpenClaw ACP does not expose a private instruction channel.",
                "capability/private-instructions",
            ));
        }
        if text_param(params, &["model", "modelId"]).is_some() {
            return Err(ProtocolFailure::new(
                "openclaw_acp_model_override_unsupported",
                "OpenClaw ACP does not expose native model selection.",
                "capability/model",
            ));
        }
        if explicit_value(params, &["sandbox", "sandboxMode"]).is_some() {
            return Err(ProtocolFailure::new(
                "openclaw_acp_sandbox_override_unsupported",
                "OpenClaw ACP does not expose a per-turn sandbox override.",
                "capability/sandbox",
            ));
        }
        if explicit_value(params, &["approvalPolicy", "approval_policy"]).is_some() {
            return Err(ProtocolFailure::new(
                "openclaw_acp_approval_override_unsupported",
                "OpenClaw ACP approvals require an explicit client approval response.",
                "capability/approval",
            ));
        }
        let reasoning_effort = text_param(params, &["reasoningEffort", "reasoning_effort"]);
        if reasoning_effort.as_deref().is_some_and(|value| {
            !matches!(
                value,
                "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "adaptive" | "max"
            )
        }) {
            return Err(ProtocolFailure::new(
                "openclaw_acp_invalid_thought_level",
                "The requested OpenClaw thought level is not supported.",
                "request/validate",
            ));
        }
        let cwd = cwd
            .filter(|path| is_absolute_acp_working_directory(path))
            .map(|path| path.to_string_lossy().to_string())
            .ok_or_else(|| {
                ProtocolFailure::new(
                    "openclaw_acp_absolute_cwd_required",
                    "OpenClaw ACP requires an absolute working directory.",
                    "request/validate",
                )
            })?;
        let requested_session_id = session_id.trim().to_string();
        let runtime_agent_id = text_param(
            params,
            &["openclawAgentId", "runtimeAgentId", "targetAgentId"],
        );
        let normalized_runtime_agent_id = runtime_agent_id.as_deref().map(normalize_agent_id);
        if runtime_agent_id.is_some()
            && normalized_runtime_agent_id
                .as_deref()
                .is_none_or(str::is_empty)
        {
            return Err(ProtocolFailure::new(
                "openclaw_acp_invalid_agent_id",
                "The requested OpenClaw agent identifier is invalid.",
                "request/validate",
            ));
        }
        let explicit_native_session_key = text_param(
            params,
            &["sessionKey", "nativeSessionKey", "openclawSessionKey"],
        );
        if !requested_session_id.is_empty()
            && explicit_native_session_key
                .as_deref()
                .is_some_and(|key| key != requested_session_id)
        {
            return Err(ProtocolFailure::new(
                "openclaw_acp_conflicting_session_id",
                "The requested OpenClaw conversation identifiers do not match.",
                "request/validate",
            ));
        }
        let native_session_key = explicit_native_session_key
            .or_else(|| (!requested_session_id.is_empty()).then(|| requested_session_id.clone()))
            .or_else(|| {
                normalized_runtime_agent_id
                    .map(|agent_id| format!("agent:{agent_id}:acp:{}", Uuid::new_v4()))
            });
        let mcp_servers = if include_local_mcp {
            crate::domain::collaboration_plugin::acp_servers_for_runtime("openclaw").map_err(
                |_| {
                    ProtocolFailure::new(
                        "openclaw_acp_mcp_registration_invalid",
                        "The optional MCP registration could not be validated safely.",
                        "session/mcp",
                    )
                },
            )?
        } else {
            Vec::new()
        };
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id,
            native_session_key,
            cwd,
            reasoning_effort,
            turn_id: Uuid::new_v4().to_string(),
            mcp_servers,
        })
    }

    pub(super) fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty()
    }

    pub(super) fn session_meta(&self) -> Option<Map<String, Value>> {
        self.native_session_key.as_ref().map(|key| {
            let mut meta = Map::new();
            meta.insert("sessionKey".into(), Value::String(key.clone()));
            meta.insert("requireExisting".into(), Value::Bool(self.is_resume()));
            meta
        })
    }
}

pub(super) fn explicit_value<'a>(params: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter()
        .find_map(|key| params.get(*key))
        .filter(|value| !value.is_null())
}

pub(super) fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

pub(super) fn normalize_agent_id(value: &str) -> String {
    let normalized = value
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
                character
            } else {
                '-'
            }
        })
        .collect::<String>();
    normalized.trim_matches('-').to_string()
}
