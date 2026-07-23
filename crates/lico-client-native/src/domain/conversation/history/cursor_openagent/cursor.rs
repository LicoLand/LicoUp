use std::fs;
use std::path::Path;

use rusqlite::{Connection, TransactionBehavior};
use serde_json::{Value, json};

use super::super::HistoryAdapter;
use super::super::query_filter::epoch_value_to_rfc3339;
use super::super::session_metadata::session_from_messages_with_title;
use super::codec::{sqlite_table_exists, sqlite_value_text};
use super::cursor_projection::{cursor_composer_model_from_config, cursor_message_from_bubble};

pub(super) fn parse_cursor_sqlite_sessions(
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    connection: &mut Connection,
) -> Vec<Value> {
    let transaction = match connection.transaction_with_behavior(TransactionBehavior::Deferred) {
        Ok(transaction) => transaction,
        Err(_) => return Vec::new(),
    };
    if !sqlite_table_exists(&transaction, "cursorDiskKV") {
        return Vec::new();
    }

    let composers = cursor_composer_rows(&transaction);
    if composers.is_empty() {
        return Vec::new();
    }
    let mut sessions = Vec::new();
    for composer in composers {
        let bubble_ids = if composer.bubble_ids.is_empty() {
            cursor_bubble_ids_for_composer(&transaction, &composer.id)
        } else {
            composer.bubble_ids.clone()
        };
        if bubble_ids.is_empty() {
            continue;
        }

        let mut messages = Vec::new();
        for bubble_id in bubble_ids {
            let Some(raw) = cursor_disk_kv_json(
                &transaction,
                &format!("bubbleId:{}:{}", composer.id, bubble_id),
            ) else {
                continue;
            };
            if let Some(message) =
                cursor_message_from_bubble(&raw, &composer.model, path, messages.len())
            {
                messages.push(message);
            }
        }
        if messages.is_empty() {
            continue;
        }

        let mut session = session_from_messages_with_title(
            HistoryAdapter::Cursor,
            path,
            metadata,
            source_kind,
            composer.id.clone(),
            messages,
            composer.title.clone(),
        );
        if let Some(object) = session.as_object_mut() {
            object.insert("model".to_string(), json!(composer.model));
            if let Some(created_at) = composer.created_at {
                object.insert("createdAt".to_string(), json!(created_at));
            }
            if let Some(updated_at) = composer.updated_at {
                object.insert("updatedAt".to_string(), json!(updated_at));
            }
        }
        sessions.push(session);
    }
    sessions
}

#[derive(Clone, Debug)]
pub(super) struct CursorComposerMeta {
    id: String,
    title: Option<String>,
    model: String,
    created_at: Option<String>,
    updated_at: Option<String>,
    bubble_ids: Vec<String>,
}

pub(super) fn cursor_composer_rows(connection: &Connection) -> Vec<CursorComposerMeta> {
    let Ok(mut statement) = connection.prepare(
        "SELECT key, value FROM cursorDiskKV
         WHERE key >= 'composerData:' AND key < 'composerData;'",
    ) else {
        return Vec::new();
    };
    let Ok(rows) = statement.query_map([], |row| {
        Ok((
            sqlite_value_text(row.get_ref(0)?),
            sqlite_value_text(row.get_ref(1)?),
        ))
    }) else {
        return Vec::new();
    };

    let mut composers = Vec::new();
    for (key, value) in rows.flatten() {
        let (Some(key), Some(value)) = (key, value) else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<Value>(&value) else {
            continue;
        };
        let id = json
            .get("composerId")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .or_else(|| {
                key.strip_prefix("composerData:")
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_string)
            });
        let Some(id) = id else {
            continue;
        };
        let model = cursor_composer_model_from_config(&json);
        let title = json
            .get("name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let bubble_ids = json
            .get("fullConversationHeadersOnly")
            .and_then(Value::as_array)
            .map(|headers| {
                headers
                    .iter()
                    .filter_map(|header| {
                        header
                            .get("bubbleId")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|value| !value.is_empty())
                            .map(str::to_string)
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        composers.push(CursorComposerMeta {
            id,
            title,
            model,
            created_at: epoch_value_to_rfc3339(json.get("createdAt").unwrap_or(&Value::Null)),
            updated_at: epoch_value_to_rfc3339(
                json.get("lastUpdatedAt")
                    .or_else(|| json.get("updatedAt"))
                    .unwrap_or(&Value::Null),
            ),
            bubble_ids,
        });
    }
    composers
}

pub(super) fn cursor_bubble_ids_for_composer(
    connection: &Connection,
    composer_id: &str,
) -> Vec<String> {
    let prefix = format!("bubbleId:{}:", composer_id);
    let upper = format!("bubbleId:{};", composer_id);
    let Ok(mut statement) =
        connection.prepare("SELECT key FROM cursorDiskKV WHERE key >= ?1 AND key < ?2")
    else {
        return Vec::new();
    };
    let Ok(rows) = statement.query_map([&prefix, &upper], |row| {
        Ok(sqlite_value_text(row.get_ref(0)?))
    }) else {
        return Vec::new();
    };
    rows.flatten()
        .flatten()
        .filter_map(|key| {
            key.strip_prefix(&prefix)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        })
        .collect()
}

pub(super) fn cursor_disk_kv_json(connection: &Connection, key: &str) -> Option<Value> {
    let value = connection
        .query_row(
            "SELECT value FROM cursorDiskKV WHERE key = ?1 LIMIT 1",
            [key],
            |row| Ok(sqlite_value_text(row.get_ref(0)?)),
        )
        .ok()
        .flatten()?;
    serde_json::from_str(&value).ok()
}
