use serde_json::Value;

pub(in crate::platform) fn partial_text_delta(message: &Value) -> Option<&str> {
    (message.get("type").and_then(Value::as_str) == Some("stream_event"))
        .then(|| message.pointer("/event/delta/text").and_then(Value::as_str))
        .flatten()
}

pub(in crate::platform) fn processing_evidence_kind(message: &Value) -> Option<&'static str> {
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

/// The name of the first tool the assistant used in this message (for example
/// `Bash`), so the client can label the evidence step instead of a bare
/// `tool`. Bounded to the tool name only; tool input stays local.
pub(super) fn processing_tool_name(message: &Value) -> Option<&str> {
    let blocks = message
        .pointer("/message/content")
        .and_then(Value::as_array)?;
    for block in blocks {
        if matches!(
            block.get("type").and_then(Value::as_str),
            Some("tool_use" | "server_tool_use")
        ) {
            let name = block.get("name").and_then(Value::as_str)?;
            if !name.trim().is_empty() {
                return Some(name);
            }
        }
    }
    None
}
