//! Private aggregate-cache ownership for native usage sources.

use super::super::contract::HistoryUsageSummary;
use super::super::window::UsageWindow;
use super::models::{CachedSource, SourceMetadata};
use anyhow::{Context, Result};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use std::collections::BTreeMap;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub(super) const CACHE_SCHEMA_VERSION: i64 = 7;
pub(super) const CACHE_FILE_NAME: &str = "agent-usage-rollups-v2.sqlite3";
const LEGACY_CACHE_FILE_NAME: &str = "agent-usage-exact-v1.sqlite3";

pub(super) fn cache_path(state_root: &Path) -> PathBuf {
    state_root.join(CACHE_FILE_NAME)
}

pub(super) fn open_cache_database(path: &Path) -> Result<Connection> {
    remove_legacy_cache(path)?;
    let mut connection = Connection::open(path).context("native usage cache open failed")?;
    connection.busy_timeout(Duration::from_secs(30))?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    let version =
        connection.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))?;
    if version != CACHE_SCHEMA_VERSION {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch(
            "DROP TABLE IF EXISTS native_usage_sources;
             DROP TABLE IF EXISTS native_usage_source_days;
             DROP TABLE IF EXISTS native_usage_source_models;
             DROP TABLE IF EXISTS native_usage_daily_totals;
             DROP TABLE IF EXISTS native_usage_daily_models;
             DROP TABLE IF EXISTS native_usage_scans;
             DROP TABLE IF EXISTS native_usage_watermarks;
             CREATE TABLE native_usage_sources (
               scope_key TEXT NOT NULL,
               source_key TEXT NOT NULL,
               modified_ns INTEGER NOT NULL,
               size INTEGER NOT NULL,
               file_id TEXT,
               parsed_bytes INTEGER NOT NULL,
               append_guard TEXT NOT NULL,
               session_count INTEGER NOT NULL,
               sealed INTEGER NOT NULL DEFAULT 0,
               PRIMARY KEY(scope_key, source_key)
             );
             CREATE TABLE native_usage_source_days (
               scope_key TEXT NOT NULL,
               source_key TEXT NOT NULL,
               day TEXT NOT NULL,
               prompt_tokens INTEGER NOT NULL,
               cached_input_tokens INTEGER NOT NULL,
               completion_tokens INTEGER NOT NULL,
               estimated_prompt_tokens INTEGER NOT NULL,
               estimated_completion_tokens INTEGER NOT NULL,
               explicit_records INTEGER NOT NULL,
               estimated_records INTEGER NOT NULL,
               message_count INTEGER NOT NULL,
               PRIMARY KEY(scope_key, source_key, day)
             );
             CREATE INDEX native_usage_source_days_window
               ON native_usage_source_days(scope_key, day);
             CREATE TABLE native_usage_source_models (
               scope_key TEXT NOT NULL,
               source_key TEXT NOT NULL,
               day TEXT NOT NULL,
               model TEXT NOT NULL,
               prompt_tokens INTEGER NOT NULL,
               cached_input_tokens INTEGER NOT NULL,
               completion_tokens INTEGER NOT NULL,
               total_tokens INTEGER NOT NULL,
               estimated_prompt_tokens INTEGER NOT NULL,
               estimated_completion_tokens INTEGER NOT NULL,
               PRIMARY KEY(scope_key, source_key, day, model)
             );
             CREATE INDEX native_usage_source_models_window
               ON native_usage_source_models(scope_key, day);
             CREATE TABLE native_usage_daily_totals (
               scope_key TEXT NOT NULL,
               day TEXT NOT NULL,
               prompt_tokens INTEGER NOT NULL,
               cached_input_tokens INTEGER NOT NULL,
               completion_tokens INTEGER NOT NULL,
               estimated_prompt_tokens INTEGER NOT NULL,
               estimated_completion_tokens INTEGER NOT NULL,
               explicit_records INTEGER NOT NULL,
               estimated_records INTEGER NOT NULL,
               message_count INTEGER NOT NULL,
               session_count INTEGER NOT NULL,
               PRIMARY KEY(scope_key, day)
             );
             CREATE TABLE native_usage_daily_models (
               scope_key TEXT NOT NULL,
               day TEXT NOT NULL,
               model TEXT NOT NULL,
               prompt_tokens INTEGER NOT NULL,
               cached_input_tokens INTEGER NOT NULL,
               completion_tokens INTEGER NOT NULL,
               total_tokens INTEGER NOT NULL,
               estimated_prompt_tokens INTEGER NOT NULL,
               estimated_completion_tokens INTEGER NOT NULL,
               PRIMARY KEY(scope_key, day, model)
             );
             CREATE TABLE native_usage_scans (
               scope_key TEXT PRIMARY KEY,
               last_scan_ms INTEGER NOT NULL
             );
             CREATE TABLE native_usage_watermarks (
               scope_key TEXT NOT NULL,
               source_key TEXT NOT NULL,
               usage_key TEXT NOT NULL,
               session_key TEXT NOT NULL,
               model TEXT,
               day TEXT NOT NULL,
               last_prompt INTEGER NOT NULL,
               last_cached INTEGER NOT NULL,
               last_completion INTEGER NOT NULL,
               day_prompt INTEGER NOT NULL,
               day_cached INTEGER NOT NULL,
               day_completion INTEGER NOT NULL,
               PRIMARY KEY(scope_key, source_key, usage_key)
             );",
        )?;
        transaction.pragma_update(None, "user_version", CACHE_SCHEMA_VERSION)?;
        transaction.commit()?;
        connection.pragma_update(None, "auto_vacuum", "INCREMENTAL")?;
        connection.execute_batch("VACUUM")?;
    }
    #[cfg(unix)]
    if path.exists() {
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(connection)
}

