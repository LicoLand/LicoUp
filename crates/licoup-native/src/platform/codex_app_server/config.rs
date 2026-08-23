use super::model::ProtocolFailure;
use serde_json::Value;
use std::path::Path;

pub(in crate::platform) const MAX_IMAGE_ATTACHMENTS: usize = 4;
pub(in crate::platform) const SUPPORTED_IMAGE_MEDIA_TYPES: &[&str] =
    &["image/png", "image/jpeg", "image/gif", "image/webp"];

/// Canonical ordered local-image input for `turn/start`. The runtime adapter
/// already validated the files; this config parse only maps the request shape.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(in crate::platform) struct LocalImageInput {
    pub(in crate::platform) name: String,
    pub(in crate::platform) media_type: String,
    pub(in crate::platform) path: String,
}

#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolConfig {
    pub(in crate::platform) prompt: String,
    pub(in crate::platform) private_instructions: Option<String>,
    pub(in crate::platform) requested_session_id: String,
    pub(in crate::platform) session_path: Option<String>,
    pub(in crate::platform) local_images: Vec<LocalImageInput>,
    pub(in crate::platform) cwd: Option<String>,
    pub(in crate::platform) model: Option<String>,
    pub(in crate::platform) reasoning_effort: Option<String>,
    pub(in crate::platform) sandbox: Option<Value>,
    pub(in crate::platform) approval_policy: Option<Value>,
}

impl ProtocolConfig {
    pub(in crate::platform) fn from_params(
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
        let local_images = parse_local_images(params)?;

        Ok(Self {
            prompt: prompt.to_string(),
            private_instructions: text_param(
                params,
                &["privateInstructions", "private_instructions"],
            ),
            requested_session_id,
            session_path,
            local_images,
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

    pub(in crate::platform) fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty() || self.session_path.is_some()
    }
}

fn parse_local_images(params: &Value) -> Result<Vec<LocalImageInput>, ProtocolFailure> {
    let Some(raw) = params.get("attachments") else {
        return Ok(Vec::new());
    };
    if raw.is_null() {
        return Ok(Vec::new());
    }
    let Some(items) = raw.as_array() else {
        return Err(attachment_failure());
    };
    if items.len() > MAX_IMAGE_ATTACHMENTS {
        return Err(attachment_failure());
    }
    let mut images = Vec::with_capacity(items.len());
    for item in items {
        let Some(object) = item.as_object() else {
            return Err(attachment_failure());
        };
        for key in object.keys() {
            if !matches!(key.as_str(), "id" | "name" | "mediaType" | "path") {
                return Err(attachment_failure());
            }
        }
        let name = required_image_field(object, "name")?;
        let media_type = required_image_field(object, "mediaType")?;
        let path = required_image_field(object, "path")?;
        if !SUPPORTED_IMAGE_MEDIA_TYPES.contains(&media_type.as_str()) {
            return Err(attachment_failure());
        }
        images.push(LocalImageInput {
            name,
            media_type,
            path,
        });
    }
    Ok(images)
}

fn required_image_field(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<String, ProtocolFailure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(attachment_failure)
}

fn attachment_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "codex_invalid_local_image",
        "The requested Codex image attachment is not valid.",
        "turn/configure",
    )
}

pub(in crate::platform) fn spark_default_reasoning_effort(model: Option<&str>) -> Option<String> {
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
