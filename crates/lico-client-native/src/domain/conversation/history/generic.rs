//! Service-neutral JSON, JSONL, embedded JSON, and text parsers.

use super::*;

pub(crate) fn parse_jsonl_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    scan_config: HistoryScanConfig,
) -> Vec<Value> {
    let mut grouped = Vec::<(String, Vec<Value>)>::new();
    if scan_config.archive_mode {
        let file = match fs::File::open(path) {
            Ok(file) => file,
            Err(_) => return Vec::new(),
        };
        let reader = BufReader::new(file);
        for (index, line) in reader.lines().enumerate() {
            let Ok(line) = line else {
                continue;
            };
            push_jsonl_message(adapter, path, index, &line, &mut grouped);
        }
    } else {
        let raw = match fs::read_to_string(path) {
            Ok(raw) => raw,
            Err(_) => return Vec::new(),
        };
        for (index, line) in raw.lines().enumerate() {
            push_jsonl_message(adapter, path, index, line, &mut grouped);
        }
    }
    grouped
        .into_iter()
        .map(|(native_session_id, messages)| {
            session_from_messages(
                adapter,
                path,
                metadata,
                source_kind,
                native_session_id,
                messages,
            )
        })
        .collect()
}

pub(super) fn push_jsonl_message(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    line: &str,
    grouped: &mut Vec<(String, Vec<Value>)>,
) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        let session_id = extract_native_session_id(&value).unwrap_or_else(|| "file".to_string());
        for message in messages_from_json(adapter, path, index, &value) {
            push_grouped_message(grouped, session_id.clone(), message);
        }
    }
}

pub(crate) fn parse_json_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
) -> Vec<Value> {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(_) => return Vec::new(),
    };
    let value = match serde_json::from_str::<Value>(&raw) {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };
    let sessions = collect_explicit_json_sessions(adapter, path, metadata, source_kind, &value);
    if !sessions.is_empty() {
        return sessions;
    }
    let mut messages = Vec::<Value>::new();
    collect_messages_from_value(adapter, path, &value, &mut messages);
    if messages.is_empty() {
        return Vec::new();
    }
    vec![session_from_messages_with_title(
        adapter,
        path,
        metadata,
        source_kind,
        extract_native_session_id(&value).unwrap_or_else(|| "file".to_string()),
        messages,
        extract_conversation_title(&value),
    )]
}

pub(crate) fn parse_text_session(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
) -> Vec<Value> {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(_) => return Vec::new(),
    };
    if raw.trim().is_empty() || !looks_like_text_conversation(&raw) {
        return Vec::new();
    }
    let created_at = system_time(metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH));
    let messages = vec![json!({
        "id": message_id(adapter.id(), path, 0),
        "role": "transcript",
        "text": raw,
        "createdAt": created_at,
        "sourcePath": display_path(path)
    })];
    vec![session_from_messages(
        adapter,
        path,
        metadata,
        source_kind,
        "file".to_string(),
        messages,
    )]
}

pub(super) fn collect_explicit_json_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    metadata: &fs::Metadata,
    source_kind: &str,
    value: &Value,
) -> Vec<Value> {
    let Some(object) = value.as_object() else {
        return Vec::new();
    };
    let mut sessions = Vec::<Value>::new();
    for key in ["sessions", "conversations", "chats", "chatSessions"] {
        let Some(Value::Array(items)) = object.get(key) else {
            continue;
        };
        for (index, item) in items.iter().enumerate() {
            let mut messages = Vec::<Value>::new();
            collect_messages_from_value(adapter, path, item, &mut messages);
            if messages.is_empty() {
                continue;
            }
            sessions.push(session_from_messages_with_title(
                adapter,
                path,
                metadata,
                source_kind,
                extract_native_session_id(item).unwrap_or_else(|| format!("{}-{}", key, index)),
                messages,
                extract_conversation_title(item),
            ));
        }
    }
    sessions
}

pub(super) fn push_grouped_message(
    groups: &mut Vec<(String, Vec<Value>)>,
    session_id: String,
    message: Value,
) {
    if let Some((_, messages)) = groups.iter_mut().find(|(id, _)| *id == session_id) {
        messages.push(message);
    } else {
        groups.push((session_id, vec![message]));
    }
}