fn remove_legacy_cache(path: &Path) -> Result<()> {
    if path.file_name().and_then(|value| value.to_str()) != Some(CACHE_FILE_NAME) {
        return Ok(());
    }
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    for suffix in ["", "-wal", "-shm"] {
        let candidate = parent.join(format!("{LEGACY_CACHE_FILE_NAME}{suffix}"));
        match fs::remove_file(&candidate) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error).context("legacy native usage cache removal failed"),
        }
    }
    Ok(())
}

pub(super) fn cache_is_fresh(
    connection: &Connection,
    scope_key: &str,
    now_ms: u64,
    interval_ms: u64,
) -> Result<bool> {
    let last = connection
        .query_row(
            "SELECT last_scan_ms FROM native_usage_scans WHERE scope_key=?1",
            [scope_key],
            |row| row.get::<_, i64>(0),
        )
        .optional()?;
    Ok(last.is_some_and(|last| now_ms.saturating_sub(from_i64(last)) < interval_ms))
}

pub(super) fn cache_has_baseline(connection: &Connection, scope_key: &str) -> Result<bool> {
    connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM native_usage_scans WHERE scope_key=?1)",
            [scope_key],
            |row| row.get::<_, bool>(0),
        )
        .map_err(Into::into)
}

pub(super) fn load_sources(
    transaction: &Transaction<'_>,
    scope_key: &str,
) -> Result<BTreeMap<String, CachedSource>> {
    let mut statement = transaction.prepare(
        "SELECT source_key, modified_ns, size, file_id, parsed_bytes, append_guard,
                session_count, sealed
         FROM native_usage_sources WHERE scope_key=?1",
    )?;
    let rows = statement.query_map([scope_key], |row| {
        Ok((
            row.get::<_, String>(0)?,
            CachedSource {
                modified_ns: from_i64(row.get(1)?),
                size: from_i64(row.get(2)?),
                file_id: row.get(3)?,
                parsed_bytes: from_i64(row.get(4)?),
                append_guard: row.get(5)?,
                session_count: from_i64(row.get(6)?),
                sealed: row.get::<_, i64>(7)? != 0,
            },
        ))
    })?;
    rows.collect::<rusqlite::Result<BTreeMap<_, _>>>()
        .map_err(Into::into)
}

pub(super) fn replace_source_rollup(
    transaction: &Transaction<'_>,
    scope_key: &str,
    source_key: &str,
    summary: &HistoryUsageSummary,
) -> Result<()> {
    transaction.execute(
        "DELETE FROM native_usage_source_days WHERE scope_key=?1 AND source_key=?2",
        params![scope_key, source_key],
    )?;
    transaction.execute(
        "DELETE FROM native_usage_source_models WHERE scope_key=?1 AND source_key=?2",
        params![scope_key, source_key],
    )?;
    add_source_rollup(transaction, scope_key, source_key, summary)
}

