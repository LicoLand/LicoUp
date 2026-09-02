use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use super::super::HistoryPageConfig;

pub(crate) fn dedupe_history_sessions(sessions: Vec<Value>) -> Vec<Value> {
    let mut seen = BTreeSet::<String>::new();
    sessions
        .into_iter()
        .filter(|session| seen.insert(history_session_dedupe_key(session)))
        .collect()
}

/// Collapse sessions that share one native identity into the richest of them,
/// carrying over metadata the richest one lacks.
///
/// Cursor records the same conversation in the IDE store, the CLI chat store,
/// and the CLI project tree, and only some of them know the project directory.
/// This runs before the delegated-task merge: leaving the copies in place makes
/// every delegated task attach to an arbitrary copy, so the conversation the
/// user opens is missing most of its tasks.
pub(crate) fn collapse_sessions_by_native_identity(sessions: Vec<Value>) -> Vec<Value> {
    let mut kept = BTreeMap::<String, usize>::new();
    let mut merged = Vec::<Value>::with_capacity(sessions.len());
    for session in sessions {
        let identity = history_session_native_id(&session);
        if identity.is_empty() {
            merged.push(session);
            continue;
        }
        match kept.get(&identity).copied() {
            Some(index) => {
                if session_richness(&session) > session_richness(&merged[index]) {
                    let previous = std::mem::replace(&mut merged[index], session);
                    absorb_session_metadata(&mut merged[index], &previous);
                } else {
                    absorb_session_metadata(&mut merged[index], &session);
                }
            }
            None => {
                kept.insert(identity, merged.len());
                merged.push(session);
            }
        }
    }
    merged
}

/// Ordering key for choosing which recorded copy of a conversation to keep. The
/// copy with the most messages holds the most of the conversation; a known
/// project directory breaks ties.
fn session_richness(session: &Value) -> (usize, u8) {
    (
        history_session_message_count(session),
        u8::from(
            session
                .get("workingDirectory")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.trim().is_empty()),
        ),
    )
}

/// Fields a discarded copy may know that the kept copy does not.
fn absorb_session_metadata(kept: &mut Value, discarded: &Value) {
    let Some(object) = kept.as_object_mut() else {
        return;
    };
    for field in [
        "workingDirectory",
        "model",
        "title",
        "createdAt",
        "subagentTitle",
        "parentSessionId",
    ] {
        let present = object
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty());
        if present {
            continue;
        }
        if let Some(value) = discarded
            .get(field)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
        {
            object.insert(field.to_string(), Value::String(value.to_string()));
        }
    }
    if object.get("delegatedSubagent").and_then(Value::as_bool) != Some(true)
        && discarded.get("delegatedSubagent").and_then(Value::as_bool) == Some(true)
    {
        object.insert("delegatedSubagent".to_string(), Value::Bool(true));
    }
    if discarded.get("running").and_then(Value::as_bool) == Some(true) {
        object.insert("running".to_string(), Value::Bool(true));
    }
}

pub(crate) fn paged_history_sessions(sessions: Vec<Value>, page: &HistoryPageConfig) -> Vec<Value> {
    if page.offset >= sessions.len() {
        return Vec::new();
    }
    let end = page
        .end()
        .map(|end| end.min(sessions.len()))
        .unwrap_or(sessions.len());
    sessions
        .into_iter()
        .skip(page.offset)
        .take(end.saturating_sub(page.offset))
        .collect()
}

pub(crate) fn history_session_dedupe_key(session: &Value) -> String {
    let adapter_id = history_session_adapter_id(session);
    let native_session_id = history_session_native_id(session);
    // Codex and Cursor both write one conversation into several stores under a
    // single native identity, so identity alone is the key.
    if matches!(adapter_id, "codex" | "cursor") && !native_session_id.is_empty() {
        return format!("{adapter_id}\n{native_session_id}");
    }
    let source_path = session
        .get("sourcePath")
        .and_then(Value::as_str)
        .unwrap_or_default();
    format!("{adapter_id}\n{source_path}\n{native_session_id}")
}

pub(super) fn history_session_adapter_id(session: &Value) -> &str {
    session
        .get("adapterId")
        .and_then(Value::as_str)
        .unwrap_or_default()
}

pub(super) fn history_session_native_id(session: &Value) -> String {
    session
        .get("nativeSessionId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or_default()
        .to_string()
}

pub(super) fn history_session_message_count(session: &Value) -> usize {
    session
        .get("messageCount")
        .and_then(Value::as_u64)
        .map(|value| value as usize)
        .or_else(|| {
            session
                .get("messages")
                .and_then(Value::as_array)
                .map(Vec::len)
        })
        .unwrap_or(0)
}
