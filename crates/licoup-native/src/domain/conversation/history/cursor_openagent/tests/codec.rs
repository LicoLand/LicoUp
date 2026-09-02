use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;
use rusqlite::types::ValueRef;

use super::super::codec::{
    MAX_SQLITE_FIELDS_PER_ROW, MAX_SQLITE_VALUE_BYTES, open_read_only_connection,
    sqlite_fields_json, sqlite_row_key, sqlite_value_text,
};

#[test]
fn value_and_field_codecs_enforce_explicit_memory_bounds() {
    assert_eq!(
        sqlite_value_text(ValueRef::Text(b"visible")).as_deref(),
        Some("visible")
    );
    let oversized = vec![b'x'; MAX_SQLITE_VALUE_BYTES + 1];
    assert!(sqlite_value_text(ValueRef::Blob(&oversized)).is_none());

    let fields = (0..=MAX_SQLITE_FIELDS_PER_ROW)
        .map(|index| (format!("field-{index}"), "value".to_string()))
        .collect::<Vec<_>>();
    assert_eq!(
        sqlite_fields_json(&fields).as_object().unwrap().len(),
        MAX_SQLITE_FIELDS_PER_ROW
    );
    assert_eq!(
        sqlite_row_key(&[("session_id".to_string(), " session-1 ".to_string())]).as_deref(),
        Some("session-1")
    );
}

#[test]
fn sqlite_connection_is_opened_read_only() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let path = std::env::temp_dir().join(format!("lico-read-only-sqlite-{unique}.db"));
    let writable = Connection::open(&path).expect("create database");
    writable
        .execute("CREATE TABLE sample (value TEXT)", [])
        .expect("create table");
    drop(writable);

    let read_only = open_read_only_connection(&path).expect("open read-only");
    assert!(
        read_only
            .execute("INSERT INTO sample (value) VALUES ('blocked')", [])
            .is_err()
    );
    drop(read_only);
    fs::remove_file(path).expect("remove fixture");
}
