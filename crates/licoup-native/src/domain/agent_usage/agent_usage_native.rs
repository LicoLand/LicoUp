//! Metadata-first, change-driven usage aggregation for non-Codex histories.

mod cache;
mod files;
mod models;
mod parser;
mod watermark;

use super::contract::{AgentDef, HistoryUsageSummary};
use super::persistence::client_state_store;
use super::window::UsageWindow;
use crate::domain::conversation::history_discovery::{
    HistoryDiscoveryOptions, discover_history_files,
};
use crate::domain::conversation::parameters::param_bool;
use crate::domain::conversation::source_catalog::{
    HistoryAdapter, adapter_for_agent, history_roots,
};
use anyhow::{Context, Result};
use cache::{
    add_source_rollup, aggregate_usage, cache_has_baseline, cache_is_fresh, cache_path,
    compact_source_days_before, load_sources, mark_scan, open_cache_database, reclaim_space,
    replace_source_rollup, save_source, seal_source,
};
use files::{
    append_guard, append_guard_matches, is_append_format, is_usage_source, roots_fingerprint,
    source_is_closed, source_key, source_metadata, usage_roots,
};
use models::{CachedSource, ScanStats, SourceMetadata};
use parser::{parse_append_source, parse_snapshot_source};
use rusqlite::TransactionBehavior;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use watermark::{WatermarkProjection, apply_cumulative_watermarks};

pub(super) const PARSER_REVISION: &str = "native-metadata-first-daily-rollups-v6";
const CACHE_REFRESH_INTERVAL_MS: u64 = 60_000;
const SNAPSHOT_CACHE_REFRESH_INTERVAL_MS: u64 = 10 * 60_000;

struct SourceEntry {
    path: PathBuf,
    source_kind: String,
    metadata: SourceMetadata,
}

pub(super) fn summarize(
    agent: &AgentDef,
    scan_params: &Value,
    window: &UsageWindow,
    warnings: &mut Vec<Value>,
) -> Option<HistoryUsageSummary> {
    match summarize_inner(agent, scan_params, window, warnings) {
        Ok(summary) => Some(summary),
        Err(_) => {
            warnings.push(json!({
                "code": "native_usage_cache_failed",
                "agentId": agent.id
            }));
            None
        }
    }
}

