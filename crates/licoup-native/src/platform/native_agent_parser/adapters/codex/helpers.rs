use serde_json::Value;

pub(super) fn response_is_error(message: &Value) -> bool {
    message.get("error").is_some()
}

pub(super) fn request_id_matches(message: &Value, expected: i64) -> bool {
    message.get("id").is_some_and(|id| {
        id.as_i64() == Some(expected)
            || id.as_str().and_then(|value| value.parse::<i64>().ok()) == Some(expected)
    })
}

pub(super) fn matches_current_ids(
    params: &Value,
    thread_id: Option<&str>,
    turn_id: Option<&str>,
) -> bool {
    params.get("threadId").and_then(Value::as_str) == thread_id
        && params.get("turnId").and_then(Value::as_str) == turn_id
}

pub(super) fn final_agent_message(items: &[Value]) -> Option<String> {
    items.iter().rev().find_map(|item| {
        (item.get("type").and_then(Value::as_str) == Some("agentMessage"))
            .then(|| {
                item.get("text")
                    .and_then(Value::as_str)
                    .filter(|text| !text.trim().is_empty())
                    .map(str::to_string)
            })
            .flatten()
    })
}
