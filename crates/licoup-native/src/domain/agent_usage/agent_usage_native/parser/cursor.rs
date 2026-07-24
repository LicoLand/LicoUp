use super::{opaque_scope, read_only_connection, sqlite_table_exists};
use crate::domain::agent_usage::attribution::message_usage;
use crate::domain::agent_usage::contract::HistoryUsageSummary;
use crate::domain::agent_usage::window::UsageWindow;
use crate::domain::conversation::usage::extract_token_usage;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

const COMPOSER_RECORD_QUERY: &str = "SELECT key,
            CASE WHEN json_valid(CAST(value AS TEXT))
              THEN CAST(json_extract(CAST(value AS TEXT), '$.modelConfig') AS TEXT)
            END
     FROM cursorDiskKV
     WHERE key >= 'composerData:' AND key < 'composerData;'";

const BUBBLE_USAGE_QUERY: &str = "SELECT key,
            CASE WHEN json_valid(CAST(value AS TEXT)) THEN CAST(COALESCE(
              json_extract(CAST(value AS TEXT), '$.createdAt'),
              json_extract(CAST(value AS TEXT), '$.created_at'),
              json_extract(CAST(value AS TEXT), '$.timestamp'),
              json_extract(CAST(value AS TEXT), '$.time')
            ) AS TEXT) END,
            CASE WHEN json_valid(CAST(value AS TEXT))
              THEN CAST(json_extract(CAST(value AS TEXT), '$.tokenCount') AS TEXT)
            END,
            CASE WHEN json_valid(CAST(value AS TEXT)) THEN CAST(COALESCE(
              json_extract(CAST(value AS TEXT), '$.modelInfo.modelName'),
              json_extract(CAST(value AS TEXT), '$.modelName'),
              json_extract(CAST(value AS TEXT), '$.model')
            ) AS TEXT) END
     FROM cursorDiskKV
     WHERE key >= 'bubbleId:' AND key < 'bubbleId;'
       AND CASE WHEN json_valid(CAST(value AS TEXT))
         THEN json_type(CAST(value AS TEXT), '$.tokenCount') IS NOT NULL
         ELSE 0 END";

/// Cursor keeps exact request counters in `cursorDiskKV` bubble metadata. This
/// projection asks SQLite only for token/model/time fields; conversation text is
/// never returned to the usage scanner.
pub(super) fn parse_cursor_usage_database(
    path: &Path,
    calendar: &UsageWindow,
) -> Option<HistoryUsageSummary> {
    let connection = read_only_connection(path)?;
    if !sqlite_table_exists(&connection, "cursorDiskKV") {
        return None;
    }

    let mut composer_models = BTreeMap::<String, String>::new();
    let mut composer_statement = connection.prepare(COMPOSER_RECORD_QUERY).ok()?;
    let composer_rows = composer_statement
        .query_map([], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
            ))
        })
        .ok()?;
    for (key, config) in composer_rows.flatten() {
        let Some(id) = key
            .as_deref()
            .and_then(|value| value.strip_prefix("composerData:"))
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        let parsed = config
            .as_deref()
            .and_then(|value| serde_json::from_str::<Value>(value).ok())
            .unwrap_or(Value::Null);
        composer_models.insert(id.to_owned(), cursor_model_from_config(&parsed));
    }
    drop(composer_statement);

    let mut bubble_statement = connection.prepare(BUBBLE_USAGE_QUERY).ok()?;
    let bubble_rows = bubble_statement
        .query_map([], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })
        .ok()?;
    let mut summary = HistoryUsageSummary::default();
    let mut sessions = BTreeSet::<String>::new();
    for (key, timestamp, token_count, bubble_model) in bubble_rows.flatten() {
        let (Some(key), Some(timestamp), Some(token_count)) = (key, timestamp, token_count) else {
            continue;
        };
        let Some(day) = calendar.date_key(&timestamp) else {
            continue;
        };
        if !calendar.contains(&day) {
            continue;
        }
        let Some(composer_id) = cursor_composer_id_from_bubble_key(&key) else {
            continue;
        };
        let Ok(token_count) = serde_json::from_str::<Value>(&token_count) else {
            continue;
        };
        let Some(normalized) = extract_token_usage(&token_count) else {
            continue;
        };
        let model = normalize_cursor_model(bubble_model.as_deref())
            .or_else(|| composer_models.get(composer_id).cloned())
            .or_else(|| Some("cursor-auto".to_owned()));
        let envelope = json!({"model": model, "usage": normalized});
        let Some(usage) = message_usage(&envelope, model) else {
            continue;
        };
        summary.add(usage, Some(day));
        sessions.insert(opaque_scope(composer_id));
    }
    summary.session_count = sessions.len() as u64;
    summary.message_count = summary.explicit_records;
    Some(summary)
}

fn cursor_composer_id_from_bubble_key(key: &str) -> Option<&str> {
    key.strip_prefix("bubbleId:")?
        .split_once(':')
        .map(|(composer_id, _)| composer_id.trim())
        .filter(|value| !value.is_empty())
}

fn cursor_model_from_config(config: &Value) -> String {
    if let Some(selected) = config.get("selectedModels").and_then(Value::as_array) {
        for candidate in selected {
            if let Some(model) = candidate
                .get("modelId")
                .and_then(Value::as_str)
                .and_then(|value| normalize_cursor_model(Some(value)))
            {
                return model;
            }
        }
    }
    normalize_cursor_model(config.get("modelName").and_then(Value::as_str))
        .unwrap_or_else(|| "cursor-auto".to_owned())
}

fn normalize_cursor_model(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case("default"))
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    #[test]
    fn cursor_record_queries_use_indexed_prefix_ranges() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE cursorDiskKV (
                   key TEXT PRIMARY KEY,
                   value BLOB NOT NULL
                 );",
            )
            .unwrap();

        for query in [COMPOSER_RECORD_QUERY, BUBBLE_USAGE_QUERY] {
            let mut statement = connection
                .prepare(&format!("EXPLAIN QUERY PLAN {query}"))
                .unwrap();
            let plan = statement
                .query_map([], |row| row.get::<_, String>(3))
                .unwrap()
                .flatten()
                .collect::<Vec<_>>()
                .join(" ");
            assert!(plan.contains("SEARCH cursorDiskKV"), "{plan}");
            assert!(!plan.contains("SCAN cursorDiskKV"), "{plan}");
        }
    }
}
