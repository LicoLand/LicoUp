use std::fs;
use std::path::Path;

use serde_json::Value;

use super::super::{HistoryAdapter, HistoryScanConfig};
use super::codec::open_read_only_connection;
use super::cursor::parse_cursor_sqlite_sessions;
use super::cursor_cli::parse_cursor_cli_store_sessions;
use super::fallback::parse_generic_sqlite_sessions;
use super::openagent::parse_openagent_sqlite_sessions;

pub(crate) fn parse_sqlite_sessions(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    metadata: &fs::Metadata,
    scan_config: HistoryScanConfig,
) -> Vec<Value> {
    let Some(mut connection) = open_read_only_connection(path) else {
        return Vec::new();
    };
    if matches!(adapter, HistoryAdapter::OpenCode | HistoryAdapter::KiloCode) {
        let precise_sessions =
            parse_openagent_sqlite_sessions(adapter, path, source_kind, metadata, &mut connection);
        if !precise_sessions.is_empty() {
            return precise_sessions;
        }
    }
    if adapter == HistoryAdapter::Cursor {
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name == "store.db")
        {
            let precise_sessions =
                parse_cursor_cli_store_sessions(path, source_kind, metadata, &connection);
            if !precise_sessions.is_empty() {
                return precise_sessions;
            }
        }
        let precise_sessions =
            parse_cursor_sqlite_sessions(path, source_kind, metadata, &mut connection);
        if !precise_sessions.is_empty() {
            return precise_sessions;
        }
    }
    parse_generic_sqlite_sessions(
        adapter,
        path,
        source_kind,
        metadata,
        &scan_config,
        &connection,
    )
}
