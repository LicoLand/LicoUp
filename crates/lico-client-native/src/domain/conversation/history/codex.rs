//! Codex rollout parser and rollout-local usage projection.

use super::*;

#[derive(Debug)]
pub(super) struct CodexRolloutGroup {
    session_id: String,
    parent_session_id: Option<String>,
    subagent_title: Option<String>,
    is_subagent: bool,
    messages: Vec<Value>,
    cwd: Option<String>,
    matched_terms: BTreeSet<String>,
    message_count: usize,
    preview_count: usize,
}

pub(crate) fn parse_codex_rollout_sessions(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    scan_config: HistoryScanConfig,
) -> Option<Vec<Value>> {
    let mut groups = Vec::<CodexRolloutGroup>::new();
    let mut current_session_id = rollout_session_id_from_filename(path);
    let mut saw_rollout_record = false;

    if scan_config.archive_mode {
        let file = fs::File::open(path).ok()?;
        let reader = BufReader::new(file);
        for (index, line) in reader.lines().enumerate() {
            let Ok(line) = line else {
                continue;
            };
            parse_codex_rollout_line(
                path,
                index,
                &line,
                &scan_config,
                &mut current_session_id,
                &mut saw_rollout_record,
                &mut groups,
            );
        }
    } else {
        let raw = fs::read_to_string(path).ok()?;
        for (index, line) in raw.lines().enumerate() {
            parse_codex_rollout_line(
                path,
                index,
                line,
                &scan_config,
                &mut current_session_id,
                &mut saw_rollout_record,
                &mut groups,
            );
        }
    }

    if !saw_rollout_record {
        return None;
    }

    Some(
        groups
            .into_iter()
            .filter(|group| {
                !group.messages.is_empty()
                    && (!scan_config.has_match_filters() || !group.matched_terms.is_empty())
            })
            .map(|group| {
                let message_count = group.message_count.max(group.messages.len());
                let mut session = session_from_messages(
                    HistoryAdapter::Codex,
                    path,
                    metadata,
                    source_kind,
                    group.session_id,
                    group.messages,
                );
                if let Some(object) = session.as_object_mut() {
                    object.insert("messageCount".to_string(), json!(message_count));
                    if scan_config.has_match_filters() {
                        object.insert("archiveDiscoveryHasConversation".to_string(), json!(true));
                        object.insert(
                            "archiveDiscoveryMatchedTerms".to_string(),
                            json!(group.matched_terms.into_iter().collect::<Vec<_>>()),
                        );
                        object.insert(
                            "messagesTruncatedForArchiveDiscovery".to_string(),
                            json!(true),
                        );
                    }
                    if let Some(cwd) = group.cwd {
                        object.insert("workingDirectory".to_string(), json!(cwd));
                    }
                    if let Some(parent_session_id) = group.parent_session_id {
                        object.insert("parentSessionId".to_string(), json!(parent_session_id));
                    }
                    if group.is_subagent {
                        object.insert("delegatedSubagent".to_string(), json!(true));
                    }
                    if let Some(title) = group.subagent_title {
                        object.insert("subagentTitle".to_string(), json!(title));
                    }
                }
                session
            })
            .collect(),
    )
}