pub(super) fn add_source_rollup(
    transaction: &Transaction<'_>,
    scope_key: &str,
    source_key: &str,
    summary: &HistoryUsageSummary,
) -> Result<()> {
    for (day, usage) in &summary.daily_usage {
        if usage.total_tokens == 0
            || usage
                .explicit_records
                .saturating_add(usage.estimated_records)
                == 0
        {
            continue;
        }
        transaction.execute(
            "INSERT INTO native_usage_source_days VALUES(
               ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11
             )
             ON CONFLICT(scope_key,source_key,day) DO UPDATE SET
               prompt_tokens=prompt_tokens+excluded.prompt_tokens,
               cached_input_tokens=cached_input_tokens+excluded.cached_input_tokens,
               completion_tokens=completion_tokens+excluded.completion_tokens,
               estimated_prompt_tokens=estimated_prompt_tokens+excluded.estimated_prompt_tokens,
               estimated_completion_tokens=estimated_completion_tokens+excluded.estimated_completion_tokens,
               explicit_records=explicit_records+excluded.explicit_records,
               estimated_records=estimated_records+excluded.estimated_records,
               message_count=message_count+excluded.message_count",
            params![
                scope_key,
                source_key,
                day,
                to_i64(usage.prompt_tokens),
                to_i64(usage.cached_input_tokens.min(usage.prompt_tokens)),
                to_i64(usage.completion_tokens),
                to_i64(usage.estimated_prompt_tokens),
                to_i64(usage.estimated_completion_tokens),
                to_i64(usage.explicit_records),
                to_i64(usage.estimated_records),
                to_i64(usage.message_count),
            ],
        )?;
        for (model, model_usage) in &usage.model_usage {
            transaction.execute(
                "INSERT INTO native_usage_source_models VALUES(
                   ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10
                 )
                 ON CONFLICT(scope_key,source_key,day,model) DO UPDATE SET
                   prompt_tokens=prompt_tokens+excluded.prompt_tokens,
                   cached_input_tokens=cached_input_tokens+excluded.cached_input_tokens,
                   completion_tokens=completion_tokens+excluded.completion_tokens,
                   total_tokens=total_tokens+excluded.total_tokens,
                   estimated_prompt_tokens=estimated_prompt_tokens+excluded.estimated_prompt_tokens,
                   estimated_completion_tokens=estimated_completion_tokens+excluded.estimated_completion_tokens",
                params![
                    scope_key,
                    source_key,
                    day,
                    model,
                    to_i64(model_usage.prompt_tokens),
                    to_i64(
                        model_usage
                            .cached_input_tokens
                            .min(model_usage.prompt_tokens)
                    ),
                    to_i64(model_usage.completion_tokens),
                    to_i64(model_usage.total_tokens),
                    to_i64(model_usage.estimated_prompt_tokens),
                    to_i64(model_usage.estimated_completion_tokens),
                ],
            )?;
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn save_source(
    transaction: &Transaction<'_>,
    scope_key: &str,
    source_key: &str,
    metadata: &SourceMetadata,
    parsed_bytes: u64,
    append_guard: &str,
    session_count: u64,
    sealed: bool,
) -> Result<()> {
    transaction.execute(
        "INSERT INTO native_usage_sources VALUES(
           ?1,?2,?3,?4,?5,?6,?7,?8,?9
         ) ON CONFLICT(scope_key,source_key) DO UPDATE SET
           modified_ns=excluded.modified_ns,
           size=excluded.size,
           file_id=excluded.file_id,
           parsed_bytes=excluded.parsed_bytes,
           append_guard=excluded.append_guard,
           session_count=excluded.session_count,
           sealed=excluded.sealed",
        params![
            scope_key,
            source_key,
            to_i64(metadata.modified_ns),
            to_i64(metadata.size),
            metadata.file_id,
            to_i64(parsed_bytes),
            append_guard,
            to_i64(session_count),
            i64::from(sealed),
        ],
    )?;
    Ok(())
}

