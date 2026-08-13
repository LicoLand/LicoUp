//! Persistent cumulative counters for conversations that can resume on a later day.

use super::super::contract::{HistoryUsageSummary, MessageUsage};
use super::super::window::UsageWindow;
use super::cache::RefreshStatements;
use super::models::{CumulativeSnapshot, CumulativeTotals};
use anyhow::Result;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug)]
pub(super) struct Watermark {
    pub(super) session_key: String,
    pub(super) model: Option<String>,
    pub(super) day: String,
    pub(super) last: CumulativeTotals,
    pub(super) day_total: CumulativeTotals,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum WatermarkProjection {
    AppendDelta,
    ReplaceCurrentDay,
    RebuildAllHistory,
}

pub(super) fn apply_cumulative_watermarks(
    statements: &mut RefreshStatements<'_>,
    scope_key: &str,
    source_key: &str,
    calendar: &UsageWindow,
    snapshots: &[CumulativeSnapshot],
    projection: WatermarkProjection,
    summary: &mut HistoryUsageSummary,
) -> Result<u64> {
    let mut states = if projection == WatermarkProjection::RebuildAllHistory {
        BTreeMap::new()
    } else {
        load_watermarks_batch(statements.transaction(), scope_key, source_key, snapshots)?
    };
    let projected_snapshots = snapshots_for_projection(snapshots, projection);
    let suppressed = projected_snapshots
        .iter()
        .filter(|snapshot| !snapshot.projects_usage)
        .map(|snapshot| snapshot.usage_key.as_str())
        .collect::<BTreeSet<_>>();
    let mut sessions = BTreeSet::new();
    for snapshot in projected_snapshots {
        if !calendar.contains(&snapshot.observed_day) {
            continue;
        }
        let (state, added) = next_watermark(states.get(&snapshot.usage_key), snapshot);
        statements.save_watermark(scope_key, source_key, &snapshot.usage_key, &state)?;
        states.insert(snapshot.usage_key.clone(), state);
        if projection != WatermarkProjection::ReplaceCurrentDay
            && snapshot.projects_usage
            && add_to_summary(summary, snapshot, added)
        {
            sessions.insert(snapshot.session_key.clone());
        }
    }

    if projection != WatermarkProjection::ReplaceCurrentDay {
        return Ok(sessions.len() as u64);
    }
    for (_, state) in states.iter().filter(|(usage_key, state)| {
        calendar.contains(&state.day) && !suppressed.contains(usage_key.as_str())
    }) {
        if add_totals(
            summary,
            state.day_total,
            state.model.clone(),
            state.day.clone(),
        ) {
            sessions.insert(state.session_key.clone());
        }
    }
    Ok(sessions.len() as u64)
}

fn snapshots_for_projection(
    snapshots: &[CumulativeSnapshot],
    projection: WatermarkProjection,
) -> Vec<&CumulativeSnapshot> {
    if projection != WatermarkProjection::ReplaceCurrentDay {
        return snapshots.iter().collect();
    }
    let mut latest = BTreeMap::new();
    for snapshot in snapshots {
        latest.insert(snapshot.usage_key.as_str(), snapshot);
    }
    latest.into_values().collect()
}

fn next_watermark(
    previous: Option<&Watermark>,
    snapshot: &CumulativeSnapshot,
) -> (Watermark, CumulativeTotals) {
    let initial = if snapshot.first_day == snapshot.observed_day {
        snapshot.totals
    } else {
        CumulativeTotals::default()
    };
    let mut next = previous.cloned().unwrap_or_else(|| Watermark {
        session_key: snapshot.session_key.clone(),
        model: snapshot.model.clone(),
        day: snapshot.observed_day.clone(),
        last: snapshot.totals,
        day_total: initial,
    });
    let mut added = initial;
    if let Some(previous) = previous {
        if snapshot.observed_day > previous.day {
            next.day = snapshot.observed_day.clone();
            next.day_total = if snapshot.totals.at_least(previous.last) {
                snapshot.totals.delta(previous.last)
            } else {
                CumulativeTotals::default()
            };
            added = next.day_total;
        } else if snapshot.observed_day == previous.day && snapshot.totals.at_least(previous.last) {
            added = snapshot.totals.delta(previous.last);
            next.day_total = add(next.day_total, added);
        } else {
            added = CumulativeTotals::default();
        }
        if snapshot.observed_day >= previous.day {
            next.last = snapshot.totals;
            next.session_key = snapshot.session_key.clone();
            next.model = snapshot.model.clone();
        }
    }
    (next, added)
}

fn add_to_summary(
    summary: &mut HistoryUsageSummary,
    snapshot: &CumulativeSnapshot,
    totals: CumulativeTotals,
) -> bool {
    add_totals(
        summary,
        totals,
        snapshot.model.clone(),
        snapshot.observed_day.clone(),
    )
}

fn add_totals(
    summary: &mut HistoryUsageSummary,
    totals: CumulativeTotals,
    model: Option<String>,
    day: String,
) -> bool {
    let total = totals.prompt.saturating_add(totals.completion);
    if total == 0 {
        return false;
    }
    summary.add(
        MessageUsage {
            prompt_tokens: totals.prompt,
            cached_input_tokens: totals.cached.min(totals.prompt),
            completion_tokens: totals.completion,
            total_tokens: total,
            model,
            accuracy: Default::default(),
        },
        Some(day),
    );
    true
}

fn add(left: CumulativeTotals, right: CumulativeTotals) -> CumulativeTotals {
    CumulativeTotals {
        prompt: left.prompt.saturating_add(right.prompt),
        cached: left.cached.saturating_add(right.cached),
        completion: left.completion.saturating_add(right.completion),
    }
}

fn load_watermarks_batch(
    transaction: &rusqlite::Transaction<'_>,
    scope_key: &str,
    source_key: &str,
    snapshots: &[CumulativeSnapshot],
) -> Result<BTreeMap<String, Watermark>> {
    let usage_keys = snapshots
        .iter()
        .map(|snapshot| snapshot.usage_key.as_str())
        .collect::<BTreeSet<_>>();
    if usage_keys.is_empty() {
        return Ok(BTreeMap::new());
    }
    let placeholders = vec!["?"; usage_keys.len()].join(",");
    let mut statement = transaction.prepare(&format!(
        "SELECT usage_key,session_key,model,day,last_prompt,last_cached,last_completion,
                day_prompt,day_cached,day_completion
         FROM native_usage_watermarks
         WHERE scope_key=?1 AND source_key=?2 AND usage_key IN ({placeholders})"
    ))?;
    let mut parameters = Vec::with_capacity(usage_keys.len() + 2);
    parameters.push(scope_key);
    parameters.push(source_key);
    parameters.extend(usage_keys.iter().copied());
    let rows = statement.query_map(rusqlite::params_from_iter(parameters), |row| {
        Ok((
            row.get::<_, String>(0)?,
            Watermark {
                session_key: row.get(1)?,
                model: row.get(2)?,
                day: row.get(3)?,
                last: totals(row.get(4)?, row.get(5)?, row.get(6)?),
                day_total: totals(row.get(7)?, row.get(8)?, row.get(9)?),
            },
        ))
    })?;
    rows.collect::<rusqlite::Result<BTreeMap<_, _>>>()
        .map_err(Into::into)
}

fn totals(prompt: i64, cached: i64, completion: i64) -> CumulativeTotals {
    CumulativeTotals {
        prompt: from_i64(prompt),
        cached: from_i64(cached),
        completion: from_i64(completion),
    }
}

fn from_i64(value: i64) -> u64 {
    value.max(0) as u64
}
