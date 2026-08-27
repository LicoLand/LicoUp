use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;
use serde_json::json;

use super::super::super::{HistoryAdapter, HistoryPageConfig, HistoryScanConfig};
use super::super::composition::{
    CopilotChatSessionsReadError, copilot_chat_sessions_document, parse_sqlite_sessions,
};

#[test]
fn public_composition_opens_locally_and_routes_to_generic_fallback() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let path = std::env::temp_dir().join(format!("lico-sqlite-composition-{unique}.db"));
    let connection = Connection::open(&path).expect("database");
    connection
        .execute("CREATE TABLE ItemTable (key TEXT, value TEXT)", [])
        .expect("table");
    connection
        .execute(
            "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
            ["chat.first", "user message: routed prompt"],
        )
        .expect("row");
    drop(connection);
    let metadata = fs::metadata(&path).expect("metadata");
    let sessions = parse_sqlite_sessions(
        HistoryAdapter::Cursor,
        &path,
        "sqlite",
        &metadata,
        HistoryScanConfig {
            archive_mode: false,
            session_ids: Vec::new(),
            match_terms: Vec::new(),
            match_project_paths: Vec::new(),
            page: HistoryPageConfig {
                offset: 0,
                limit: None,
            },
        },
    );
    assert_eq!(sessions.len(), 1);
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn copilot_document_reader_accepts_payloads_beyond_the_removed_cap_and_case_drift() {
    let connection = Connection::open_in_memory().expect("database");
    connection
        .execute("CREATE TABLE itemtable (key TEXT, value TEXT)", [])
        .expect("table");
    let payload = json!({
        "chatSessions": [{
            "id": "large-session",
            "messages": [{"role": "user", "content": "x".repeat(33 * 1024 * 1024)}]
        }]
    })
    .to_string();
    connection
        .execute(
            "INSERT INTO itemtable (key, value) VALUES (?1, ?2)",
            ["GITHUB.COPILOT-CHAT.CHATSESSIONS", payload.as_str()],
        )
        .expect("row");

    let document = copilot_chat_sessions_document(&connection)
        .expect("read")
        .expect("document");
    assert_eq!(document["chatSessions"][0]["id"], "large-session");
}

#[test]
fn copilot_document_reader_distinguishes_invalid_payloads_from_missing_rows() {
    let connection = Connection::open_in_memory().expect("database");
    connection
        .execute("CREATE TABLE ItemTable (key TEXT, value TEXT)", [])
        .expect("table");
    assert_eq!(copilot_chat_sessions_document(&connection), Ok(None));
    connection
        .execute(
            "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
            ["github.copilot-chat.chatSessions", "not-json"],
        )
        .expect("row");
    assert_eq!(
        copilot_chat_sessions_document(&connection),
        Err(CopilotChatSessionsReadError::InvalidPayload)
    );
}