pub(super) fn parse_codex_rollout_line(
    path: &Path,
    index: usize,
    line: &str,
    scan_config: &HistoryScanConfig,
    current_session_id: &mut Option<String>,
    saw_rollout_record: &mut bool,
    groups: &mut Vec<CodexRolloutGroup>,
) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }
    let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
        return;
    };
    let Some(event_type) = value.get("type").and_then(Value::as_str) else {
        return;
    };
    let Some(payload) = value.get("payload") else {
        return;
    };
    if !matches!(
        event_type,
        "session_meta" | "turn_context" | "response_item" | "event_msg"
    ) {
        return;
    }
    *saw_rollout_record = true;

    if event_type == "session_meta" {
        if let Some(session_id) = find_string(payload, &["id", "sessionId", "session_id"])
            .filter(|value| !value.trim().is_empty())
        {
            *current_session_id = Some(session_id);
        }
    }

    let session_id = current_session_id
        .clone()
        .unwrap_or_else(|| "file".to_string());
    let cwd = find_string(payload, &["cwd", "workingDirectory", "projectPath"])
        .filter(|value| !value.trim().is_empty());

    if event_type == "session_meta" {
        update_codex_rollout_group_lineage(groups, &session_id, payload);
    }

    if let Some(message) = codex_rollout_message(path, index, event_type, payload, &value) {
        push_codex_rollout_message(groups, session_id, message, cwd, scan_config);
    } else if cwd.is_some() {
        update_codex_rollout_group_cwd(groups, session_id, cwd);
    }
}

pub(super) fn update_codex_rollout_group_cwd(
    groups: &mut Vec<CodexRolloutGroup>,
    session_id: String,
    cwd: Option<String>,
) {
    if let Some(group) = groups
        .iter_mut()
        .find(|group| group.session_id == session_id)
    {
        if group.cwd.is_none() {
            group.cwd = cwd;
        }
        return;
    }
    groups.push(CodexRolloutGroup {
        session_id,
        parent_session_id: None,
        subagent_title: None,
        is_subagent: false,
        messages: Vec::new(),
        cwd,
        matched_terms: BTreeSet::new(),
        message_count: 0,
        preview_count: 0,
    });
}

pub(super) fn update_codex_rollout_group_lineage(
    groups: &mut Vec<CodexRolloutGroup>,
    session_id: &str,
    payload: &Value,
) {
    if !groups.iter().any(|group| group.session_id == session_id) {
        update_codex_rollout_group_cwd(groups, session_id.to_string(), None);
    }
    let Some(group) = groups
        .iter_mut()
        .find(|group| group.session_id == session_id)
    else {
        return;
    };
    group.parent_session_id = find_nested_string(
        payload,
        &[
            "forked_from_id",
            "forkedFromId",
            "parent_session_id",
            "parentSessionId",
            "parent_thread_id",
            "parentThreadId",
        ],
        0,
    )
    .filter(|parent_id| parent_id != session_id);
    group.is_subagent = contains_nested_key(payload, "subagent", 0)
        || contains_nested_key(payload, "thread_spawn", 0)
        || contains_nested_key(payload, "threadSpawn", 0);
    group.subagent_title = find_nested_string(
        payload,
        &["agent_nickname", "agentNickname", "agent_role", "agentRole"],
        0,
    );
}

pub(super) fn find_nested_string(value: &Value, keys: &[&str], depth: usize) -> Option<String> {
    if depth > 8 {
        return None;
    }
    match value {
        Value::Object(object) => {
            for key in keys {
                if let Some(text) = object.get(*key).and_then(Value::as_str) {
                    if !text.trim().is_empty() {
                        return Some(text.to_string());
                    }
                }
            }
            object
                .values()
                .find_map(|child| find_nested_string(child, keys, depth + 1))
        }
        Value::Array(items) => items
            .iter()
            .find_map(|child| find_nested_string(child, keys, depth + 1)),
        _ => None,
    }
}

pub(super) fn contains_nested_key(value: &Value, needle: &str, depth: usize) -> bool {
    if depth > 8 {
        return false;
    }
    match value {
        Value::Object(object) => {
            object.contains_key(needle)
                || object
                    .values()
                    .any(|child| contains_nested_key(child, needle, depth + 1))
        }
        Value::Array(items) => items
            .iter()
            .any(|child| contains_nested_key(child, needle, depth + 1)),
        _ => false,
    }
}

