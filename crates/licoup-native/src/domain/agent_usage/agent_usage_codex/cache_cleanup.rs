use super::constants::{CACHE_DATABASE_PREFIX, CACHE_SCHEMA_VERSION};
use anyhow::{Context, Result};
use rusqlite::Connection;
use std::fs;
use std::path::Path;

pub(super) fn remove_obsolete_cache_databases(active_path: &Path) -> Result<()> {
    let Some(directory) = active_path.parent() else {
        return Ok(());
    };
    let Ok(entries) = fs::read_dir(directory) else {
        return Ok(());
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path == active_path
            || path.extension().and_then(|value| value.to_str()) != Some("sqlite3")
            || !path
                .file_name()
                .and_then(|value| value.to_str())
                .is_some_and(|value| value.starts_with(CACHE_DATABASE_PREFIX))
        {
            continue;
        }
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            continue;
        }
        let Ok(stale) = Connection::open_with_flags(
            &path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        ) else {
            continue;
        };
        let version = stale
            .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap_or(CACHE_SCHEMA_VERSION);
        drop(stale);
        if version >= CACHE_SCHEMA_VERSION {
            continue;
        }
        fs::remove_file(&path)?;
        for suffix in ["-wal", "-shm"] {
            let sidecar = Path::new(&format!("{}{suffix}", path.to_string_lossy())).to_path_buf();
            if sidecar.try_exists().unwrap_or(false) {
                fs::remove_file(sidecar)?;
            }
        }
    }
    Ok(())
}

pub(super) fn reclaim_cache_space(connection: &Connection) -> Result<()> {
    connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    let page_count =
        connection.pragma_query_value(None, "page_count", |row| row.get::<_, u64>(0))?;
    let free_pages =
        connection.pragma_query_value(None, "freelist_count", |row| row.get::<_, u64>(0))?;
    if page_count > 0 && free_pages.saturating_mul(4) >= page_count {
        // A bulk first-time rollup can free most pages. Routine daily cleanup
        // uses incremental vacuum and never rewrites the whole database.
        connection.execute_batch("VACUUM;")?;
    } else if free_pages > 0 {
        connection.execute_batch("PRAGMA incremental_vacuum(256);")?;
    }
    connection
        .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
        .context("agent usage cache compaction failed")?;
    Ok(())
}
