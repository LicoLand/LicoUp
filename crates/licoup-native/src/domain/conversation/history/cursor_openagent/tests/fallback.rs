use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;

use super::super::super::{HistoryAdapter, HistoryPageConfig, HistoryScanConfig};
use super::super::fallback::parse_generic_sqlite_sessions;

#[test]
fn generic_fallback_projects_only_adapter_accepted_rows() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let path = std::env::temp_dir().join(format!("lico-sqlite-fallback-{unique}.db"));
    let connection = Connection::open(&path).expect("database");
    connection
        .execute("CREATE TABLE ItemTable (key TEXT, value TEXT)", [])
        .expect("table");
    connection
        .execute(
            "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
            ["chat.first", "user message: visible prompt"],
        )
        .expect("accepted row");
    connection
        .execute(
            "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
            ["settings.theme", "dark"],
        )
        .expect("rejected row");
    let metadata = fs::metadata(&path).expect("metadata");
    let sessions = parse_generic_sqlite_sessions(
        HistoryAdapter::Cursor,
        &path,
        "sqlite",
        &metadata,
        &HistoryScanConfig {
            archive_mode: false,
            session_ids: Vec::new(),
            match_terms: Vec::new(),
            match_project_paths: Vec::new(),
            page: HistoryPageConfig {
                offset: 0,
                limit: None,
            },
        },
        &connection,
    );
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], "chat.first");
    drop(connection);
    fs::remove_file(path).expect("remove fixture");
}
