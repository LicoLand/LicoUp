use super::MAX_OUTPUT_BYTES;
use serde_json::Value;
use std::env;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) const MAX_IMAGE_ATTACHMENTS: usize = 4;
pub(super) const MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE: u64 = 4 * 1024 * 1024;
pub(super) const MAX_IMAGE_ATTACHMENT_BYTES_TOTAL: u64 = 16 * 1024 * 1024;

pub(super) const SUPPORTED_IMAGE_MEDIA_TYPES: &[&str] =
    &["image/png", "image/jpeg", "image/gif", "image/webp"];

/// Canonical typed local-image input after shape validation. Paths are never
/// logged or returned by callers; this struct exists only for admission and
/// protocol mapping.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct LocalImageInput {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) media_type: String,
    pub(super) path: String,
}

/// Why attachment shape validation failed, mapped by the caller to a stable
/// redacted `RuntimeAdapterError`. No path or content is carried here.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum AttachmentShapeFailure {
    NotArray,
    ListExceeded,
    NotObject,
    UnknownField,
    FieldMissing,
    MediaUnsupported,
    RemoteUrl,
}

pub(super) fn attachment_media_type_supported(media_type: &str) -> bool {
    SUPPORTED_IMAGE_MEDIA_TYPES.contains(&media_type)
}

/// Parses the optional `attachments` request array into canonical local-image
/// inputs. Absent or null means no attachments. Returns the failure reason for
/// any invalid shape; the caller maps it to the stable adapter error.
pub(super) fn parse_attachments(
    params: &Value,
) -> Result<Vec<LocalImageInput>, AttachmentShapeFailure> {
    let Some(raw) = params.get("attachments") else {
        return Ok(Vec::new());
    };
    if raw.is_null() {
        return Ok(Vec::new());
    }
    let Some(items) = raw.as_array() else {
        return Err(AttachmentShapeFailure::NotArray);
    };
    if items.len() > MAX_IMAGE_ATTACHMENTS {
        return Err(AttachmentShapeFailure::ListExceeded);
    }
    let mut parsed = Vec::with_capacity(items.len());
    for item in items {
        parsed.push(parse_attachment_item(item)?);
    }
    Ok(parsed)
}

fn parse_attachment_item(item: &Value) -> Result<LocalImageInput, AttachmentShapeFailure> {
    let Some(object) = item.as_object() else {
        return Err(AttachmentShapeFailure::NotObject);
    };
    for key in object.keys() {
        if !matches!(key.as_str(), "id" | "name" | "mediaType" | "path") {
            return Err(AttachmentShapeFailure::UnknownField);
        }
    }
    let id = required_attachment_field(object, "id")?;
    let name = required_attachment_field(object, "name")?;
    let media_type = required_attachment_field(object, "mediaType")?;
    let path = required_attachment_field(object, "path")?;
    if !attachment_media_type_supported(&media_type) {
        return Err(AttachmentShapeFailure::MediaUnsupported);
    }
    if path.contains("://") {
        return Err(AttachmentShapeFailure::RemoteUrl);
    }
    Ok(LocalImageInput {
        id,
        name,
        media_type,
        path,
    })
}

fn required_attachment_field(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<String, AttachmentShapeFailure> {
    object
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or(AttachmentShapeFailure::FieldMissing)
}

pub(super) fn binary_param(params: &Value, fallback: &str) -> String {
    text_param(params, &["binary", "binaryPath", "executable"])
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| fallback.to_string())
}

pub(super) fn codex_binary_param(params: &Value) -> String {
    if let Some(binary) = text_param(params, &["binary", "binaryPath", "executable"])
        .filter(|value| !value.is_empty())
    {
        return binary;
    }
    if let Ok(binary) = env::var("CODEX_CLI_PATH")
        && !binary.trim().is_empty()
    {
        return binary;
    }
    if cfg!(windows)
        && let Ok(profile) = env::var("USERPROFILE")
    {
        let candidate = Path::new(&profile)
            .join(".codex")
            .join(".sandbox-bin")
            .join("codex.exe");
        if candidate.is_file() {
            return candidate.to_string_lossy().to_string();
        }
    }
    "codex".to_string()
}

pub(super) fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(|value| value.trim().to_string())
}

pub(super) fn message_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::to_string)
}

pub(super) fn u64_param(params: &Value, key: &str, fallback: u64) -> u64 {
    params
        .get(key)
        .and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.trim().parse().ok()))
        })
        .unwrap_or(fallback)
}

/// An explicitly configured output budget. Absent means the client imposes
/// no limit: LicoUp waits for the agent to finish and streams whatever it
/// produces. Explicit values stay bounded by the public contract ceiling.
pub(super) fn optional_output_param(params: &Value, key: &str) -> Option<usize> {
    params.get(key).and_then(|value| {
        let parsed = value
            .as_u64()
            .or_else(|| value.as_str().and_then(|text| text.trim().parse().ok()))?;
        usize::try_from(parsed)
            .unwrap_or(MAX_OUTPUT_BYTES)
            .clamp(1, MAX_OUTPUT_BYTES)
            .into()
    })
}

pub(super) fn bounded_output_param(params: &Value, key: &str, fallback: usize) -> usize {
    usize::try_from(u64_param(params, key, fallback as u64))
        .unwrap_or(MAX_OUTPUT_BYTES)
        .clamp(1, MAX_OUTPUT_BYTES)
}

pub(super) fn timestamp() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    millis.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn explicit_output_budget_preserves_the_public_sixty_four_mibibyte_bound() {
        assert_eq!(MAX_OUTPUT_BYTES, 64 * 1024 * 1024);
        assert_eq!(
            optional_output_param(
                &json!({"maxStdoutBytes": MAX_OUTPUT_BYTES}),
                "maxStdoutBytes",
            ),
            Some(MAX_OUTPUT_BYTES)
        );
        assert_eq!(
            optional_output_param(
                &json!({"maxStdoutBytes": MAX_OUTPUT_BYTES as u64 + 1}),
                "maxStdoutBytes",
            ),
            Some(MAX_OUTPUT_BYTES)
        );
    }

    #[test]
    fn absent_output_budget_means_unbounded() {
        assert_eq!(
            optional_output_param(&json!({}), "maxStdoutBytes"),
            None,
            "the client must not limit agent output when no explicit budget is set"
        );
    }
}
