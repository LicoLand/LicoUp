//! Metadata-first, change-driven usage aggregation for non-Codex histories.
//!
//! The refresh pipeline is two-phase: discovery and parsing build an
//! immutable typed plan with no database lease held, then one short
//! immediate transaction revalidates identities and applies the planned
//! compaction, rollup, source, watermark, and scan-marker actions with
//! prepared statements.

mod cache;
mod files;
mod models;
mod openclaw;
mod parser;
pub(super) mod runtime;
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
    RefreshStatements, aggregate_usage, cache_has_baseline, cache_is_fresh, cache_path,
    load_compaction_targets, load_sources, reclaim_space,
};
use files::{
    append_guard, append_guard_matches, is_append_format, is_usage_source, roots_fingerprint,
    source_is_closed, source_key, source_metadata, usage_roots,
};
use models::{
    CachedSource, ParseResult, PlannedSource, PlannedSourceAction, RefreshPlan, ScanStats,
    SourceMetadata,
};
use parser::{parse_append_source, parse_snapshot_source};
use runtime::{CacheLease, CacheRuntime};
use rusqlite::TransactionBehavior;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use watermark::{WatermarkProjection, apply_cumulative_watermarks};

pub(super) const PARSER_REVISION: &str = "native-metadata-first-daily-rollups-v8";
const CACHE_REFRESH_INTERVAL_MS: u64 = 60_000;
const SNAPSHOT_CACHE_REFRESH_INTERVAL_MS: u64 = 10 * 60_000;

struct SourceEntry {
    path: PathBuf,
    source_kind: String,
    metadata: SourceMetadata,
}

struct StableParse {
    parsed: ParseResult,
    metadata: SourceMetadata,
    append: bool,
}

