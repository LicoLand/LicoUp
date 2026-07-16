//! Kimi Code wire-history parser.

use super::*;

pub(crate) fn parse_kimi_code_wire_session(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
) -> Vec<Value> {
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(_) => return Vec::new(),
    };
    let mut messages = Vec::<Value>::new();
    let mut fallback_user_messages = Vec::<Value>::new();
    let mut fallback_agent_messages = Vec::<Value>::new();
    let mut saw_user = false;
    let mut saw_agent = false;
    let mut assistant_text = String::new();
    let mut assistant_index = 0usize;
    let mut assistant_created_at = None::<String>;
    let mut assistant_group = None::<String>;
    let mut reasoning_text = String::new();
    let mut reasoning_summaries = Vec::<Value>::new();
    let mut reasoning_index = 0usize;
    let mut reasoning_created_at = None::<String>;
    let mut reasoning_group = None::<String>;
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let Ok(line) = line else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        match value.get("type").and_then(Value::as_str) {
            Some("turn.prompt") => {
                flush_kimi_code_assistant(
                    path,
                    &mut messages,
                    &mut assistant_text,
                    assistant_index,
                    assistant_created_at.take(),
                );
                assistant_group = None;
                flush_kimi_code_reasoning(
                    path,
                    &mut messages,
                    &mut reasoning_text,
                    &mut reasoning_summaries,
                    reasoning_index,
                    reasoning_created_at.take(),
                );
                reasoning_group = None;
                if let Some(text) = value.get("input").and_then(extract_text)
                    && let Some(message) = plain_history_message(
                        HistoryAdapter::KimiCode,
                        path,
                        index,
                        0,
                        "user",
                        &text,
                        extract_timestamp(&value),
                    )
                {
                    messages.push(message);
                    saw_user = true;
                }
            }
            Some("context.append_message") => {
                let mut message_value = value.get("message").cloned().unwrap_or(Value::Null);
                if let Some(object) = message_value.as_object_mut()
                    && !object.contains_key("time")
                    && let Some(time) = value.get("time")
                {
                    object.insert("time".to_string(), time.clone());
                }
                for parsed in
                    messages_from_json(HistoryAdapter::KimiCode, path, index, &message_value)
                {
                    match parsed.get("role").and_then(Value::as_str) {
                        Some("user" | "human") => fallback_user_messages.push(parsed),
                        Some("agent" | "assistant" | "model" | "ai") => {
                            fallback_agent_messages.push(parsed)
                        }
                        _ => {}
                    }
                }
            }
            Some("context.append_loop_event") => {
                let event = value.get("event").unwrap_or(&value);
                let semantic = event
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let created_at = extract_timestamp(&value).or_else(|| extract_timestamp(event));
                match semantic {
                    "content.part" => {
                        let part = event.get("part").unwrap_or(event);
                        let group = kimi_code_content_group(&value, event);
                        match part.get("type").and_then(Value::as_str) {
                            Some("text") => {
                                flush_kimi_code_reasoning(
                                    path,
                                    &mut messages,
                                    &mut reasoning_text,
                                    &mut reasoning_summaries,
                                    reasoning_index,
                                    reasoning_created_at.take(),
                                );
                                reasoning_group = None;
                                if assistant_group
                                    .as_deref()
                                    .is_some_and(|active| active != group)
                                {
                                    flush_kimi_code_assistant(
                                        path,
                                        &mut messages,
                                        &mut assistant_text,
                                        assistant_index,
                                        assistant_created_at.take(),
                                    );
                                }
                                if let Some(text) = part.get("text").and_then(extract_text)
                                    && !text.is_empty()
                                {
                                    if assistant_text.is_empty() {
                                        assistant_index = index;
                                        assistant_created_at = created_at;
                                        assistant_group = Some(group);
                                    }
                                    assistant_text.push_str(&text);
                                    saw_agent = true;
                                }
                            }
                            Some("think") => {
                                flush_kimi_code_assistant(
                                    path,
                                    &mut messages,
                                    &mut assistant_text,
                                    assistant_index,
                                    assistant_created_at.take(),
                                );
                                assistant_group = None;
                                if reasoning_group
                                    .as_deref()
                                    .is_some_and(|active| active != group)
                                {
                                    flush_kimi_code_reasoning(
                                        path,
                                        &mut messages,
                                        &mut reasoning_text,
                                        &mut reasoning_summaries,
                                        reasoning_index,
                                        reasoning_created_at.take(),
                                    );
                                }
                                if reasoning_text.is_empty() {
                                    reasoning_index = index;
                                    reasoning_created_at = created_at;
                                    reasoning_group = Some(group);
                                }
                                if let Some(text) = part
                                    .get("think")
                                    .or_else(|| part.get("text"))
                                    .and_then(extract_text)
                                {
                                    reasoning_text.push_str(&text);
                                }
                                for key in ["summary", "reasoningSummary", "reasoning_summary"] {
                                    if let Some(summary) = part.get(key) {
                                        reasoning_summaries.push(summary.clone());
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    "tool.call" | "tool.result" => {
                        flush_kimi_code_assistant(
                            path,
                            &mut messages,
                            &mut assistant_text,
                            assistant_index,
                            assistant_created_at.take(),
                        );
                        assistant_group = None;
                        flush_kimi_code_reasoning(
                            path,
                            &mut messages,
                            &mut reasoning_text,
                            &mut reasoning_summaries,
                            reasoning_index,
                            reasoning_created_at.take(),
                        );
                        reasoning_group = None;
                        messages.push(structured_history_message(
                            HistoryAdapter::KimiCode,
                            path,
                            index,
                            0,
                            if semantic == "tool.call" {
                                HistoryMessageKind::ToolCall
                            } else {
                                HistoryMessageKind::ToolResult
                            },
                            semantic,
                            event,
                            created_at,
                        ));
                    }
                    _ => {}
                }
            }
            Some("usage.record") => {
                if !saw_user {
                    messages.append(&mut fallback_user_messages);
                }
                if !saw_agent {
                    messages.append(&mut fallback_agent_messages);
                }
                if !saw_user {
                    messages.append(&mut fallback_user_messages);
                }
                if !saw_agent {
                    messages.append(&mut fallback_agent_messages);
                }
                flush_kimi_code_assistant(
                    path,
                    &mut messages,
                    &mut assistant_text,
                    assistant_index,
                    assistant_created_at.take(),
                );
                assistant_group = None;
                flush_kimi_code_reasoning(
                    path,
                    &mut messages,
                    &mut reasoning_text,
                    &mut reasoning_summaries,
                    reasoning_index,
                    reasoning_created_at.take(),
                );
                reasoning_group = None;
                if let Some(message) = kimi_code_usage_message(path, index, &value) {
                    messages.push(message);
                }
            }
            _ => {}
        }
    }
    flush_kimi_code_assistant(
        path,
        &mut messages,
        &mut assistant_text,
        assistant_index,
        assistant_created_at,
    );
    flush_kimi_code_reasoning(
        path,
        &mut messages,
        &mut reasoning_text,
        &mut reasoning_summaries,
        reasoning_index,
        reasoning_created_at,
    );
    if !saw_user {
        messages.extend(fallback_user_messages);
    }
    if !saw_agent {
        messages.extend(fallback_agent_messages);
    }
    if messages.is_empty() {
        return Vec::new();
    }
    let explicit_title = path
        .ancestors()
        .nth(3)
        .map(|session_root| session_root.join("state.json"))
        .and_then(|state_path| fs::read_to_string(state_path).ok())
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|state| extract_conversation_title(&state));
    vec![session_from_messages_with_title(
        HistoryAdapter::KimiCode,
        path,
        metadata,
        source_kind,
        kimi_code_native_session_id(path),
        messages,
        explicit_title,
    )]
}

pub(super) fn flush_kimi_code_assistant(
    path: &Path,
    messages: &mut Vec<Value>,
    text: &mut String,
    index: usize,
    created_at: Option<String>,
) {
    if text.is_empty() {
        return;
    }
    if let Some(message) = plain_history_message(
        HistoryAdapter::KimiCode,
        path,
        index,
        0,
        "agent",
        text,
        created_at,
    ) {
        messages.push(message);
    }
    text.clear();
}

pub(super) fn flush_kimi_code_reasoning(
    path: &Path,
    messages: &mut Vec<Value>,
    text: &mut String,
    summaries: &mut Vec<Value>,
    index: usize,
    created_at: Option<String>,
) {
    if text.is_empty() && summaries.is_empty() {
        return;
    }
    let mut value = json!({"text": std::mem::take(text)});
    if !summaries.is_empty() {
        value["summary"] = Value::Array(std::mem::take(summaries));
    }
    messages.push(structured_history_message(
        HistoryAdapter::KimiCode,
        path,
        index,
        0,
        HistoryMessageKind::Reasoning,
        "thinking",
        &value,
        created_at,
    ));
}

pub(super) fn kimi_code_content_group(value: &Value, event: &Value) -> String {
    let turn = find_string(value, &["turnId", "turn_id"])
        .or_else(|| find_string(event, &["turnId", "turn_id"]))
        .unwrap_or_default();
    let step = find_string(event, &["step", "stepId", "step_id"]).unwrap_or_default();
    format!("{turn}\n{step}")
}

pub(super) fn kimi_code_usage_message(path: &Path, index: usize, value: &Value) -> Option<Value> {
    if value.get("usageScope").and_then(Value::as_str) != Some("turn") {
        return None;
    }
    let usage = value.get("usage")?.as_object()?;
    let input_other = usage
        .get("inputOther")
        .and_then(token_count_value)
        .unwrap_or(0);
    let input_cache_read = usage
        .get("inputCacheRead")
        .and_then(token_count_value)
        .unwrap_or(0);
    let input_cache_creation = usage
        .get("inputCacheCreation")
        .and_then(token_count_value)
        .unwrap_or(0);
    let output = usage.get("output").and_then(token_count_value).unwrap_or(0);
    let prompt_tokens = input_other
        .saturating_add(input_cache_read)
        .saturating_add(input_cache_creation);
    let total_tokens = prompt_tokens.saturating_add(output);
    if total_tokens == 0 {
        return None;
    }
    let model = value
        .get("model")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())?;
    let created_at = find_string(value, &["time", "timestamp", "createdAt"])
        .unwrap_or_else(native_message_timestamp);
    Some(json!({
        "id": native_history_message_id(HistoryAdapter::KimiCode, path, index, 0),
        "role": "metadata",
        "text": "Kimi Code token usage",
        "createdAt": created_at,
        "sourcePath": display_path(path),
        "sourceEventType": "usage.record",
        "model": model,
        "usageScope": "turn",
        "usage": {
            "promptTokens": prompt_tokens,
            "cachedInputTokens": input_cache_read,
            "completionTokens": output,
            "totalTokens": total_tokens,
            "source": "explicit"
        }
    }))
}

pub(super) fn kimi_code_native_session_id(path: &Path) -> String {
    let agent_id = path
        .parent()
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .unwrap_or("main");
    let session_id = path
        .ancestors()
        .nth(3)
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .unwrap_or("session");
    if agent_id == "main" {
        session_id.to_string()
    } else {
        format!("{session_id}:{agent_id}")
    }
}
