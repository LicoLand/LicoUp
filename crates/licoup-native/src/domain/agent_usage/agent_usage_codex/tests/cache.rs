use super::super::cache::{cache_is_fresh, open_cache_database};
use super::super::cache_cleanup::reclaim_cache_space;
use super::super::constants::CACHE_SCHEMA_VERSION;
use super::support::temp_dir;
use rusqlite::Connection;
use std::fs;

#[test]
fn schema_mismatch_resets_rows_and_installs_covering_indexes() {
    let root = temp_dir("cache-schema");
    let path = root.join("usage.sqlite3");
    {
        let stale = Connection::open(&path).unwrap();
        stale
            .execute_batch(
                "PRAGMA user_version=6;
                 CREATE TABLE usage_rows (model TEXT NOT NULL);
                 INSERT INTO usage_rows(model) VALUES('stale');",
            )
            .unwrap();
    }
    let connection = open_cache_database(&path).unwrap();
    let version = connection
        .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
        .unwrap();
    let index_sql = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='index' AND name='usage_rows_window'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    assert_eq!(version, CACHE_SCHEMA_VERSION);
    assert!(index_sql.contains("root_key, day"));
    assert!(!index_sql.contains("source_key"));
    let auto_vacuum = connection
        .pragma_query_value(None, "auto_vacuum", |row| row.get::<_, i64>(0))
        .unwrap();
    assert_eq!(auto_vacuum, 2);
}

#[test]
fn freshness_uses_one_root_scoped_scan_timestamp() {
    let root = temp_dir("cache-freshness");
    let path = root.join("usage.sqlite3");
    let connection = open_cache_database(&path).unwrap();
    connection
        .execute(
            "INSERT INTO usage_scans(root_key, last_scan_ms) VALUES(?1, ?2)",
            rusqlite::params!["root", 1_000_i64],
        )
        .unwrap();
    assert!(cache_is_fresh(&connection, "root", 1_001).unwrap());
    assert!(!cache_is_fresh(&connection, "root", 61_001).unwrap());
}

#[test]
fn opening_current_schema_removes_only_obsolete_cache_files() {
    let root = temp_dir("cache-obsolete");
    let stale_path = root.join("agent-usage-cache-v2-stale.sqlite3");
    let current_path = root.join("agent-usage-cache-v2-current.sqlite3");
    let peer_path = root.join("agent-usage-cache-v2-peer.sqlite3");
    Connection::open(&stale_path)
        .unwrap()
        .pragma_update(None, "user_version", CACHE_SCHEMA_VERSION - 1)
        .unwrap();
    open_cache_database(&peer_path).unwrap();
    open_cache_database(&current_path).unwrap();

    assert!(!stale_path.exists());
    assert!(peer_path.exists());
    assert!(current_path.exists());
}

#[test]
fn physical_compaction_truncates_pages_after_bulk_detail_deletion() {
    let root = temp_dir("cache-physical-compaction");
    let path = root.join("usage.sqlite3");
    let mut connection = open_cache_database(&path).unwrap();
    let transaction = connection.transaction().unwrap();
    {
        let mut insert = transaction
            .prepare(
                "INSERT INTO usage_rows VALUES(
                   'root',?1,?2,NULL,NULL,'2026-01-01',NULL,1,0,1,?3
                 )",
            )
            .unwrap();
        let padding = "x".repeat(512);
        for index in 0..10_000_i64 {
            insert
                .execute(rusqlite::params![format!("source-{index}"), index, padding])
                .unwrap();
        }
    }
    transaction.commit().unwrap();
    connection
        .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
        .unwrap();
    let expanded = fs::metadata(&path).unwrap().len();
    connection.execute("DELETE FROM usage_rows", []).unwrap();
    reclaim_cache_space(&connection).unwrap();
    let compacted = fs::metadata(&path).unwrap().len();

    assert!(
        compacted < expanded / 2,
        "cache file was not truncated: {expanded} -> {compacted}"
    );
}
