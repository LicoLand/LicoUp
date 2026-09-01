use super::super::acp_driver_runtime::ProtocolFailure;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct ServeTurnConfig {
    pub(super) prompt: String,
    pub(super) private_instructions: Option<String>,
    pub(super) requested_session_id: String,
    pub(super) cwd: String,
    pub(super) model: Option<String>,
    pub(super) runtime_agent: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) mode: Option<String>,
    pub(super) allow_all: Option<bool>,
}

impl ServeTurnConfig {
    pub(super) fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        let cwd = cwd
            .map(Path::to_path_buf)
            .or_else(|| {
                params
                    .get("cwd")
                    .or_else(|| params.get("workingDirectory"))
                    .and_then(Value::as_str)
                    .map(PathBuf::from)
            })
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")));
        if !cwd.is_absolute() {
            return Err(ProtocolFailure::new(
                "acp_working_directory_invalid",
                "ACP conversation sessions require an absolute working directory.",
                "initialize",
            ));
        }
        Ok(Self {
            prompt: prompt.to_string(),
            private_instructions: text_setting(params, &["privateInstructions"]),
            requested_session_id: session_id.trim().to_string(),
            cwd: cwd.to_string_lossy().into_owned(),
            model: text_setting(params, &["model"]),
            runtime_agent: text_setting(params, &["agent", "runtimeAgent"]),
            reasoning_effort: text_setting(params, &["reasoningEffort", "reasoning"]),
            mode: text_setting(params, &["mode"]),
            allow_all: params.get("allowAll").and_then(Value::as_bool),
        })
    }

    pub(super) fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty()
    }
}

fn text_setting(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        params
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    })
}

pub(super) fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}