pub(super) fn collect_messages_from_value(
    adapter: HistoryAdapter,
    path: &Path,
    value: &Value,
    out: &mut Vec<Value>,
) {
    match value {
        Value::Array(items) => {
            for (index, item) in items.iter().enumerate() {
                if value_is_conversation_container(item) {
                    collect_messages_from_value(adapter, path, item, out);
                } else {
                    let messages = messages_from_json(adapter, path, index, item);
                    if messages.is_empty() {
                        collect_messages_from_value(adapter, path, item, out);
                    } else {
                        out.extend(messages);
                    }
                }
            }
        }
        Value::Object(object) => {
            let before = out.len();
            for key in [
                "messages",
                "conversation",
                "conversations",
                "transcript",
                "turns",
                "items",
                "entries",
                "sessions",
                "chats",
                "chatSessions",
            ] {
                if let Some(child) = object.get(key) {
                    collect_messages_from_value(adapter, path, child, out);
                }
            }
            if out.len() == before {
                let messages = messages_from_json(adapter, path, 0, value);
                if !messages.is_empty() {
                    out.extend(messages);
                }
            }
        }
        _ => {}
    }
}

pub(super) fn value_is_conversation_container(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    let has_container = [
        "messages",
        "conversation",
        "conversations",
        "transcript",
        "turns",
        "entries",
        "sessions",
        "chats",
        "chatSessions",
    ]
    .iter()
    .any(|key| object.contains_key(*key));
    let has_direct_message_text = [
        "text", "content", "prompt", "response", "answer", "summary", "value",
    ]
    .iter()
    .any(|key| object.contains_key(*key));
    has_container && !has_direct_message_text
}

pub(super) fn messages_from_json(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    value: &Value,
) -> Vec<Value> {
    let role = extract_role(value);
    let created_at = extract_timestamp(value);
    let model = extract_native_model(value);
    if let Some(blocks) = direct_native_content_blocks(value) {
        let mut messages = blocks
            .iter()
            .enumerate()
            .filter_map(|(block_index, block)| {
                message_from_native_content_block(
                    adapter,
                    path,
                    index,
                    block_index,
                    &role,
                    block,
                    created_at.clone(),
                )
            })
            .collect::<Vec<_>>();
        if !messages.is_empty() {
            let target_index = messages.len() - 1;
            if let Some(object) = messages[target_index].as_object_mut() {
                if let Some(usage) = extract_token_usage(value) {
                    object.insert("usage".to_string(), usage);
                    object.insert("usageScope".to_string(), json!("request-response"));
                }
                if let Some(model) = model {
                    object.insert("model".to_string(), json!(model));
                }
            }
            return messages;
        }
    }
    let kind = history_message_kind_from_semantic(&role);
    if kind != HistoryMessageKind::Text {
        return vec![structured_history_message(
            adapter, path, index, 0, kind, &role, value, created_at,
        )];
    }
    let Some(text) = extract_text(value) else {
        return Vec::new();
    };
    if let Some(message) =
        delegated_subagent_prompt_message(adapter, path, index, &role, &text, created_at.clone())
    {
        return vec![message];
    }
    let Some(mut message) =
        plain_history_message(adapter, path, index, 0, &role, &text, created_at)
    else {
        return Vec::new();
    };
    if let Some(object) = message.as_object_mut() {
        if let Some(usage) = extract_token_usage(value) {
            object.insert("usage".to_string(), usage);
            object.insert("usageScope".to_string(), json!("request-response"));
        }
        if let Some(model) = model {
            object.insert("model".to_string(), json!(model));
        }
    }
    vec![message]
}

pub(super) fn direct_native_content_blocks(value: &Value) -> Option<&Vec<Value>> {
    value
        .get("message")
        .and_then(|message| message.get("content"))
        .or_else(|| value.get("content"))
        .and_then(Value::as_array)
}

pub(super) fn message_from_native_content_block(
    adapter: HistoryAdapter,
    path: &Path,
    index: usize,
    block_index: usize,
    outer_role: &str,
    block: &Value,
    created_at: Option<String>,
) -> Option<Value> {
    let semantic = native_content_semantic(block);
    let kind = history_message_kind_from_semantic(&semantic);
    if kind != HistoryMessageKind::Text {
        return Some(structured_history_message(
            adapter,
            path,
            index,
            block_index,
            kind,
            &semantic,
            block,
            created_at,
        ));
    }
    let text = extract_text(block)?;
    if let Some(message) = delegated_subagent_prompt_message(
        adapter,
        path,
        index,
        outer_role,
        &text,
        created_at.clone(),
    ) {
        return Some(message);
    }
    plain_history_message(
        adapter,
        path,
        index,
        block_index,
        outer_role,
        &text,
        created_at,
    )
}

pub(super) fn native_content_semantic(value: &Value) -> String {
    value
        .as_object()
        .and_then(|object| {
            ["type", "kind", "role", "eventType", "event_type"]
                .iter()
                .find_map(|key| object.get(*key).and_then(Value::as_str))
        })
        .unwrap_or_default()
        .to_string()
}