pub(super) fn push_codex_rollout_message(
    groups: &mut Vec<CodexRolloutGroup>,
    session_id: String,
    message: Value,
    cwd: Option<String>,
    scan_config: &HistoryScanConfig,
) {
    let matched_terms = codex_rollout_message_matched_terms(&message, cwd.as_deref(), scan_config);
    if let Some(group) = groups
        .iter_mut()
        .find(|group| group.session_id == session_id)
    {
        if group.cwd.is_none() {
            group.cwd = cwd;
        }
        push_codex_rollout_message_into_group(group, message, matched_terms, scan_config);
        return;
    }
    let mut group = CodexRolloutGroup {
        session_id,
        parent_session_id: None,
        subagent_title: None,
        is_subagent: false,
        messages: Vec::new(),
        cwd,
        matched_terms: BTreeSet::new(),
        message_count: 0,
        preview_count: 0,
    };
    push_codex_rollout_message_into_group(&mut group, message, matched_terms, scan_config);
    groups.push(group);
}

pub(super) fn push_codex_rollout_message_into_group(
    group: &mut CodexRolloutGroup,
    message: Value,
    matched_terms: Vec<String>,
    scan_config: &HistoryScanConfig,
) {
    let is_conversation = history_message_is_matchable(&message);
    if is_conversation {
        group.message_count += 1;
    }
    for term in matched_terms {
        group.matched_terms.insert(term);
    }
    if !scan_config.has_match_filters() {
        group.messages.push(message);
        return;
    }
    if !is_conversation {
        return;
    }
    let is_match = !group.matched_terms.is_empty()
        && codex_rollout_message_matched_terms(&message, group.cwd.as_deref(), scan_config)
            .into_iter()
            .any(|term| group.matched_terms.contains(&term));
    if is_match || group.preview_count < ARCHIVE_DISCOVERY_PREVIEW_MESSAGES {
        if !is_match {
            group.preview_count += 1;
        }
        group
            .messages
            .push(truncate_codex_rollout_preview_message(message));
    }
}

pub(super) fn codex_rollout_message_matched_terms(
    message: &Value,
    cwd: Option<&str>,
    scan_config: &HistoryScanConfig,
) -> Vec<String> {
    if !scan_config.has_match_filters() || !history_message_is_matchable(message) {
        return Vec::new();
    }
    let text = message
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let path_text = cwd.unwrap_or_default();
    scan_config.matched_terms_in_text_and_path(text, path_text)
}

pub(super) fn truncate_codex_rollout_preview_message(mut message: Value) -> Value {
    if let Some(object) = message.as_object_mut() {
        if let Some(text) = object.get("text").and_then(Value::as_str) {
            if text.chars().count() > ARCHIVE_DISCOVERY_PREVIEW_TEXT_CHARS {
                object.insert(
                    "text".to_string(),
                    json!(format!(
                        "{}...",
                        text.chars()
                            .take(ARCHIVE_DISCOVERY_PREVIEW_TEXT_CHARS)
                            .collect::<String>()
                    )),
                );
            }
        }
    }
    message
}

pub(super) fn codex_rollout_message(
    path: &Path,
    index: usize,
    event_type: &str,
    payload: &Value,
    raw_value: &Value,
) -> Option<Value> {
    match event_type {
        "session_meta" | "turn_context" => None,
        "response_item" => codex_response_item_message(path, index, payload, raw_value),
        "event_msg" => codex_event_message(path, index, payload, raw_value),
        _ => None,
    }
}

pub(super) fn codex_event_message(
    path: &Path,
    index: usize,
    payload: &Value,
    raw_value: &Value,
) -> Option<Value> {
    let item_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let normalized = normalize_history_message_semantic(item_type);
    if normalized.ends_with("-delta")
        || matches!(
            normalized.as_str(),
            "agent-message" | "user-message" | "task-started" | "task-complete"
        )
    {
        return None;
    }
    let kind = if matches!(
        normalized.as_str(),
        "token-count" | "usage" | "turn-metadata"
    ) {
        HistoryMessageKind::Metadata
    } else if matches!(normalized.as_str(), "turn-aborted" | "stream-error") {
        HistoryMessageKind::Error
    } else {
        history_message_kind_from_semantic(item_type)
    };
    if matches!(kind, HistoryMessageKind::Text | HistoryMessageKind::Event)
        && normalized != "warning"
    {
        return None;
    }
    Some(structured_history_message(
        HistoryAdapter::Codex,
        path,
        index,
        0,
        kind,
        item_type,
        payload,
        extract_timestamp(raw_value),
    ))
}