pub(super) fn seal_source(
    transaction: &Transaction<'_>,
    scope_key: &str,
    source_key: &str,
    session_count: u64,
) -> Result<()> {
    let first_day = transaction.query_row(
        "SELECT MIN(day) FROM native_usage_source_days
             WHERE scope_key=?1 AND source_key=?2",
        params![scope_key, source_key],
        |row| row.get::<_, Option<String>>(0),
    )?;
    transaction.execute(
        "INSERT INTO native_usage_daily_totals
           SELECT scope_key, day, prompt_tokens, cached_input_tokens,
                  completion_tokens, estimated_prompt_tokens,
                  estimated_completion_tokens, explicit_records,
                  estimated_records, message_count, 0
           FROM native_usage_source_days WHERE scope_key=?1 AND source_key=?2
         ON CONFLICT(scope_key,day) DO UPDATE SET
           prompt_tokens=prompt_tokens+excluded.prompt_tokens,
           cached_input_tokens=cached_input_tokens+excluded.cached_input_tokens,
           completion_tokens=completion_tokens+excluded.completion_tokens,
           estimated_prompt_tokens=estimated_prompt_tokens+excluded.estimated_prompt_tokens,
           estimated_completion_tokens=estimated_completion_tokens+excluded.estimated_completion_tokens,
           explicit_records=explicit_records+excluded.explicit_records,
           estimated_records=estimated_records+excluded.estimated_records,
           message_count=message_count+excluded.message_count",
        params![scope_key, source_key],
    )?;
    transaction.execute(
        "INSERT INTO native_usage_daily_models
           SELECT scope_key, day, model, prompt_tokens, cached_input_tokens,
                  completion_tokens, total_tokens, estimated_prompt_tokens,
                  estimated_completion_tokens
           FROM native_usage_source_models WHERE scope_key=?1 AND source_key=?2
         ON CONFLICT(scope_key,day,model) DO UPDATE SET
           prompt_tokens=prompt_tokens+excluded.prompt_tokens,
           cached_input_tokens=cached_input_tokens+excluded.cached_input_tokens,
           completion_tokens=completion_tokens+excluded.completion_tokens,
           total_tokens=total_tokens+excluded.total_tokens,
           estimated_prompt_tokens=estimated_prompt_tokens+excluded.estimated_prompt_tokens,
           estimated_completion_tokens=estimated_completion_tokens+excluded.estimated_completion_tokens",
        params![scope_key, source_key],
    )?;
    if let Some(first_day) = first_day {
        transaction.execute(
            "UPDATE native_usage_daily_totals
             SET session_count=session_count+?3
             WHERE scope_key=?1 AND day=?2",
            params![scope_key, first_day, to_i64(session_count)],
        )?;
    }
    transaction.execute(
        "DELETE FROM native_usage_source_days WHERE scope_key=?1 AND source_key=?2",
        params![scope_key, source_key],
    )?;
    transaction.execute(
        "DELETE FROM native_usage_source_models WHERE scope_key=?1 AND source_key=?2",
        params![scope_key, source_key],
    )?;
    transaction.execute(
        "UPDATE native_usage_sources SET sealed=1
         WHERE scope_key=?1 AND source_key=?2",
        params![scope_key, source_key],
    )?;
    Ok(())
}

