use serde_json::{Value, json};

pub(super) fn partial_text_delta(message: &Value) -> Option<&str> {
    (message.get("type").and_then(Value::as_str) == Some("stream_event"))
        .then(|| message.pointer("/event/delta/text").and_then(Value::as_str))
        .flatten()
}

pub(super) fn processing_evidence_kind(message: &Value) -> Option<&'static str> {
    let message_type = message.get("type").and_then(Value::as_str)?;
    if message_type == "assistant" {
        let blocks = message
            .pointer("/message/content")
            .and_then(Value::as_array)?;
        if blocks.iter().any(|block| {
            matches!(
                block.get("type").and_then(Value::as_str),
                Some("tool_use" | "server_tool_use")
            )
        }) {
            return Some("tool");
        }
        if blocks.iter().any(|block| {
            matches!(
                block.get("type").and_then(Value::as_str),
                Some("thinking" | "redacted_thinking")
            )
        }) {
            return Some("reasoning");
        }
    }
    if message_type == "stream_event" {
        let event_type = message.pointer("/event/type").and_then(Value::as_str);
        let block_type = message
            .pointer("/event/content_block/type")
            .and_then(Value::as_str);
        let delta_type = message.pointer("/event/delta/type").and_then(Value::as_str);
        if matches!(block_type, Some("tool_use" | "server_tool_use")) {
            return Some("tool");
        }
        if matches!(block_type, Some("thinking" | "redacted_thinking"))
            || matches!(delta_type, Some("thinking_delta" | "signature_delta"))
        {
            return Some("reasoning");
        }
        if matches!(event_type, Some("message_start" | "content_block_start")) {
            return Some("progress");
        }
    }
    None
}

/// Project only user-visible assistant text and bounded status metadata.
/// Tool input, message bodies, paths, identifiers, and vendor metadata stay local.
pub(super) fn project_event(message: &Value) -> Option<Value> {
    match message.get("type").and_then(Value::as_str)? {
        "stream_event" => partial_text_delta(message).map(|text| {
            json!({
                "type": "stream_event",
                "event": {
                    "type": "content_block_delta",
                    "delta": {"type": "text_delta", "text": text}
                }
            })
        }),
        "assistant" => Some(json!({"type": "assistant", "contentAvailable": true})),
        "result" => Some(json!({
            "type": "result",
            "subtype": message.get("subtype").and_then(Value::as_str).unwrap_or("unknown"),
            "isError": message.get("is_error").and_then(Value::as_bool).unwrap_or(false)
        })),
        "system" => Some(json!({
            "type": "system",
            "subtype": message.get("subtype").and_then(Value::as_str).unwrap_or("unknown")
        })),
        "control_request" => Some(json!({
            "type": "control_request",
            "subtype": message.pointer("/request/subtype").and_then(Value::as_str).unwrap_or("unknown")
        })),
        _ => None,
    }
}