fn summarize_inner(
    agent: &AgentDef,
    scan_params: &Value,
    window: &UsageWindow,
    warnings: &mut Vec<Value>,
) -> Result<HistoryUsageSummary> {
    let adapter = adapter_for_agent(agent.id)
        .with_context(|| format!("unsupported usage adapter: {}", agent.id))?;
    let roots = usage_roots(adapter, history_roots(adapter, scan_params));
    let root_paths = roots
        .iter()
        .map(|root| root.path.clone())
        .collect::<Vec<_>>();
    let scope_key = roots_fingerprint(agent.id, &root_paths, &window.cache_timezone_key());
    let state_store = client_state_store(scan_params)?;
    let mut connection = open_cache_database(&cache_path(state_store.root()))?;
    let force_refresh = param_bool(scan_params, "forceRefresh").unwrap_or(false);
    let now_ms = unix_millis();
    if !force_refresh
        && cache_is_fresh(
            &connection,
            &scope_key,
            now_ms,
            cache_refresh_interval_ms(adapter),
        )?
    {
        let mut summary = aggregate_usage(&mut connection, &scope_key, window)?;
        summary.scan_cache = Some(
            ScanStats {
                cache_fresh: true,
                ..ScanStats::default()
            }
            .to_json(),
        );
        return Ok(summary);
    }
    let has_baseline = cache_has_baseline(&connection, &scope_key)?;
    let parse_window = if has_baseline {
        window.today_only()
    } else {
        window.all_history()
    };

    let discovery = discover_history_files(adapter, &roots, HistoryDiscoveryOptions::default());
    for skipped in discovery
        .skipped
        .iter()
        .filter(|item| item.get("reason").and_then(Value::as_str) != Some("not_present"))
    {
        warnings.push(json!({
            "code": skipped
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("native_usage_source_skipped"),
            "agentId": agent.id
        }));
    }
    let unique_candidates = discovery
        .candidates
        .into_iter()
        .filter(|candidate| is_usage_source(adapter, &candidate.path, &candidate.source_kind))
        .fold(
            BTreeMap::<PathBuf, String>::new(),
            |mut unique, candidate| {
                unique
                    .entry(candidate.path)
                    .or_insert(candidate.source_kind);
                unique
            },
        );
    let entries = unique_candidates
        .into_iter()
        .filter_map(|(path, source_kind)| {
            let metadata = source_metadata(&path)?;
            Some(SourceEntry {
                metadata,
                path,
                source_kind,
            })
        })
        .collect::<Vec<_>>();
    let mut stats = ScanStats {
        discovered_sources: entries.len() as u64,
        ..ScanStats::default()
    };

    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .context("native usage cache transaction failed")?;
    let mut cached = load_sources(&transaction, &scope_key)?;

    // Day rollover is independent of source discovery. Even if a log was
    // archived or removed, yesterday's mutable row is finalized exactly once.
    for (key, source) in &mut cached {
        let compacted = compact_source_days_before(
            &transaction,
            &scope_key,
            key,
            &window.end,
            source.session_count,
        )?;
        if compacted > 0 {
            source.session_count = 0;
            stats.compacted_days = stats.compacted_days.saturating_add(compacted);
        }
    }

    for entry in entries {
        let key = source_key(&scope_key, &entry.path);
        let previous = cached.get(&key).cloned();
        if let Some(previous) = &previous
            && source_unchanged(previous, &entry.metadata)
            && (!force_refresh
                || (is_append_format(&entry.path)
                    && append_guard_matches(&entry.path, previous.size, &previous.append_guard)))
        {
            if !previous.sealed && source_is_closed(&entry.metadata, window) {
                seal_source(&transaction, &scope_key, &key, previous.session_count)?;
                stats.sealed_sources = stats.sealed_sources.saturating_add(1);
            } else {
                stats.reused_sources = stats.reused_sources.saturating_add(1);
            }
            continue;
        }

        let append = previous.as_ref().is_some_and(|previous| {
            is_append_format(&entry.path)
                && previous.file_id.is_some()
                && previous.file_id == entry.metadata.file_id
                && entry.metadata.size > previous.size
                && previous.parsed_bytes <= previous.size
                && append_guard_matches(&entry.path, previous.size, &previous.append_guard)
        });
        let append_format = is_append_format(&entry.path);
        let previous_session_count = previous.as_ref().map_or(0, |source| source.session_count);
        let (mut parsed, projection) = if append {
            let previous = previous.as_ref().expect("append source checked above");
            let parsed = parse_append_source(
                adapter,
                &entry.path,
                previous.parsed_bytes,
                &parse_window,
                previous.session_count > 0,
            )?;
            stats.appended_sources = stats.appended_sources.saturating_add(1);
            stats.parsed_bytes = stats
                .parsed_bytes
                .saturating_add(parsed.parsed_bytes.saturating_sub(previous.parsed_bytes));
            (parsed, WatermarkProjection::AppendDelta)
        } else {
            let metadata = fs::metadata(&entry.path)?;
            let parsed = if append_format {
                parse_append_source(
                    adapter,
                    &entry.path,
                    0,
                    &parse_window,
                    previous_session_count > 0,
                )?
            } else {
                parse_snapshot_source(
                    adapter,
                    &entry.path,
                    &entry.source_kind,
                    &metadata,
                    &parse_window,
                )?
            };
            stats.replaced_sources = stats.replaced_sources.saturating_add(1);
            stats.parsed_bytes = stats.parsed_bytes.saturating_add(parsed.parsed_bytes);
            let projection = if has_baseline {
                WatermarkProjection::ReplaceCurrentDay
            } else {
                WatermarkProjection::RebuildAllHistory
            };
            (parsed, projection)
        };
        let snapshots = std::mem::take(&mut parsed.cumulative_snapshots);
        let watermarked_sessions = apply_cumulative_watermarks(
            &transaction,
            &scope_key,
            &key,
            &parse_window,
            &snapshots,
            projection,
            &mut parsed.summary,
        )?;
        parsed.summary.session_count = parsed
            .summary
            .session_count
            .saturating_add(watermarked_sessions);
        let session_count = if append_format {
            if append {
                previous_session_count.saturating_add(if previous_session_count == 0 {
                    parsed.summary.session_count
                } else {
                    0
                })
            } else {
                previous_session_count.max(parsed.summary.session_count)
            }
        } else {
            parsed.summary.session_count
        };
        parsed.session_increment = if append {
            session_count.saturating_sub(previous_session_count)
        } else {
            session_count
        };
        if append {
            add_source_rollup(&transaction, &scope_key, &key, &parsed.summary)?;
        } else {
            replace_source_rollup(&transaction, &scope_key, &key, &parsed.summary)?;
        }
        let guard = if append_format {
            append_guard(&entry.path, entry.metadata.size)?
        } else {
            String::new()
        };
        save_source(
            &transaction,
            &scope_key,
            &key,
            &entry.metadata,
            parsed.parsed_bytes,
            &guard,
            session_count,
            false,
        )?;
        let compacted =
            compact_source_days_before(&transaction, &scope_key, &key, &window.end, session_count)?;
        stats.compacted_days = stats.compacted_days.saturating_add(compacted);
        if source_is_closed(&entry.metadata, window) {
            seal_source(
                &transaction,
                &scope_key,
                &key,
                if compacted > 0 { 0 } else { session_count },
            )?;
            stats.sealed_sources = stats.sealed_sources.saturating_add(1);
        }
    }
    mark_scan(&transaction, &scope_key, now_ms)?;
    transaction.commit()?;
    if stats.sealed_sources > 0 || stats.compacted_days > 0 || stats.rebuilt {
        reclaim_space(&connection)?;
    }
    let mut summary = aggregate_usage(&mut connection, &scope_key, window)?;
    summary.scan_cache = Some(stats.to_json());
    Ok(summary)
}

fn source_unchanged(cached: &CachedSource, metadata: &SourceMetadata) -> bool {
    cached.modified_ns == metadata.modified_ns
        && cached.size == metadata.size
        && cached.file_id == metadata.file_id
}

fn unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn cache_refresh_interval_ms(adapter: HistoryAdapter) -> u64 {
    if matches!(
        adapter,
        HistoryAdapter::Antigravity | HistoryAdapter::Copilot | HistoryAdapter::Cursor
    ) {
        SNAPSHOT_CACHE_REFRESH_INTERVAL_MS
    } else {
        CACHE_REFRESH_INTERVAL_MS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_heavy_adapters_are_throttled_without_affecting_append_adapters() {
        assert_eq!(
            cache_refresh_interval_ms(HistoryAdapter::Antigravity),
            10 * CACHE_REFRESH_INTERVAL_MS
        );
        assert_eq!(
            cache_refresh_interval_ms(HistoryAdapter::Copilot),
            10 * CACHE_REFRESH_INTERVAL_MS
        );
        assert_eq!(
            cache_refresh_interval_ms(HistoryAdapter::Cursor),
            10 * CACHE_REFRESH_INTERVAL_MS
        );
        assert_eq!(
            cache_refresh_interval_ms(HistoryAdapter::Pi),
            CACHE_REFRESH_INTERVAL_MS
        );
    }
}
