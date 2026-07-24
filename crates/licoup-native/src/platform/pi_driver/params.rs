use super::errors::ProtocolFailure;
use super::sessions::resolve_session_path;
use serde_json::Value;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub(super) struct ProtocolConfig {
    pub(super) prompt: String,
    pub(super) requested_session_id: String,
    pub(super) resume_session_path: Option<PathBuf>,
    pub(super) cwd: String,
    pub(super) model: Option<String>,
    pub(super) model_provider: Option<String>,
    pub(super) model_id: Option<String>,
    pub(super) thinking_level: Option<String>,
    pub(super) turn_id: String,
}

impl ProtocolConfig {
    pub(super) fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        if prompt.trim().is_empty() {
            return Err(ProtocolFailure::new(
                "pi_empty_prompt",
                "Pi Agent requires a non-empty message.",
                "request/validate",
            ));
        }
        if explicit_value(params, &["sandbox", "sandboxMode"]).is_some() {
            return Err(ProtocolFailure::new(
                "pi_sandbox_override_unsupported",
                "Pi RPC does not expose a per-turn sandbox override.",
                "capability/sandbox",
            ));
        }
        if explicit_value(params, &["approvalPolicy", "approval_policy"]).is_some() {
            return Err(ProtocolFailure::new(
                "pi_approval_override_unsupported",
                "Pi RPC approvals require an explicit client UI response.",
                "capability/approval",
            ));
        }
        let thinking_level =
            text_param(params, &["reasoningEffort", "reasoning_effort", "thinking"]);
        if thinking_level.as_deref().is_some_and(|value| {
            !matches!(
                value,
                "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max"
            )
        }) {
            return Err(ProtocolFailure::new(
                "pi_invalid_thinking_level",
                "Pi Agent does not support the requested thinking level.",
                "request/validate",
            ));
        }
        let cwd = cwd
            .filter(|path| path.is_absolute())
            .map(|path| path.to_string_lossy().to_string())
            .ok_or_else(|| {
                ProtocolFailure::new(
                    "pi_absolute_cwd_required",
                    "Pi Agent requires an absolute working directory.",
                    "request/validate",
                )
            })?;
        let requested_session_id = session_id.trim().to_string();
        let resume_session_path = if requested_session_id.is_empty() {
            None
        } else {
            Some(resolve_session_path(&requested_session_id)?)
        };
        let model = text_param(params, &["model", "modelId"]);
        let (model_provider, model_id) = match model.as_deref() {
            Some(value) => {
                let Some((provider, model_id)) = value.split_once('/') else {
                    return Err(ProtocolFailure::new(
                        "pi_model_provider_required",
                        "Pi RPC model overrides require provider/model identity.",
                        "capability/model",
                    ));
                };
                if provider.trim().is_empty() || model_id.trim().is_empty() {
                    return Err(ProtocolFailure::new(
                        "pi_model_provider_required",
                        "Pi RPC model overrides require provider/model identity.",
                        "capability/model",
                    ));
                }
                (
                    Some(provider.trim().to_string()),
                    Some(model_id.trim().to_string()),
                )
            }
            None => (None, None),
        };
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id,
            resume_session_path,
            cwd,
            model,
            model_provider,
            model_id,
            thinking_level,
            turn_id: Uuid::new_v4().to_string(),
        })
    }

    pub(super) fn is_resume(&self) -> bool {
        self.resume_session_path.is_some()
    }
}

fn explicit_value<'a>(params: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter()
        .find_map(|key| params.get(*key))
        .filter(|value| !value.is_null())
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}
