use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;

use super::super::super::{HistoryAdapter, HistoryPageConfig, HistoryScanConfig};
use super::super::composition::parse_sqlite_sessions;

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
