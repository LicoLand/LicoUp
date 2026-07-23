//! Pi and GitHub Copilot native history parsers.

use super::*;

pub(crate) fn parse_pi_session(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
) -> Option<Value> {
    let raw = fs::read_to_string(path).ok()?;
    let mut native_session_id = path
        .file_stem()
        .and_then(|value| value.to_str())
        .and_then(|stem| stem.rsplit_once('_').map(|(_, id)| id.to_string()))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "pi-session".to_string());
    let mut title = None::<String>;
    let mut messages = Vec::<Value>::new();

    for (index, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        let entry_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match entry_type {
            "session" => {
                if let Some(session_id) = value
                    .get("id")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                {
                    native_session_id = session_id.to_string();
                }
            }
            "session_info" => {
                if let Some(name) = value
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                {
                    title = Some(name.to_string());
                }
            }
            "message" => {
                let Some(message) = value.get("message") else {
                    continue;
                };
                let first_projected = messages.len();
                let role = message
                    .get("role")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let normalized_role = match role {
                    "user" => "user",
                    "assistant" => "agent",
                    "toolResult" => "tool",
                    other if !other.is_empty() => other,
                    _ => continue,
                };
                if role == "assistant" {
                    if let Some(blocks) = message.get("content").and_then(Value::as_array) {
                        for (block_index, block) in blocks.iter().enumerate() {
                            let block_type =
                                block.get("type").and_then(Value::as_str).unwrap_or("");
                            if block_type == "thinking" {
                                if let Some(text) = block.get("thinking").and_then(Value::as_str) {
                                    if let Some(message) = plain_history_message(
                                        HistoryAdapter::Pi,
                                        path,
                                        index,
                                        block_index,
                                        "reasoning",
                                        text,
                                        extract_timestamp(&value),
                                    ) {
                                        messages.push(message);
                                    }
                                }
                                continue;
                            }
                            if block_type == "toolCall" {
                                messages.push(structured_history_message(
                                    HistoryAdapter::Pi,
                                    path,
                                    index,
                                    block_index,
                                    HistoryMessageKind::ToolCall,
                                    "tool",
                                    block,
                                    extract_timestamp(&value),
                                ));
                                continue;
                            }
                            if let Some(text) = extract_text(block) {
                                if let Some(message) = plain_history_message(
                                    HistoryAdapter::Pi,
                                    path,
                                    index,
                                    block_index,
                                    normalized_role,
                                    &text,
                                    extract_timestamp(&value),
                                ) {
                                    messages.push(message);
                                }
                            }
                        }
                        attach_native_usage_to_projection(
                            &mut messages,
                            first_projected,
                            HistoryAdapter::Pi,
                            path,
                            index,
                            &value,
                            message,
                        );
                        continue;
                    }
                }
                if let Some(text) = extract_text(message).or_else(|| extract_text(&value)) {
                    if let Some(mut projected) = plain_history_message(
                        HistoryAdapter::Pi,
                        path,
                        index,
                        0,
                        normalized_role,
                        &text,
                        extract_timestamp(&value).or_else(|| extract_timestamp(message)),
                    ) {
                        attach_native_usage(&mut projected, &value, message);
                        messages.push(projected);
                    }
                } else {
                    attach_native_usage_to_projection(
                        &mut messages,
                        first_projected,
                        HistoryAdapter::Pi,
                        path,
                        index,
                        &value,
                        message,
                    );
                }
            }
            _ => {}
        }
    }

    if messages.is_empty() {
        return None;
    }
    Some(session_from_messages_with_title(
        HistoryAdapter::Pi,
        path,
        metadata,
        source_kind,
        native_session_id,
        messages,
        title,
    ))
}

pub(crate) fn parse_copilot_transcript_session(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
) -> Option<Value> {
    let raw = fs::read_to_string(path).ok()?;
    let mut native_session_id = path
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| "copilot-transcript".to_string());
    let mut messages = Vec::<Value>::new();

    for (index, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        let event_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if event_type == "session.start" {
            if let Some(session_id) = value
                .get("data")
                .and_then(|data| data.get("sessionId"))
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
            {
                native_session_id = session_id.to_string();
            }
            continue;
        }
        let structured_kind = history_message_kind_from_semantic(event_type);
        if structured_kind != HistoryMessageKind::Text {
            let data = value.get("data").unwrap_or(&value);
            let mut projected = structured_history_message(
                HistoryAdapter::Copilot,
                path,
                index,
                0,
                structured_kind,
                event_type,
                data,
                extract_timestamp(&value),
            );
            attach_native_usage(&mut projected, &value, data);
            messages.push(projected);
            continue;
        }
        let role = match event_type {
            "user.message" => "user",
            "assistant.message" => "agent",
            _ => continue,
        };
        let data = value.get("data").unwrap_or(&value);
        let text = data
            .get("content")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| extract_text(data))
            .unwrap_or_default();
        let Some(text) = clean_native_message_text(HistoryAdapter::Copilot, role, &text) else {
            continue;
        };
        let created_at = extract_timestamp(&value).unwrap_or_else(|| {
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
        });
        let mut projected = json!({
            "id": message_id(HistoryAdapter::Copilot.id(), path, index),
            "role": role,
            "text": text,
            "createdAt": created_at,
            "sourcePath": display_path(path),
            "sourceEventType": event_type
        });
        attach_native_usage(&mut projected, &value, data);
        messages.push(projected);
    }

    if messages.is_empty() {
        return None;
    }
    Some(session_from_messages(
        HistoryAdapter::Copilot,
        path,
        metadata,
        source_kind,
        native_session_id,
        messages,
    ))
}

fn attach_native_usage(target: &mut Value, event: &Value, payload: &Value) -> bool {
    let Some(usage) = extract_token_usage(payload).or_else(|| extract_token_usage(event)) else {
        return false;
    };
    let Some(object) = target.as_object_mut() else {
        return false;
    };
    object.insert("usage".to_string(), usage);
    object.insert("usageScope".to_string(), json!("request-response"));
    if let Some(model) = extract_native_model(payload).or_else(|| extract_native_model(event)) {
        object.insert("model".to_string(), json!(model));
    }
    true
}

#[allow(clippy::too_many_arguments)]
fn attach_native_usage_to_projection(
    messages: &mut Vec<Value>,
    first_projected: usize,
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    event: &Value,
    payload: &Value,
) {
    if first_projected < messages.len() {
        let projected = &messages[first_projected..];
        let offset = projected
            .iter()
            .rposition(|message| message.get("role").and_then(Value::as_str) == Some("agent"))
            .unwrap_or(projected.len() - 1);
        if attach_native_usage(&mut messages[first_projected + offset], event, payload) {
            return;
        }
    }
    let mut projected = json!({
        "id": native_history_message_id(adapter, path, index, 0),
        "role": "metadata",
        "text": format!("{} token usage", adapter.label()),
        "createdAt": extract_timestamp(event)
            .or_else(|| extract_timestamp(payload))
            .unwrap_or_else(native_message_timestamp),
        "sourcePath": display_path(path),
        "sourceEventType": "message.usage"
    });
    if attach_native_usage(&mut projected, event, payload) {
        messages.push(projected);
    }
}