pub(super) fn codex_response_item_message(
    path: &Path,
    index: usize,
    payload: &Value,
    raw_value: &Value,
) -> Option<Value> {
    let item_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let structured_kind = history_message_kind_from_semantic(item_type);
    if structured_kind != HistoryMessageKind::Text {
        return Some(structured_history_message(
            HistoryAdapter::Codex,
            path,
            index,
            0,
            structured_kind,
            item_type,
            payload,
            extract_timestamp(raw_value),
        ));
    }
    let text = match item_type {
        _ => payload
            .get("content")
            .or_else(|| payload.get("text"))
            .or_else(|| payload.get("summary"))
            .and_then(extract_text),
    }?;
    let role = extract_role(payload);
    if let Some(mut message) = delegated_subagent_prompt_message(
        HistoryAdapter::Codex,
        path,
        index,
        &role,
        &text,
        extract_timestamp(raw_value),
    ) {
        if let Some(object) = message.as_object_mut() {
            object.insert("sourceEventType".to_string(), json!("response_item"));
            object.insert("sourceItemType".to_string(), json!(item_type));
        }
        return Some(message);
    }
    let text = clean_native_message_text(HistoryAdapter::Codex, &role, &text)?;
    if metadata_like_text(&text) {
        return None;
    }
    let mut message = json!({
        "id": message_id(HistoryAdapter::Codex.id(), path, index),
        "role": role,
        "text": text,
        "createdAt": extract_timestamp(raw_value).unwrap_or_else(|| {
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
        }),
        "sourcePath": display_path(path),
        "sourceEventType": "response_item",
        "sourceItemType": item_type
    });
    if let Some(usage) = extract_token_usage(payload).or_else(|| extract_token_usage(raw_value)) {
        if let Some(object) = message.as_object_mut() {
            object.insert("usage".to_string(), usage);
        }
    }
    Some(message)
}

pub(crate) fn codex_usage_estimate_message(value: &Value) -> Option<(String, String)> {
    if value.get("type").and_then(Value::as_str) != Some("response_item") {
        return None;
    }
    let payload = value.get("payload")?;
    let item_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if matches!(
        item_type,
        "function_call" | "function_call_output" | "reasoning"
    ) {
        return None;
    }
    let text = payload
        .get("content")
        .or_else(|| payload.get("text"))
        .or_else(|| payload.get("summary"))
        .and_then(extract_text)?;
    let role = extract_role(payload);
    let text = clean_native_message_text(HistoryAdapter::Codex, &role, &text)?;
    if metadata_like_text(&text) {
        return None;
    }
    Some((role, text))
}

pub(super) fn rollout_session_id_from_filename(path: &Path) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    let parts = stem.split('-').collect::<Vec<_>>();
    if parts.len() < 5 {
        return None;
    }
    for window in parts.windows(5) {
        let candidate = window.join("-");
        if looks_like_uuid(&candidate) {
            return Some(candidate);
        }
    }
    None
}

pub(super) fn looks_like_uuid(value: &str) -> bool {
    let parts = value.split('-').collect::<Vec<_>>();
    let lengths = [8usize, 4, 4, 4, 12];
    parts.len() == lengths.len()
        && parts.iter().zip(lengths).all(|(part, length)| {
            part.len() == length && part.chars().all(|ch| ch.is_ascii_hexdigit())
        })
}
