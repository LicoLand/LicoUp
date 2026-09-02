use serde_json::Value;

pub(super) fn assistant_text(message: &Value) -> Option<String> {
    message
        .pointer("/message/content")
        .and_then(Value::as_array)
        .and_then(|blocks| {
            blocks.iter().find_map(|block| {
                (block.get("type").and_then(Value::as_str) == Some("text"))
                    .then(|| block.get("text").and_then(Value::as_str))
                    .flatten()
                    .map(str::to_string)
            })
        })
        .or_else(|| {
            message
                .get("result")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .or_else(|| {
            message
                .pointer("/content/text")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
}

pub(super) fn delta_text(message: &Value) -> Option<&str> {
    message
        .pointer("/event/delta/text")
        .and_then(Value::as_str)
        .or_else(|| message.pointer("/delta/text").and_then(Value::as_str))
        .or_else(|| {
            (message.get("type").and_then(Value::as_str) == Some("content_block_delta"))
                .then(|| message.pointer("/delta/text").and_then(Value::as_str))
                .flatten()
        })
}

pub(super) fn session_id(message: &Value) -> Option<&str> {
    message
        .get("session_id")
        .or_else(|| message.get("sessionId"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

pub(super) fn terminal_result(message: &Value) -> Option<&str> {
    if message.get("type").and_then(Value::as_str) != Some("result") {
        return None;
    }
    message
        .get("result")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

pub(super) fn is_error_result(message: &Value) -> bool {
    message
        .get("is_error")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || message
            .get("subtype")
            .and_then(Value::as_str)
            .is_some_and(|value| value != "success")
}