/// Reduces every completed local day for a still-live source into the shared
/// agent/day/model tables. Only the current day's source rows remain mutable.
/// The source fingerprint and append cursor stay available to avoid rescans.
pub(super) fn compact_source_days_before(
    transaction: &Transaction<'_>,
    scope_key: &str,
    source_key: &str,
    before_day: &str,
    session_count: u64,
) -> Result<u64> {
    let compacted_days = transaction.query_row(
        "SELECT COUNT(*) FROM native_usage_source_days
         WHERE scope_key=?1 AND source_key=?2 AND day<?3",
        params![scope_key, source_key, before_day],
        |row| row.get::<_, i64>(0),
    )?;
    if compacted_days <= 0 {
        return Ok(0);
    }
    let first_day = transaction.query_row(
        "SELECT MIN(day) FROM native_usage_source_days
         WHERE scope_key=?1 AND source_key=?2 AND day<?3",
        params![scope_key, source_key, before_day],
        |row| row.get::<_, Option<String>>(0),
    )?;
    transaction.execute(
        "INSERT INTO native_usage_daily_totals
           SELECT scope_key, day, prompt_tokens, cached_input_tokens,
                  completion_tokens, estimated_prompt_tokens,
                  estimated_completion_tokens, explicit_records,
                  estimated_records, message_count, 0
           FROM native_usage_source_days
           WHERE scope_key=?1 AND source_key=?2 AND day<?3
         ON CONFLICT(scope_key,day) DO UPDATE SET
           prompt_tokens=prompt_tokens+excluded.prompt_tokens,
           cached_input_tokens=cached_input_tokens+excluded.cached_input_tokens,
           completion_tokens=completion_tokens+excluded.completion_tokens,
           estimated_prompt_tokens=estimated_prompt_tokens+excluded.estimated_prompt_tokens,
           estimated_completion_tokens=estimated_completion_tokens+excluded.estimated_completion_tokens,
           explicit_records=explicit_records+excluded.explicit_records,
           estimated_records=estimated_records+excluded.estimated_records,
           message_count=message_count+excluded.message_count",
        params![scope_key, source_key, before_day],
    )?;
    transaction.execute(
        "INSERT INTO native_usage_daily_models
           SELECT scope_key, day, model, prompt_tokens, cached_input_tokens,
                  completion_tokens, total_tokens, estimated_prompt_tokens,
                  estimated_completion_tokens
           FROM native_usage_source_models
           WHERE scope_key=?1 AND source_key=?2 AND day<?3
         ON CONFLICT(scope_key,day,model) DO UPDATE SET
           prompt_tokens=prompt_tokens+excluded.prompt_tokens,
           cached_input_tokens=cached_input_tokens+excluded.cached_input_tokens,
           completion_tokens=completion_tokens+excluded.completion_tokens,
           total_tokens=total_tokens+excluded.total_tokens,
           estimated_prompt_tokens=estimated_prompt_tokens+excluded.estimated_prompt_tokens,
           estimated_completion_tokens=estimated_completion_tokens+excluded.estimated_completion_tokens",
        params![scope_key, source_key, before_day],
    )?;
    if let Some(first_day) = first_day {
        transaction.execute(
            "UPDATE native_usage_daily_totals
             SET session_count=session_count+?3
             WHERE scope_key=?1 AND day=?2",
            params![scope_key, first_day, to_i64(session_count)],
        )?;
    }
    transaction.execute(
        "DELETE FROM native_usage_source_days
         WHERE scope_key=?1 AND source_key=?2 AND day<?3",
        params![scope_key, source_key, before_day],
    )?;
    transaction.execute(
        "DELETE FROM native_usage_source_models
         WHERE scope_key=?1 AND source_key=?2 AND day<?3",
        params![scope_key, source_key, before_day],
    )?;
    transaction.execute(
        "UPDATE native_usage_sources SET session_count=0
         WHERE scope_key=?1 AND source_key=?2",
        params![scope_key, source_key],
    )?;
    Ok(from_i64(compacted_days))
}

pub(super) fn mark_scan(transaction: &Transaction<'_>, scope_key: &str, now_ms: u64) -> Result<()> {
    transaction.execute(
        "INSERT INTO native_usage_scans(scope_key,last_scan_ms) VALUES(?1,?2)
         ON CONFLICT(scope_key) DO UPDATE SET last_scan_ms=excluded.last_scan_ms",
        params![scope_key, to_i64(now_ms)],
    )?;
    Ok(())
}

