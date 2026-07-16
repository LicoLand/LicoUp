use serde_json::{Map, Value};

use super::antigravity::has_user_request_tag;
use super::generated_context::generated_control_text;
use super::semantic::looks_like_delegated_agent_prompt;

const MAX_TEXT_EXTRACTION_DEPTH: usize = 16;
const MAX_EMBEDDED_JSON_DISCOVERY_DEPTH: usize = 6;

pub(in crate::domain::conversation::history) fn extract_text(value: &Value) -> Option<String> {
    extract_text_at_depth(value, 0)
}

fn extract_text_at_depth(value: &Value, depth: usize) -> Option<String> {
    if depth > MAX_TEXT_EXTRACTION_DEPTH {
        return None;
    }
    match value {
        Value::String(text) => extract_text_from_string(text, depth),
        Value::Array(items) => {
            let parts = items
                .iter()
                .filter_map(|item| extract_text_at_depth(item, depth + 1))
                .filter(|text| !text.trim().is_empty())
                .collect::<Vec<_>>();
            (!parts.is_empty()).then(|| parts.join("\n"))
        }
        Value::Object(object) => {
            if structured_content_object_is_tool_or_metadata(object) {
                return None;
            }
            if structured_content_object_is_text(object) {
                return object
                    .get("text")
                    .or_else(|| object.get("content"))
                    .and_then(|value| extract_text_at_depth(value, depth + 1));
            }
            for key in [
                "text", "content", "message", "messages", "prompt", "response", "answer",
                "summary", "value", "parts", "items", "turns",
            ] {
                if let Some(text) = object
                    .get(key)
                    .and_then(|value| extract_text_at_depth(value, depth + 1))
                {
                    if !text.trim().is_empty() {
                        return Some(text);
                    }
                }
            }
            None
        }
        _ => None,
    }
}

fn structured_content_object_is_tool_or_metadata(object: &Map<String, Value>) -> bool {
    let kind = object
        .get("type")
        .or_else(|| object.get("kind"))
        .or_else(|| object.get("role"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        kind.as_str(),
        "tool_result"
            | "tool-use"
            | "tool_use"
            | "tool"
            | "function_call"
            | "function_call_output"
            | "input_json_delta"
            | "thinking"
            | "redacted_thinking"
            | "image"
            | "image_url"
            | "document"
            | "attachment"
            | "metadata"
            | "system"
    )
}

fn structured_content_object_is_text(object: &Map<String, Value>) -> bool {
    let kind = object
        .get("type")
        .or_else(|| object.get("kind"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        kind.as_str(),
        "text" | "input_text" | "output_text" | "markdown"
    )
}

fn extract_text_from_string(text: &str, depth: usize) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.is_empty()
        || (generated_control_text(trimmed)
            && !looks_like_delegated_agent_prompt(trimmed)
            && !has_user_request_tag(trimmed))
    {
        return None;
    }
    if depth < 4 {
        if let Some(value) = parse_embedded_json_text(trimmed) {
            if value
                .as_object()
                .map(structured_content_object_is_tool_or_metadata)
                .unwrap_or(false)
            {
                return None;
            }
            if let Some(decoded) = extract_text_at_depth(&value, depth + 1) {
                let decoded = decoded.trim().to_string();
                if !decoded.is_empty()
                    && (!generated_control_text(&decoded)
                        || looks_like_delegated_agent_prompt(&decoded)
                        || has_user_request_tag(&decoded))
                {
                    return Some(decoded);
                }
            }
        }
    }
    Some(text.to_string())
}

fn parse_embedded_json_text(text: &str) -> Option<Value> {
    let trimmed = text.trim();
    let structured = (trimmed.starts_with('{') && trimmed.ends_with('}'))
        || (trimmed.starts_with('[') && trimmed.ends_with(']'));
    if !structured {
        return None;
    }
    let value = serde_json::from_str::<Value>(trimmed).ok()?;
    embedded_json_may_hold_message_text(&value, 0).then_some(value)
}

fn embedded_json_may_hold_message_text(value: &Value, depth: usize) -> bool {
    if depth > MAX_EMBEDDED_JSON_DISCOVERY_DEPTH {
        return false;
    }
    match value {
        Value::Array(items) => items
            .iter()
            .any(|item| embedded_json_may_hold_message_text(item, depth + 1)),
        Value::Object(object) => {
            object.keys().any(|key| {
                matches!(
                    key.as_str(),
                    "text"
                        | "content"
                        | "message"
                        | "messages"
                        | "prompt"
                        | "response"
                        | "answer"
                        | "summary"
                        | "value"
                        | "parts"
                        | "items"
                        | "turns"
                )
            }) || object
                .values()
                .any(|child| embedded_json_may_hold_message_text(child, depth + 1))
        }
        _ => false,
    }
}

pub(in crate::domain::conversation::history) fn extract_role(value: &Value) -> String {
    if let Some(type_code) = value.get("type").and_then(Value::as_i64) {
        match type_code {
            1 => return "user".to_string(),
            0 | 2 => return "agent".to_string(),
            _ => {}
        }
    }
    let role = find_string(value, &["role", "author", "speaker", "type", "source"])
        .unwrap_or_else(|| "system".to_string())
        .to_ascii_lowercase();
    if role.contains("user") || role.contains("human") || role == "1" {
        "user".to_string()
    } else if role.contains("assistant")
        || role.contains("agent")
        || role.contains("model")
        || role.contains("ai")
        || role == "0"
        || role == "2"
    {
        "agent".to_string()
    } else if role.contains("tool") {
        "tool".to_string()
    } else {
        role
    }
}

pub(in crate::domain::conversation::history) fn extract_timestamp(value: &Value) -> Option<String> {
    find_string(
        value,
        &[
            "createdAt",
            "updatedAt",
            "timestamp",
            "time",
            "date",
            "created_at",
            "updated_at",
        ],
    )
}

pub(in crate::domain::conversation::history) fn find_string(
    value: &Value,
    keys: &[&str],
) -> Option<String> {
    find_string_at_depth(value, keys, 0)
}

fn find_string_at_depth(value: &Value, keys: &[&str], depth: usize) -> Option<String> {
    if depth > MAX_TEXT_EXTRACTION_DEPTH {
        return None;
    }
    let object = value.as_object()?;
    for key in keys {
        if let Some(text) = object.get(*key).and_then(Value::as_str) {
            return Some(text.to_string());
        }
        if let Some(number) = object.get(*key).and_then(Value::as_i64) {
            return Some(number.to_string());
        }
    }
    object
        .get("message")
        .and_then(|message| find_string_at_depth(message, keys, depth + 1))
}

pub(in crate::domain::conversation::history) fn extract_native_session_id(
    value: &Value,
) -> Option<String> {
    find_string(
        value,
        &[
            "sessionId",
            "session_id",
            "conversationId",
            "conversation_id",
            "chatId",
            "chat_id",
            "threadId",
            "thread_id",
            "sessionKey",
            "session_key",
        ],
    )
    .filter(|value| !value.trim().is_empty())
}
