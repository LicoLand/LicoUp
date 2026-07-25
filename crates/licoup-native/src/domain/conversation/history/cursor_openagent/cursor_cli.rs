use std::fs;
use std::path::Path;

use rusqlite::Connection;
use serde_json::{Value, json};

use super::super::HistoryAdapter;
use super::super::generic::messages_from_json;
use super::super::message_projection::{extract_role, extract_text, native_message_timestamp};
use super::super::query_filter::{epoch_number_to_rfc3339, epoch_value_to_rfc3339};
use super::super::session_metadata::session_from_messages_with_title;
use super::codec::sqlite_table_exists;
use super::cursor_projection::normalize_cursor_model_name;

pub(super) fn parse_cursor_cli_store_sessions(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    connection: &Connection,
) -> Vec<Value> {
    if !sqlite_table_exists(connection, "blobs") {
        return Vec::new();
    }
    let session_id = path
        .parent()
        .and_then(|parent| parent.file_name())
        .and_then(|name| name.to_str())
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| "cli-session".to_owned());
    let (created_at, updated_at, model) = cursor_cli_store_metadata(connection);
    let mut messages = Vec::<Value>::new();
    let Ok(mut statement) = connection.prepare("SELECT id, data FROM blobs ORDER BY id ASC") else {
        return Vec::new();
    };
    let Ok(rows) = statement.query_map([], |row| {
        Ok((
            row.get::<_, Option<i64>>(0)?,
            row.get::<_, Option<Vec<u8>>>(1)?,
        ))
    }) else {
        return Vec::new();
    };
    for (index, (blob_id, data)) in rows.flatten().enumerate() {
        let Some(data) = data else {
            continue;
        };
        let Ok(raw) = std::str::from_utf8(&data) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(raw) else {
            continue;
        };
        let role = extract_role(&value);
        if role == "system" || role == "metadata" {
            continue;
        }
        let text = extract_text(&value).unwrap_or_default();
        if text.trim().is_empty() {
            continue;
        }
        let created = blob_id
            .and_then(epoch_number_to_rfc3339)
            .or(created_at.clone())
            .unwrap_or_else(native_message_timestamp);
        let mut envelope = value;
        if !envelope.is_object() {
            envelope = json!({});
        }
        if let Some(object) = envelope.as_object_mut() {
            object
                .entry("role".to_string())
                .or_insert_with(|| json!(role));
            object.insert("createdAt".to_string(), json!(created));
            if let Some(model) = model.as_ref() {
                object
                    .entry("model".to_string())
                    .or_insert_with(|| json!(model));
            }
        }
        messages.extend(messages_from_json(
            HistoryAdapter::Cursor,
            path,
            index,
            &envelope,
        ));
    }
    if messages.is_empty() {
        return Vec::new();
    }
    let mut session = session_from_messages_with_title(
        HistoryAdapter::Cursor,
        path,
        metadata,
        source_kind,
        session_id,
        messages,
        None,
    );
    if let Some(object) = session.as_object_mut() {
        if let Some(model) = model {
            object.insert("model".to_string(), json!(model));
        }
        if let Some(created_at) = created_at {
            object.insert("createdAt".to_string(), json!(created_at));
        }
        if let Some(updated_at) = updated_at {
            object.insert("updatedAt".to_string(), json!(updated_at));
        }
    }
    vec![session]
}

fn cursor_cli_store_metadata(
    connection: &Connection,
) -> (Option<String>, Option<String>, Option<String>) {
    if !sqlite_table_exists(connection, "meta") {
        return (None, None, None);
    }
    let Ok(mut statement) = connection.prepare("SELECT value FROM meta ORDER BY key ASC") else {
        return (None, None, None);
    };
    let Ok(rows) = statement.query_map([], |row| Ok(row.get::<_, Option<String>>(0)?)) else {
        return (None, None, None);
    };
    for value in rows.flatten().flatten() {
        let decoded = decode_cli_meta_value(&value);
        let Some(json) = decoded else {
            continue;
        };
        let created_at = json
            .get("createdAt")
            .and_then(epoch_value_to_rfc3339)
            .or_else(|| json.get("createdAtMs").and_then(epoch_value_to_rfc3339));
        let updated_at = json
            .get("updatedAt")
            .and_then(epoch_value_to_rfc3339)
            .or_else(|| json.get("updatedAtMs").and_then(epoch_value_to_rfc3339));
        let model = json
            .get("model")
            .or_else(|| json.get("modelId"))
            .and_then(Value::as_str)
            .map(normalize_cursor_model_name);
        if created_at.is_some() || updated_at.is_some() || model.is_some() {
            return (created_at, updated_at, model);
        }
    }
    (None, None, None)
}

fn decode_cli_meta_value(value: &str) -> Option<Value> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with('{') {
        return serde_json::from_str(trimmed).ok();
    }
    if trimmed.len() % 2 == 0 && trimmed.chars().all(|ch| ch.is_ascii_hexdigit()) {
        let bytes = (0..trimmed.len())
            .step_by(2)
            .filter_map(|index| u8::from_str_radix(&trimmed[index..index + 2], 16).ok())
            .collect::<Vec<_>>();
        let text = String::from_utf8(bytes).ok()?;
        return serde_json::from_str(&text).ok();
    }
    None
}
