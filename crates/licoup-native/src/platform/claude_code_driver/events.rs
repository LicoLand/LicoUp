use serde_json::{Value, json};

pub(super) fn partial_text_delta(message: &Value) -> Option<&str> {
    (message.get("type").and_then(Value::as_str) == Some("stream_event"))
        .then(|| message.pointer("/event/delta/text").and_then(Value::as_str))
        .flatten()
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