pub(super) fn aggregate_usage(
    connection: &mut Connection,
    scope_key: &str,
    window: &UsageWindow,
) -> Result<HistoryUsageSummary> {
    let snapshot = connection.transaction_with_behavior(TransactionBehavior::Deferred)?;
    let mut summary = HistoryUsageSummary {
        source: Some("native-metadata-first-usage-cache"),
        ..HistoryUsageSummary::default()
    };
    {
        let mut statement = snapshot.prepare(
            "SELECT day,
                    SUM(prompt_tokens), SUM(cached_input_tokens),
                    SUM(completion_tokens), SUM(estimated_prompt_tokens),
                    SUM(estimated_completion_tokens), SUM(explicit_records),
                    SUM(estimated_records), SUM(message_count), SUM(session_count)
             FROM (
               SELECT day,prompt_tokens,cached_input_tokens,completion_tokens,
                      estimated_prompt_tokens,estimated_completion_tokens,
                      explicit_records,estimated_records,message_count,session_count
               FROM native_usage_daily_totals WHERE scope_key=?1
               UNION ALL
               SELECT day,prompt_tokens,cached_input_tokens,completion_tokens,
                      estimated_prompt_tokens,estimated_completion_tokens,
                      explicit_records,estimated_records,message_count,0
               FROM native_usage_source_days WHERE scope_key=?1
             )
             WHERE day>=?2 AND day<=?3 GROUP BY day ORDER BY day",
        )?;
        let rows = statement.query_map(params![scope_key, &window.start, &window.end], |row| {
            Ok((
                row.get::<_, String>(0)?,
                from_i64(row.get(1)?),
                from_i64(row.get(2)?),
                from_i64(row.get(3)?),
                from_i64(row.get(4)?),
                from_i64(row.get(5)?),
                from_i64(row.get(6)?),
                from_i64(row.get(7)?),
                from_i64(row.get(8)?),
                from_i64(row.get(9)?),
            ))
        })?;
        for row in rows {
            let (
                day,
                mut prompt,
                cached,
                mut completion,
                mut estimated_prompt,
                mut estimated_completion,
                explicit_records,
                mut estimated_records,
                mut messages,
                sessions,
            ) = row?;
            if explicit_records > 0 {
                prompt = prompt.saturating_sub(estimated_prompt);
                completion = completion.saturating_sub(estimated_completion);
                messages = messages.saturating_sub(estimated_records);
                estimated_prompt = 0;
                estimated_completion = 0;
                estimated_records = 0;
            }
            let explicit_prompt = prompt.saturating_sub(estimated_prompt);
            let explicit_completion = completion.saturating_sub(estimated_completion);
            summary.explicit_prompt_tokens = summary
                .explicit_prompt_tokens
                .saturating_add(explicit_prompt);
            summary.explicit_cached_input_tokens = summary
                .explicit_cached_input_tokens
                .saturating_add(cached.min(explicit_prompt));
            summary.explicit_completion_tokens = summary
                .explicit_completion_tokens
                .saturating_add(explicit_completion);
            summary.explicit_total_tokens = summary
                .explicit_total_tokens
                .saturating_add(explicit_prompt.saturating_add(explicit_completion));
            summary.estimated_prompt_tokens = summary
                .estimated_prompt_tokens
                .saturating_add(estimated_prompt);
            summary.estimated_completion_tokens = summary
                .estimated_completion_tokens
                .saturating_add(estimated_completion);
            summary.estimated_total_tokens = summary
                .estimated_total_tokens
                .saturating_add(estimated_prompt.saturating_add(estimated_completion));
            summary.explicit_records = summary.explicit_records.saturating_add(explicit_records);
            summary.estimated_records = summary.estimated_records.saturating_add(estimated_records);
            summary.message_count = summary.message_count.saturating_add(messages);
            summary.session_count = summary.session_count.saturating_add(sessions);
            let daily = summary.daily_usage.entry(day).or_default();
            daily.prompt_tokens = prompt;
            daily.cached_input_tokens = cached.min(prompt);
            daily.completion_tokens = completion;
            daily.total_tokens = prompt.saturating_add(completion);
            daily.explicit_records = explicit_records;
            daily.estimated_records = estimated_records;
            daily.estimated_prompt_tokens = estimated_prompt;
            daily.estimated_completion_tokens = estimated_completion;
            daily.message_count = messages;
        }
    }
    {
        let mut statement = snapshot.prepare(
            "SELECT day,model,
                    SUM(prompt_tokens),SUM(cached_input_tokens),
                    SUM(completion_tokens),SUM(total_tokens),
                    SUM(estimated_prompt_tokens),SUM(estimated_completion_tokens)
             FROM (
               SELECT day,model,prompt_tokens,cached_input_tokens,
                      completion_tokens,total_tokens,estimated_prompt_tokens,
                      estimated_completion_tokens
               FROM native_usage_daily_models WHERE scope_key=?1
               UNION ALL
               SELECT day,model,prompt_tokens,cached_input_tokens,
                      completion_tokens,total_tokens,estimated_prompt_tokens,
                      estimated_completion_tokens
               FROM native_usage_source_models WHERE scope_key=?1
             )
             WHERE day>=?2 AND day<=?3 GROUP BY day,model ORDER BY day,model",
        )?;
        let rows = statement.query_map(params![scope_key, &window.start, &window.end], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                from_i64(row.get(2)?),
                from_i64(row.get(3)?),
                from_i64(row.get(4)?),
                from_i64(row.get(5)?),
                from_i64(row.get(6)?),
                from_i64(row.get(7)?),
            ))
        })?;
        for row in rows {
            let (
                day,
                model,
                mut prompt,
                mut cached,
                mut completion,
                mut total,
                mut estimated_prompt,
                mut estimated_completion,
            ) = row?;
            if summary
                .daily_usage
                .get(&day)
                .is_some_and(|usage| usage.explicit_records > 0)
            {
                prompt = prompt.saturating_sub(estimated_prompt);
                completion = completion.saturating_sub(estimated_completion);
                total = prompt.saturating_add(completion);
                cached = cached.min(prompt);
                estimated_prompt = 0;
                estimated_completion = 0;
            }
            summary
                .daily_usage
                .entry(day)
                .or_default()
                .add_model_usage_with_estimates(
                    model,
                    prompt,
                    cached,
                    completion,
                    total,
                    estimated_prompt,
                    estimated_completion,
                );
        }
    }
    summary.session_count = summary.session_count.saturating_add(
        snapshot
            .query_row(
                "SELECT COALESCE(SUM(session_count),0) FROM native_usage_sources s
             WHERE scope_key=?1 AND sealed=0 AND EXISTS(
               SELECT 1 FROM native_usage_source_days d
               WHERE d.scope_key=s.scope_key AND d.source_key=s.source_key
                 AND d.day>=?2 AND d.day<=?3
             )",
                params![scope_key, &window.start, &window.end],
                |row| row.get::<_, i64>(0),
            )
            .map(from_i64)?,
    );
    let source_count = snapshot.query_row(
        "SELECT COUNT(*) FROM native_usage_sources WHERE scope_key=?1",
        [scope_key],
        |row| row.get::<_, i64>(0),
    )?;
    snapshot.commit()?;
    if source_count > 0 {
        summary
            .source_paths
            .insert("native-metadata-first-usage-store".to_owned());
    }
    Ok(summary)
}

