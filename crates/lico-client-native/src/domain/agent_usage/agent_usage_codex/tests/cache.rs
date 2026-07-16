use super::super::cache::{cache_is_fresh, open_cache_database};
use super::super::constants::CACHE_SCHEMA_VERSION;
use super::support::temp_dir;
use rusqlite::Connection;

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
    assert!(index_sql.contains("root_key, day, source_key, event_index"));
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
