use std::collections::BTreeSet;

use serde_json::Value;

use super::super::HistoryPageConfig;

pub(crate) fn dedupe_history_sessions(sessions: Vec<Value>) -> Vec<Value> {
    let mut seen = BTreeSet::<String>::new();
    sessions
        .into_iter()
        .filter(|session| seen.insert(history_session_dedupe_key(session)))
        .collect()
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
    if adapter_id == "codex" && !native_session_id.is_empty() {
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