pub(super) fn reclaim_space(connection: &Connection) -> Result<()> {
    connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    let page_count =
        connection.pragma_query_value(None, "page_count", |row| row.get::<_, u64>(0))?;
    let free_pages =
        connection.pragma_query_value(None, "freelist_count", |row| row.get::<_, u64>(0))?;
    if page_count > 0 && free_pages.saturating_mul(4) >= page_count {
        connection.execute_batch("VACUUM;")?;
    } else if free_pages > 0 {
        connection.execute_batch("PRAGMA incremental_vacuum(256);")?;
    }
    connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    Ok(())
}

fn to_i64(value: u64) -> i64 {
    value.min(i64::MAX as u64) as i64
}

fn from_i64(value: i64) -> u64 {
    value.max(0) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::agent_usage::contract::MessageUsage;
    use serde_json::json;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEMP_DATABASE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    fn temp_database() -> PathBuf {
        std::env::temp_dir().join(format!(
            "lico-native-usage-cache-{}-{}-{}.sqlite3",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            TEMP_DATABASE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn current_rollup_cache_removes_superseded_exact_cache_files() {
        let root = temp_database();
        fs::create_dir_all(&root).unwrap();
        for suffix in ["", "-wal", "-shm"] {
            fs::write(
                root.join(format!("{LEGACY_CACHE_FILE_NAME}{suffix}")),
                b"legacy",
            )
            .unwrap();
        }
        let path = cache_path(&root);
        let connection = open_cache_database(&path).unwrap();
        for suffix in ["", "-wal", "-shm"] {
            assert!(
                !root
                    .join(format!("{LEGACY_CACHE_FILE_NAME}{suffix}"))
                    .exists()
            );
        }
        drop(connection);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn sealed_source_keeps_only_day_and_model_rollups() {
        let path = temp_database();
        let mut connection = open_cache_database(&path).unwrap();
        let transaction = connection.transaction().unwrap();
        let mut summary = HistoryUsageSummary::default();
        summary.add(
            MessageUsage {
                prompt_tokens: 10,
                cached_input_tokens: 4,
                completion_tokens: 2,
                total_tokens: 12,
                model: Some("model-a".to_owned()),
                accuracy: Default::default(),
            },
            Some("2026-07-14".to_owned()),
        );
        add_source_rollup(&transaction, "scope", "source", &summary).unwrap();
        save_source(
            &transaction,
            "scope",
            "source",
            &SourceMetadata {
                modified_ns: 1,
                size: 1,
                file_id: None,
            },
            1,
            "guard",
            1,
            false,
        )
        .unwrap();
        seal_source(&transaction, "scope", "source", 1).unwrap();
        assert_eq!(
            transaction
                .query_row("SELECT COUNT(*) FROM native_usage_source_days", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            0
        );
        transaction.commit().unwrap();
        let window = UsageWindow::from_params(&json!({
            "now": "2026-07-15T12:00:00Z",
            "historyDays": 2
        }));
        let aggregate = aggregate_usage(&mut connection, "scope", &window).unwrap();
        assert_eq!(aggregate.total_tokens(), 12);
        assert_eq!(aggregate.session_count, 1);
        drop(connection);
        for candidate in [
            path.clone(),
            PathBuf::from(format!("{}-wal", path.to_string_lossy())),
            PathBuf::from(format!("{}-shm", path.to_string_lossy())),
        ] {
            let _ = fs::remove_file(candidate);
        }
    }

    #[test]
    fn day_compaction_keeps_only_today_mutable() {
        let path = temp_database();
        let mut connection = open_cache_database(&path).unwrap();
        let transaction = connection.transaction().unwrap();
        let mut summary = HistoryUsageSummary::default();
        for (day, prompt, completion) in [("2026-07-14", 10, 2), ("2026-07-15", 20, 3)] {
            summary.add(
                MessageUsage {
                    prompt_tokens: prompt,
                    cached_input_tokens: 0,
                    completion_tokens: completion,
                    total_tokens: prompt + completion,
                    model: Some("model-a".to_owned()),
                    accuracy: Default::default(),
                },
                Some(day.to_owned()),
            );
        }
        add_source_rollup(&transaction, "scope", "source", &summary).unwrap();
        save_source(
            &transaction,
            "scope",
            "source",
            &SourceMetadata {
                modified_ns: 1,
                size: 1,
                file_id: None,
            },
            1,
            "guard",
            1,
            false,
        )
        .unwrap();

        assert_eq!(
            compact_source_days_before(&transaction, "scope", "source", "2026-07-15", 1,).unwrap(),
            1
        );
        assert_eq!(
            transaction
                .query_row("SELECT day FROM native_usage_source_days", [], |row| row
                    .get::<_, String>(
                    0
                ),)
                .unwrap(),
            "2026-07-15"
        );
        assert_eq!(
            transaction
                .query_row("SELECT day FROM native_usage_daily_totals", [], |row| {
                    row.get::<_, String>(0)
                },)
                .unwrap(),
            "2026-07-14"
        );
        transaction.commit().unwrap();
        let window = UsageWindow::from_params(&json!({
            "now": "2026-07-15T12:00:00Z",
            "historyDays": 2
        }));
        assert_eq!(
            aggregate_usage(&mut connection, "scope", &window)
                .unwrap()
                .total_tokens(),
            35
        );
        drop(connection);
        for candidate in [
            path.clone(),
            PathBuf::from(format!("{}-wal", path.to_string_lossy())),
            PathBuf::from(format!("{}-shm", path.to_string_lossy())),
        ] {
            let _ = fs::remove_file(candidate);
        }
    }
}
