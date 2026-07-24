use std::fs;
use std::path::Path;
use std::time::SystemTime;

use rusqlite::Connection;
use serde_json::{Value, json};

use super::super::generic::{collect_messages_from_value, push_grouped_message};
use super::super::query_filter::{display_path, extract_json_from_text, message_id, system_time};
use super::super::session_metadata::session_from_messages;
use super::super::{
    ARCHIVE_SQLITE_PAGE_ROWS, HistoryAdapter, HistoryScanConfig, MAX_SQLITE_ROWS_PER_TABLE,
};
use super::codec::{sqlite_fields_json, sqlite_row_fields, sqlite_row_key};

pub(super) fn parse_generic_sqlite_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    scan_config: &HistoryScanConfig,
    connection: &Connection,
) -> Vec<Value> {
    let mut sessions = Vec::<Value>::new();
    let mut table_statement = match connection
        .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    {
        Ok(statement) => statement,
        Err(_) => return sessions,
    };
    let table_names = table_statement
        .query_map([], |row| row.get::<_, String>(0))
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter(|name| adapter.sqlite_table_may_hold_history(name))
        .collect::<Vec<_>>();

    for table in table_names {
        let mut grouped = Vec::<(String, Vec<Value>)>::new();
        let mut total_index = 0usize;
        let mut offset = 0usize;
        loop {
            let limit = if scan_config.archive_mode {
                ARCHIVE_SQLITE_PAGE_ROWS
            } else {
                MAX_SQLITE_ROWS_PER_TABLE
            };
            let query = format!(
                "SELECT * FROM \"{}\" LIMIT {} OFFSET {}",
                table.replace('"', "\"\""),
                limit,
                offset
            );
            let mut statement = match connection.prepare(&query) {
                Ok(statement) => statement,
                Err(_) => break,
            };
            let column_names = statement
                .column_names()
                .iter()
                .map(|name| name.to_string())
                .collect::<Vec<_>>();
            let rows =
                match statement.query_map([], |row| Ok(sqlite_row_fields(row, &column_names))) {
                    Ok(rows) => rows,
                    Err(_) => break,
                };
            let page = rows.filter_map(Result::ok).collect::<Vec<_>>();
            let page_len = page.len();
            for fields in page {
                let index = total_index;
                total_index += 1;
                let row_text = fields
                    .iter()
                    .map(|(name, value)| format!("{}: {}", name, value))
                    .collect::<Vec<_>>()
                    .join("\n");
                let row_key = sqlite_row_key(&fields);
                if !adapter.sqlite_row_may_hold_history(&table, row_key.as_deref(), &row_text) {
                    continue;
                }
                let source_fields = sqlite_fields_json(&fields);
                let session_id = row_key
                    .clone()
                    .unwrap_or_else(|| format!("{}:{}", table, index));
                let row_key_value = row_key.unwrap_or_default();
                let mut row_messages = Vec::<Value>::new();
                if let Some(json_value) = extract_json_from_text(&row_text) {
                    collect_messages_from_value(adapter, path, &json_value, &mut row_messages);
                }
                if row_messages.is_empty() {
                    row_messages.push(json!({
                        "id": message_id(adapter.id(), path, index),
                        "role": "record",
                        "text": row_text,
                        "createdAt": system_time(metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH)),
                        "sourcePath": display_path(path),
                        "sourceTable": table,
                        "sourceKey": row_key_value.clone(),
                        "sourceFields": source_fields.clone()
                    }));
                }
                for mut message in row_messages {
                    if let Some(object) = message.as_object_mut() {
                        object
                            .entry("sourceTable".to_string())
                            .or_insert_with(|| json!(table.clone()));
                        object
                            .entry("sourceKey".to_string())
                            .or_insert_with(|| json!(row_key_value.clone()));
                        object
                            .entry("sourceFields".to_string())
                            .or_insert_with(|| source_fields.clone());
                    }
                    push_grouped_message(&mut grouped, session_id.clone(), message);
                }
            }
            if !scan_config.archive_mode || page_len < limit {
                break;
            }
            offset += limit;
        }
        for (native_session_id, messages) in grouped {
            sessions.push(session_from_messages(
                adapter,
                path,
                metadata,
                source_kind,
                native_session_id,
                messages,
            ));
        }
    }
    sessions
}
