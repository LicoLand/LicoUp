//! Persistent cumulative counters for conversations that can resume on a later day.

use super::super::contract::{HistoryUsageSummary, MessageUsage};
use super::super::window::UsageWindow;
use super::models::{CumulativeSnapshot, CumulativeTotals};
use anyhow::Result;
use rusqlite::{OptionalExtension, Transaction, params};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug)]
struct Watermark {
    session_key: String,
    model: Option<String>,
    day: String,
    last: CumulativeTotals,
    day_total: CumulativeTotals,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum WatermarkProjection {
    AppendDelta,
    ReplaceCurrentDay,
    RebuildAllHistory,
}

pub(super) fn apply_cumulative_watermarks(
    transaction: &Transaction<'_>,
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
        load_watermarks(transaction, scope_key, source_key, snapshots)?
    };
    let mut upsert = transaction.prepare(
        "INSERT INTO native_usage_watermarks VALUES(
           ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12
         ) ON CONFLICT(scope_key,source_key,usage_key) DO UPDATE SET
           session_key=excluded.session_key,model=excluded.model,day=excluded.day,
           last_prompt=excluded.last_prompt,last_cached=excluded.last_cached,
           last_completion=excluded.last_completion,day_prompt=excluded.day_prompt,
           day_cached=excluded.day_cached,day_completion=excluded.day_completion",
    )?;
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
        save_watermark(
            &mut upsert,
            scope_key,
            source_key,
            &snapshot.usage_key,
            &state,
        )?;
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

fn load_watermarks(
    transaction: &Transaction<'_>,
    scope_key: &str,
    source_key: &str,
    snapshots: &[CumulativeSnapshot],
) -> Result<BTreeMap<String, Watermark>> {
    let mut statement = transaction.prepare(
        "SELECT session_key,model,day,last_prompt,last_cached,last_completion,
                day_prompt,day_cached,day_completion
         FROM native_usage_watermarks
         WHERE scope_key=?1 AND source_key=?2 AND usage_key=?3",
    )?;
    let mut states = BTreeMap::new();
    let usage_keys = snapshots
        .iter()
        .map(|snapshot| snapshot.usage_key.as_str())
        .collect::<BTreeSet<_>>();
    for usage_key in usage_keys {
        let state = statement
            .query_row(params![scope_key, source_key, usage_key], |row| {
                Ok(Watermark {
                    session_key: row.get(0)?,
                    model: row.get(1)?,
                    day: row.get(2)?,
                    last: totals(row.get(3)?, row.get(4)?, row.get(5)?),
                    day_total: totals(row.get(6)?, row.get(7)?, row.get(8)?),
                })
            })
            .optional()?;
        if let Some(state) = state {
            states.insert(usage_key.to_owned(), state);
        }
    }
    Ok(states)
}

fn save_watermark(
    statement: &mut rusqlite::Statement<'_>,
    scope_key: &str,
    source_key: &str,
    usage_key: &str,
    state: &Watermark,
) -> Result<()> {
    statement.execute(params![
        scope_key,
        source_key,
        usage_key,
        state.session_key,
        state.model,
        state.day,
        to_i64(state.last.prompt),
        to_i64(state.last.cached),
        to_i64(state.last.completion),
        to_i64(state.day_total.prompt),
        to_i64(state.day_total.cached),
        to_i64(state.day_total.completion),
    ])?;
    Ok(())
}

fn totals(prompt: i64, cached: i64, completion: i64) -> CumulativeTotals {
    CumulativeTotals {
        prompt: from_i64(prompt),
        cached: from_i64(cached),
        completion: from_i64(completion),
    }
}

fn to_i64(value: u64) -> i64 {
    value.min(i64::MAX as u64) as i64
}

fn from_i64(value: i64) -> u64 {
    value.max(0) as u64
}
