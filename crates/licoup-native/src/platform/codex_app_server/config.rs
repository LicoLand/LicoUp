use super::model::ProtocolFailure;
use serde_json::Value;
use std::path::Path;

#[derive(Clone, Debug)]
pub(super) struct ProtocolConfig {
    pub(super) prompt: String,
    pub(super) requested_session_id: String,
    pub(super) session_path: Option<String>,
    pub(super) cwd: Option<String>,
    pub(super) model: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) sandbox: Option<Value>,
    pub(super) approval_policy: Option<Value>,
}

impl ProtocolConfig {
    pub(super) fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        let session_path = text_param(params, &["sessionPath", "sourcePath"]);
        let requested_session_id = if session_id.trim().is_empty() && session_path.is_some() {
            thread_id_from_session_path(session_path.as_deref().unwrap_or_default())
                .unwrap_or_default()
        } else {
            session_id.trim().to_string()
        };
        if session_path.is_some() && requested_session_id.is_empty() {
            return Err(ProtocolFailure::new(
                "codex_invalid_resume_target",
                "Codex could not identify the existing conversation to resume.",
                "thread/resume",
            ));
        }

        let sandbox = params
            .get("sandbox")
            .or_else(|| params.get("sandboxMode"))
            .filter(|value| !value.is_null())
            .cloned();
        if let Some(value) = sandbox.as_ref() {
            let valid = value.as_str().is_some_and(|value| {
                matches!(
                    value,
                    "read-only" | "workspace-write" | "danger-full-access"
                )
            });
            if !valid {
                return Err(ProtocolFailure::new(
                    "codex_invalid_sandbox",
                    "The requested Codex sandbox mode is not supported.",
                    "thread/configure",
                ));
            }
        }

        let model = text_param(params, &["model", "modelId"]);
        let reasoning_effort = text_param(params, &["reasoningEffort", "reasoning_effort"])
            .or_else(|| spark_default_reasoning_effort(model.as_deref()));

        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id,
            session_path,
            cwd: cwd.map(|path| path.to_string_lossy().to_string()),
            model,
            reasoning_effort,
            sandbox,
            approval_policy: params
                .get("approvalPolicy")
                .or_else(|| params.get("approval_policy"))
                .filter(|value| !value.is_null())
                .cloned(),
        })
    }

    pub(super) fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty() || self.session_path.is_some()
    }
}

pub(super) fn spark_default_reasoning_effort(model: Option<&str>) -> Option<String> {
    let model = model?.to_ascii_lowercase();
    model.contains("spark").then(|| "low".to_string())
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn thread_id_from_session_path(path: &str) -> Option<String> {
    let stem = Path::new(path).file_stem()?.to_str()?;
    stem.split(|character: char| !character.is_ascii_hexdigit() && character != '-')
        .flat_map(|part| part.as_bytes().windows(36))
        .filter_map(|window| std::str::from_utf8(window).ok())
        .find(|candidate| looks_like_uuid(candidate))
        .map(str::to_string)
}

fn looks_like_uuid(value: &str) -> bool {
    value.len() == 36
        && value
            .chars()
            .enumerate()
            .all(|(index, character)| match index {
                8 | 13 | 18 | 23 => character == '-',
                _ => character.is_ascii_hexdigit(),
            })
}