pub(super) fn summarize(
    agent: &AgentDef,
    scan_params: &Value,
    window: &UsageWindow,
    warnings: &mut Vec<Value>,
    runtime: &CacheRuntime,
) -> Option<HistoryUsageSummary> {
    if agent.id == "openclaw" {
        return Some(openclaw::summarize(window, warnings));
    }
    match summarize_inner(agent, scan_params, window, warnings, runtime) {
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
    runtime: &CacheRuntime,
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
    let database_path = cache_path(state_store.root());
    let force_refresh = param_bool(scan_params, "forceRefresh").unwrap_or(false);
    let now_ms = unix_millis();
    let mut stats = ScanStats::default();
    let refresh_scope = runtime.begin_refresh(&scope_key, &database_path, now_ms)?;
    stats.opened_connections = refresh_scope.opened_connections();

    let (has_baseline, previous, compaction_targets) = {
        let mut lease = runtime.lease(&scope_key, &database_path, now_ms)?;
        stats.leases = stats.leases.saturating_add(lease.stats().leases);
        stats.opened_connections = stats
            .opened_connections
            .saturating_add(lease.stats().opened);
        if !force_refresh
            && cache_is_fresh(
                lease.connection(0),
                &scope_key,
                now_ms,
                cache_refresh_interval_ms(adapter),
            )?
        {
            let mut summary = aggregate_usage(lease.connection(1), &scope_key, window)?;
            apply_source(adapter, &mut summary);
            summary.scan_cache = Some(
                ScanStats {
                    cache_fresh: true,
                    opened_connections: stats.opened_connections,
                    leases: stats.leases,
                    ..ScanStats::default()
                }
                .to_json(),
            );
            return Ok(summary);
        }
        let has_baseline = cache_has_baseline(lease.connection(0), &scope_key)?;
        let previous = load_sources(lease.connection(0), &scope_key)?;
        let compaction_targets =
            load_compaction_targets(lease.connection(0), &scope_key, &window.end)?;
        (has_baseline, previous, compaction_targets)
    };
    // The lease is released here: discovery, guard hashing, and parsing run
    // without holding any database connection.

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
    stats.discovered_sources = entries.len() as u64;

    // Day rollover is independent of source discovery. The plan replicates
    // the post-compaction session state so unchanged-source decisions match
    // the single-transaction behavior exactly.
    let mut planned_sources = previous.clone();
    for (key, source) in &mut planned_sources {
        if compaction_targets.contains(key) {
            source.session_count = 0;
        }
    }
    let compactions = previous
        .iter()
        .map(|(key, source)| (key.clone(), source.session_count))
        .collect::<Vec<_>>();

    let mut sources = Vec::new();
    for entry in entries {
        let key = source_key(&scope_key, &entry.path);
        let previous_source = planned_sources.get(&key).cloned();
        let (action, metadata) = if let Some(previous) = &previous_source
            && source_unchanged(previous, &entry.metadata)
            && (!force_refresh
                || (is_append_format(&entry.path)
                    && append_guard_matches(&entry.path, previous.size, &previous.append_guard)))
        {
            if !previous.sealed && source_is_closed(&entry.metadata, window) {
                stats.sealed_sources = stats.sealed_sources.saturating_add(1);
                (
                    PlannedSourceAction::ReuseSeal {
                        session_count: previous.session_count,
                    },
                    entry.metadata.clone(),
                )
            } else {
                stats.reused_sources = stats.reused_sources.saturating_add(1);
                (PlannedSourceAction::Reuse, entry.metadata.clone())
            }
        } else {
            let append_format = is_append_format(&entry.path);
            let previous_session_count = previous_source
                .as_ref()
                .map_or(0, |source| source.session_count);
            let stable = parse_stable_source(
                adapter,
                &entry.path,
                &entry.source_kind,
                previous_source.as_ref(),
                previous_session_count,
                &parse_window,
            )?;
            let projection = if stable.append {
                let previous = previous_source
                    .as_ref()
                    .expect("stable append requires a previous source");
                stats.appended_sources = stats.appended_sources.saturating_add(1);
                stats.parsed_bytes = stats.parsed_bytes.saturating_add(
                    stable
                        .parsed
                        .parsed_bytes
                        .saturating_sub(previous.parsed_bytes),
                );
                WatermarkProjection::AppendDelta
            } else {
                stats.replaced_sources = stats.replaced_sources.saturating_add(1);
                stats.parsed_bytes = stats
                    .parsed_bytes
                    .saturating_add(stable.parsed.parsed_bytes);
                if has_baseline {
                    WatermarkProjection::ReplaceCurrentDay
                } else {
                    WatermarkProjection::RebuildAllHistory
                }
            };
            let append_guard = if append_format {
                append_guard(&entry.path, stable.metadata.size)?
            } else {
                String::new()
            };
            (
                PlannedSourceAction::Refresh {
                    append: stable.append,
                    append_format,
                    previous_session_count,
                    parsed: Box::new(stable.parsed),
                    projection,
                    append_guard,
                },
                stable.metadata,
            )
        };
        sources.push(PlannedSource {
            key,
            path: entry.path,
            metadata,
            action,
        });
    }

    let plan = RefreshPlan {
        previous,
        compaction_targets,
        compactions,
        sources,
    };
    {
        let mut lease = runtime.lease(&scope_key, &database_path, now_ms)?;
        stats.leases = stats.leases.saturating_add(lease.stats().leases);
        stats.opened_connections = stats
            .opened_connections
            .saturating_add(lease.stats().opened);
        apply_refresh_plan(
            &mut lease,
            &scope_key,
            &parse_window,
            window,
            now_ms,
            plan,
            &mut stats,
        )?;
    }
    // The apply lease is released before aggregation.

    let mut summary = {
        let mut lease = runtime.lease(&scope_key, &database_path, now_ms)?;
        stats.leases = stats.leases.saturating_add(lease.stats().leases);
        stats.opened_connections = stats
            .opened_connections
            .saturating_add(lease.stats().opened);
        aggregate_usage(lease.connection(1), &scope_key, window)?
    };
    apply_source(adapter, &mut summary);
    summary.scan_cache = Some(stats.to_json());
    Ok(summary)
}

fn apply_refresh_plan(
    lease: &mut CacheLease<'_>,
    scope_key: &str,
    parse_window: &UsageWindow,
    window: &UsageWindow,
    now_ms: u64,
    plan: RefreshPlan,
    stats: &mut ScanStats,
) -> Result<()> {
    let started = Instant::now();
    let connection = lease.connection(0);
    let needs_reclaim = {
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("native usage cache transaction failed")?;
        stats.statements = stats.statements.saturating_add(1);
        let current = load_sources(&transaction, scope_key)?;
        if current != plan.previous {
            anyhow::bail!("native usage cache changed during scan");
        }
        stats.statements = stats.statements.saturating_add(1);
        let targets = load_compaction_targets(&transaction, scope_key, &window.end)?;
        if targets != plan.compaction_targets {
            anyhow::bail!("native usage cache changed during scan");
        }
        for source in &plan.sources {
            let observed = source_metadata(&source.path).with_context(|| {
                format!(
                    "native usage source recheck failed: {}",
                    source.path.display()
                )
            })?;
            if observed != source.metadata {
                anyhow::bail!("native usage source changed during scan");
            }
        }
        let mut statements = RefreshStatements::prepare(&transaction)?;
        for (key, session_count) in &plan.compactions {
            let compacted = statements.compact(scope_key, key, &window.end, *session_count)?;
            stats.compacted_days = stats.compacted_days.saturating_add(compacted);
        }
        for source in plan.sources {
            match source.action {
                PlannedSourceAction::Reuse => {}
                PlannedSourceAction::ReuseSeal { session_count } => {
                    statements.seal(scope_key, &source.key, session_count)?;
                }
                PlannedSourceAction::Refresh {
                    append,
                    append_format,
                    previous_session_count,
                    mut parsed,
                    projection,
                    append_guard,
                } => {
                    let snapshots = std::mem::take(&mut parsed.cumulative_snapshots);
                    let watermarked_sessions = apply_cumulative_watermarks(
                        &mut statements,
                        scope_key,
                        &source.key,
                        parse_window,
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
                    if append {
                        statements.add_rollup(scope_key, &source.key, &parsed.summary)?;
                    } else {
                        statements.replace_rollup(scope_key, &source.key, &parsed.summary)?;
                    }
                    statements.save_source(
                        scope_key,
                        &source.key,
                        &source.metadata,
                        parsed.parsed_bytes,
                        &append_guard,
                        session_count,
                    )?;
                    let compacted =
                        statements.compact(scope_key, &source.key, &window.end, session_count)?;
                    stats.compacted_days = stats.compacted_days.saturating_add(compacted);
                    if source_is_closed(&source.metadata, window) {
                        statements.seal(
                            scope_key,
                            &source.key,
                            if compacted > 0 { 0 } else { session_count },
                        )?;
                        stats.sealed_sources = stats.sealed_sources.saturating_add(1);
                    }
                }
            }
        }
        statements.mark_scan(scope_key, now_ms)?;
        let executed = statements.executed();
        let sealed_sources = stats.sealed_sources;
        let compacted_days = stats.compacted_days;
        let rebuilt = stats.rebuilt;
        drop(statements);
        transaction.commit()?;
        stats.statements = stats.statements.saturating_add(executed);
        stats.transaction_millis = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
        sealed_sources > 0 || compacted_days > 0 || rebuilt
    };
    if needs_reclaim {
        reclaim_space(connection)?;
    }
    Ok(())
}

/// Parses a source with metadata verification before and after the read.
/// One change retries the parse; a second change fails the whole scan so no
/// cache row or watermark can partially apply.
fn parse_stable_source(
    adapter: HistoryAdapter,
    path: &Path,
    source_kind: &str,
    previous_source: Option<&CachedSource>,
    previous_session_count: u64,
    parse_window: &UsageWindow,
) -> Result<StableParse> {
    let append_format = is_append_format(path);
    for _ in 0..2 {
        let before = source_metadata(path)
            .with_context(|| format!("native usage source metadata failed: {}", path.display()))?;
        // Recompute append eligibility for the exact snapshot about to be
        // parsed. A replacement between discovery and either retry must fall
        // back to a full parse instead of applying an obsolete append plan.
        let append = previous_source.is_some_and(|previous| {
            append_format
                && previous.file_id.is_some()
                && previous.file_id == before.file_id
                && before.size > previous.size
                && previous.parsed_bytes <= previous.size
                && append_guard_matches(path, previous.size, &previous.append_guard)
        });
        let parsed = if append {
            let previous = previous_source.expect("append source checked above");
            parse_append_source(
                adapter,
                path,
                previous.parsed_bytes,
                parse_window,
                previous_session_count > 0,
            )?
        } else if append_format {
            parse_append_source(adapter, path, 0, parse_window, previous_session_count > 0)?
        } else {
            let metadata = fs::metadata(path)
                .with_context(|| format!("native usage source stat failed: {}", path.display()))?;
            parse_snapshot_source(adapter, path, source_kind, &metadata, parse_window)?
        };
        let after = source_metadata(path)
            .with_context(|| format!("native usage source recheck failed: {}", path.display()))?;
        if after == before {
            return Ok(StableParse {
                parsed,
                metadata: after,
                append,
            });
        }
    }
    anyhow::bail!(
        "native usage source changed while parsing: {}",
        path.display()
    )
}

fn apply_source(adapter: HistoryAdapter, summary: &mut HistoryUsageSummary) {
    if adapter == HistoryAdapter::Hermes {
        summary.source = Some("hermes-gateway-usage-database");
    }
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
