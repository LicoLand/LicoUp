use std::path::Path;

use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags, Row};
use serde_json::{Value, json};

pub(super) const MAX_SQLITE_FIELDS_PER_ROW: usize = 256;
pub(super) const MAX_SQLITE_FIELD_NAME_BYTES: usize = 256;
pub(super) const MAX_SQLITE_VALUE_BYTES: usize = 4 * 1024 * 1024;
pub(super) const MAX_SQLITE_ROW_BYTES: usize = 8 * 1024 * 1024;

pub(super) fn open_read_only_connection(path: &Path) -> Option<Connection> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()
}

pub(super) fn sqlite_table_exists(connection: &Connection, table: &str) -> bool {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1",
            [table],
            |_| Ok(()),
        )
        .is_ok()
}

pub(super) fn sqlite_row_fields(row: &Row<'_>, column_names: &[String]) -> Vec<(String, String)> {
    let mut fields = Vec::new();
    let mut row_bytes = 0usize;
    for (index, name) in column_names
        .iter()
        .take(MAX_SQLITE_FIELDS_PER_ROW)
        .enumerate()
    {
        if name.len() > MAX_SQLITE_FIELD_NAME_BYTES {
            continue;
        }
        let Some(value) = row.get_ref(index).ok().and_then(sqlite_value_text) else {
            continue;
        };
        if value.trim().is_empty() {
            continue;
        }
        let field_bytes = name.len().saturating_add(value.len());
        let Some(next_bytes) = row_bytes.checked_add(field_bytes) else {
            break;
        };
        if next_bytes > MAX_SQLITE_ROW_BYTES {
            break;
        }
        row_bytes = next_bytes;
        fields.push((name.clone(), value));
    }
    fields
}

pub(super) fn sqlite_row_key(fields: &[(String, String)]) -> Option<String> {
    for preferred in [
        "key",
        "id",
        "sessionId",
        "session_id",
        "sessionKey",
        "session_key",
        "conversationId",
    ] {
        if let Some((_, value)) = fields
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(preferred))
            && !value.trim().is_empty()
        {
            return Some(value.trim().to_string());
        }
    }
    None
}

pub(super) fn sqlite_fields_json(fields: &[(String, String)]) -> Value {
    let mut object = serde_json::Map::<String, Value>::new();
    for (name, value) in fields.iter().take(MAX_SQLITE_FIELDS_PER_ROW) {
        object.insert(name.clone(), json!(value));
    }
    Value::Object(object)
}

pub(super) fn sqlite_value_text(value: ValueRef<'_>) -> Option<String> {
    match value {
        ValueRef::Null => Some(String::new()),
        ValueRef::Integer(value) => Some(value.to_string()),
        ValueRef::Real(value) => Some(value.to_string()),
        ValueRef::Text(value) | ValueRef::Blob(value) => {
            if value.len() > MAX_SQLITE_VALUE_BYTES {
                None
            } else {
                Some(String::from_utf8_lossy(value).into_owned())
            }
        }
    }
}
