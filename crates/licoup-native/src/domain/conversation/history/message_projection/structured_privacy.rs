use std::sync::OnceLock;

use regex::Regex;
use serde_json::Value;

use super::semantic::{HistoryMessageKind, normalize_history_message_semantic};

const MAX_STRUCTURED_EVENT_TEXT_CHARS: usize = 1_200;
const MAX_REASONING_SUMMARY_DEPTH: usize = 3;

pub(super) fn structured_event_text(
    kind: HistoryMessageKind,
    value: &Value,
    fallback: &str,
) -> String {
    if matches!(
        kind,
        HistoryMessageKind::Reasoning | HistoryMessageKind::Metadata | HistoryMessageKind::ToolCall
    ) {
        return fallback.to_string();
    }
    structured_event_detail_candidate(value)
        .and_then(|text| sanitize_structured_event_text(&text))
        .unwrap_or_else(|| fallback.to_string())
}

/// Only provider-owned summary fields are eligible for display. Generic reasoning or thinking
/// fields can contain chain-of-thought and remain redacted even when they look human-readable.
pub(super) fn structured_reasoning_summary(value: &Value) -> Option<String> {
    for key in ["summary", "reasoningSummary", "reasoning_summary"] {
        let Some(candidate) = value.get(key) else {
            continue;
        };
        if let Some(summary) = structured_reasoning_summary_value(candidate, 0) {
            return Some(summary);
        }
    }
    None
}

pub(super) fn structured_reasoning_summary_value(value: &Value, depth: usize) -> Option<String> {
    if depth > MAX_REASONING_SUMMARY_DEPTH {
        return None;
    }
    match value {
        Value::String(text) => (!text.trim().is_empty()).then(|| text.trim().to_string()),
        Value::Array(items) => {
            let summaries = items
                .iter()
                .filter_map(|item| structured_reasoning_summary_value(item, depth + 1))
                .collect::<Vec<_>>();
            (!summaries.is_empty()).then(|| summaries.join("\n"))
        }
        Value::Object(object) => {
            if let Some(kind) = object
                .get("type")
                .or_else(|| object.get("kind"))
                .and_then(Value::as_str)
            {
                let normalized = normalize_history_message_semantic(kind);
                if !matches!(
                    normalized.as_str(),
                    "summary" | "summary-text" | "reasoning-summary" | "text"
                ) {
                    return None;
                }
            }
            ["text", "content", "summary"]
                .iter()
                .find_map(|key| object.get(*key))
                .and_then(|candidate| structured_reasoning_summary_value(candidate, depth + 1))
        }
        _ => None,
    }
}

fn structured_event_detail_candidate(value: &Value) -> Option<String> {
    for key in [
        "error", "reason", "message", "summary", "text", "output", "result", "content",
    ] {
        let Some(candidate) = value.get(key) else {
            continue;
        };
        if let Some(text) = candidate.as_str() {
            if !text.trim().is_empty() {
                return Some(text.to_string());
            }
        }
        if key == "error" {
            if let Some(text) = candidate.get("message").and_then(Value::as_str) {
                if !text.trim().is_empty() {
                    return Some(text.to_string());
                }
            }
        }
    }
    None
}

pub(super) fn sanitize_structured_label(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.chars().count() > 96
        || trimmed
            .chars()
            .any(|character| matches!(character, '\n' | '\r' | '/' | '\\' | '{' | '}' | '[' | ']'))
        || secret_assignment_regex().is_match(trimmed)
        || opaque_value_regex().is_match(trimmed)
    {
        return None;
    }
    Some(trimmed.to_string())
}

pub(super) fn sanitize_structured_event_text(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || looks_like_raw_structured_payload(trimmed) {
        return None;
    }
    let redacted = bearer_regex().replace_all(trimmed, "Bearer [redacted]");
    let redacted = secret_assignment_regex().replace_all(&redacted, "$1: [redacted]");
    let redacted = local_path_regex().replace_all(&redacted, "[local path hidden]");
    let redacted = relative_path_regex().replace_all(&redacted, "$1[local path hidden]");
    let redacted = opaque_value_regex().replace_all(&redacted, "[opaque value hidden]");
    let redacted = redacted.trim();
    if redacted.is_empty() {
        return None;
    }
    let mut text = redacted
        .chars()
        .take(MAX_STRUCTURED_EVENT_TEXT_CHARS)
        .collect::<String>();
    if redacted.chars().count() > MAX_STRUCTURED_EVENT_TEXT_CHARS {
        text.push_str("\n…");
    }
    Some(text)
}

pub(super) fn looks_like_raw_structured_payload(value: &str) -> bool {
    let trimmed = value.trim();
    let candidate = trimmed
        .strip_prefix("```json")
        .or_else(|| trimmed.strip_prefix("```JSON"))
        .map(|text| {
            text.trim()
                .strip_suffix("```")
                .unwrap_or(text.trim())
                .trim()
        })
        .unwrap_or(trimmed);
    if candidate.contains("{\"") || candidate.contains("[{") {
        return true;
    }
    if !((candidate.starts_with('{') && candidate.ends_with('}'))
        || (candidate.starts_with('[') && candidate.ends_with(']')))
    {
        return false;
    }
    serde_json::from_str::<Value>(candidate)
        .map(|value| value.is_object() || value.is_array())
        .unwrap_or(true)
}

fn bearer_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"(?i)\bbearer\s+[a-z0-9._~+\-/]+=*").expect("valid bearer regex")
    })
}

fn secret_assignment_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r#"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|password|secret|cookie|credential)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
        )
        .expect("valid secret assignment regex")
    })
}

fn local_path_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(
            r#"(?i)(?:file://)?/(?:users|home|private|tmp|workspace|workspaces|volumes|var/folders|opt)/[^\s\"'<>]*|[a-z]:\\[^\s\"'<>]*|~[/\\][^\s\"'<>]*"#,
        )
        .expect("valid local path regex")
    })
}

fn relative_path_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r#"(?i)(^|[\s(\"'=])((?:\.{1,2}[/\\])?[a-z0-9._-]+(?:[/\\][a-z0-9._-]+)+)"#)
            .expect("valid relative local path regex")
    })
}

fn opaque_value_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| Regex::new(r"\b[a-zA-Z0-9_-]{40,}\b").expect("valid opaque value regex"))
}
