use super::{opaque_scope, positive, read_only_connection, sqlite_table_exists, table_columns};
use crate::domain::agent_usage::agent_usage_native::models::{
    CumulativeSnapshot, CumulativeTotals, ParseResult,
};
use crate::domain::agent_usage::attribution::message_usage;
use crate::domain::agent_usage::contract::HistoryUsageSummary;
use crate::domain::agent_usage::window::UsageWindow;
use crate::domain::conversation::usage::extract_token_usage;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

pub(super) fn parse_openagent_usage_database(
    path: &Path,
    calendar: &UsageWindow,
) -> Option<ParseResult> {
    let connection = read_only_connection(path)?;
    let has_sessions = sqlite_table_exists(&connection, "session");
    let has_messages = sqlite_table_exists(&connection, "message");
    if !has_sessions && !has_messages {
        return None;
    }
    let mut summary = HistoryUsageSummary::default();
    let mut sessions = BTreeSet::<String>::new();
    let mut session_models = BTreeMap::<String, String>::new();
    let mut aggregate_sessions = BTreeSet::<String>::new();
    let mut cumulative_snapshots = Vec::new();

    if has_sessions {
        collect_session_cumulative_metadata(
            &connection,
            calendar,
            &mut session_models,
            &mut aggregate_sessions,
            &mut cumulative_snapshots,
        )?;
    }
    let mut exact_usage_sessions = BTreeSet::new();
    if has_messages {
        collect_message_usage_metadata(
            &connection,
            calendar,
            &aggregate_sessions,
            &session_models,
            &mut summary,
            &mut sessions,
            &mut exact_usage_sessions,
        )?;
    }
    for snapshot in &mut cumulative_snapshots {
        snapshot.projects_usage = snapshot.first_day == snapshot.observed_day
            || !exact_usage_sessions.contains(&snapshot.session_key);
    }
    summary.session_count = sessions.len() as u64;
    summary.message_count = summary.explicit_records;
    Some(ParseResult {
        summary,
        cumulative_snapshots,
        ..ParseResult::default()
    })
}

fn collect_session_cumulative_metadata(
    connection: &rusqlite::Connection,
    calendar: &UsageWindow,
    session_models: &mut BTreeMap<String, String>,
    aggregate_sessions: &mut BTreeSet<String>,
    cumulative_snapshots: &mut Vec<CumulativeSnapshot>,
) -> Option<()> {
    let columns = table_columns(connection, "session");
    let required = [
        "id",
        "time_created",
        "time_updated",
        "tokens_input",
        "tokens_output",
        "tokens_reasoning",
        "tokens_cache_read",
        "tokens_cache_write",
    ];
    if required.iter().any(|column| !columns.contains(*column)) {
        return Some(());
    }
    let model_column = if columns.contains("model") {
        "model"
    } else {
        "NULL"
    };
    let time_filter = epoch_numeric_filter(calendar, "time_updated");
    let sql = format!(
        "SELECT id,{model_column},time_created,time_updated,tokens_input,
                tokens_output,tokens_reasoning,tokens_cache_read,tokens_cache_write
         FROM session{time_filter}"
    );
    let mut statement = connection.prepare(&sql).ok()?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<i64>>(2)?,
                row.get::<_, Option<i64>>(3)?,
                row.get::<_, Option<i64>>(4)?.unwrap_or(0),
                row.get::<_, Option<i64>>(5)?.unwrap_or(0),
                row.get::<_, Option<i64>>(6)?.unwrap_or(0),
                row.get::<_, Option<i64>>(7)?.unwrap_or(0),
                row.get::<_, Option<i64>>(8)?.unwrap_or(0),
            ))
        })
        .ok()?;
    for (id, model, created, updated, input, output, reasoning, cache_read, cache_write) in
        rows.flatten()
    {
        let Some(id) = id else {
            continue;
        };
        if let Some(model) = model
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            session_models.insert(id.clone(), model.to_owned());
        }
        let (Some(created), Some(updated)) = (created, updated) else {
            continue;
        };
        let (Some(created_day), Some(updated_day)) = (
            calendar.date_key(&created.to_string()),
            calendar.date_key(&updated.to_string()),
        ) else {
            continue;
        };
        if !calendar.contains(&updated_day) {
            continue;
        }
        let prompt = positive(input)
            .saturating_add(positive(cache_read))
            .saturating_add(positive(cache_write));
        let completion = positive(output).saturating_add(positive(reasoning));
        if prompt == 0 && completion == 0 {
            continue;
        }
        let model = model.filter(|value| !value.trim().is_empty());
        let session_key = opaque_scope(&id);
        cumulative_snapshots.push(CumulativeSnapshot {
            usage_key: opaque_scope(&format!("{id}\0{}", model.as_deref().unwrap_or_default())),
            session_key,
            model,
            first_day: created_day.clone(),
            observed_day: updated_day.clone(),
            totals: CumulativeTotals {
                prompt,
                cached: positive(cache_read).min(prompt),
                completion,
            },
            projects_usage: true,
        });
        if created_day == updated_day {
            aggregate_sessions.insert(id);
        }
    }
    Some(())
}

fn collect_message_usage_metadata(
    connection: &rusqlite::Connection,
    calendar: &UsageWindow,
    aggregate_sessions: &BTreeSet<String>,
    session_models: &BTreeMap<String, String>,
    summary: &mut HistoryUsageSummary,
    sessions: &mut BTreeSet<String>,
    exact_usage_sessions: &mut BTreeSet<String>,
) -> Option<()> {
    let columns = table_columns(connection, "message");
    if ["session_id", "time_created", "data"]
        .iter()
        .any(|column| !columns.contains(*column))
    {
        return Some(());
    }
    let order = if columns.contains("id") {
        "time_created ASC,id ASC"
    } else {
        "time_created ASC"
    };
    let time_filter = epoch_numeric_filter(calendar, "time_created");
    let sql = format!(
        "SELECT session_id,
                CAST(COALESCE(
                  CASE WHEN json_valid(CAST(data AS TEXT))
                    THEN json_extract(CAST(data AS TEXT), '$.time.created') END,
                  time_created,
                  CASE WHEN json_valid(CAST(data AS TEXT))
                    THEN json_extract(CAST(data AS TEXT), '$.createdAt') END,
                  CASE WHEN json_valid(CAST(data AS TEXT))
                    THEN json_extract(CAST(data AS TEXT), '$.timestamp') END
                ) AS TEXT),
                CASE WHEN json_valid(CAST(data AS TEXT)) THEN CAST(COALESCE(
                  json_extract(CAST(data AS TEXT), '$.usage'),
                  json_extract(CAST(data AS TEXT), '$.tokens'),
                  json_extract(CAST(data AS TEXT), '$.tokenUsage'),
                  json_extract(CAST(data AS TEXT), '$.token_usage'),
                  json_extract(CAST(data AS TEXT), '$.usageMetadata'),
                  json_extract(CAST(data AS TEXT), '$.usage_metadata'),
                  json_extract(CAST(data AS TEXT), '$.responseUsage'),
                  json_extract(CAST(data AS TEXT), '$.response_usage'),
                  json_extract(CAST(data AS TEXT), '$.tokenCount'),
                  json_extract(CAST(data AS TEXT), '$.\"gen_ai.usage\"')
                ) AS TEXT) END,
                CASE WHEN json_valid(CAST(data AS TEXT)) THEN CAST(COALESCE(
                  json_extract(CAST(data AS TEXT), '$.modelID'),
                  json_extract(CAST(data AS TEXT), '$.modelId'),
                  json_extract(CAST(data AS TEXT), '$.model_id'),
                  json_extract(CAST(data AS TEXT), '$.model'),
                  json_extract(CAST(data AS TEXT), '$.modelName')
                ) AS TEXT) END
         FROM message{time_filter} ORDER BY {order}"
    );
    let mut statement = connection.prepare(&sql).ok()?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })
        .ok()?;
    for (session_id, timestamp, usage_json, message_model) in rows.flatten() {
        if session_id
            .as_ref()
            .is_some_and(|id| aggregate_sessions.contains(id))
        {
            continue;
        }
        let (Some(timestamp), Some(usage_json)) = (timestamp, usage_json) else {
            continue;
        };
        let Some(day) = calendar.date_key(&timestamp) else {
            continue;
        };
        if !calendar.contains(&day) {
            continue;
        }
        let Ok(raw_usage) = serde_json::from_str::<Value>(&usage_json) else {
            continue;
        };
        let Some(normalized) = extract_token_usage(&raw_usage) else {
            continue;
        };
        let model = message_model
            .filter(|value| !value.trim().is_empty())
            .or_else(|| {
                session_id
                    .as_ref()
                    .and_then(|id| session_models.get(id).cloned())
            });
        let envelope = json!({"model": model, "usage": normalized});
        let Some(usage) = message_usage(&envelope, model) else {
            continue;
        };
        summary.add(usage, Some(day));
        if let Some(session_id) = session_id {
            let session_key = opaque_scope(&session_id);
            sessions.insert(session_key.clone());
            exact_usage_sessions.insert(session_key);
        }
    }
    Some(())
}

fn epoch_numeric_filter(calendar: &UsageWindow, column: &str) -> String {
    calendar
        .coarse_epoch_millis_bounds()
        .map(|(lower_ms, upper_ms)| {
            let lower_s = lower_ms / 1_000;
            let upper_s = upper_ms / 1_000;
            let lower_us = lower_ms.saturating_mul(1_000);
            let upper_us = upper_ms.saturating_mul(1_000);
            let lower_ns = lower_ms.saturating_mul(1_000_000);
            let upper_ns = upper_ms.saturating_mul(1_000_000);
            format!(
                " WHERE ({column}>={lower_s} AND {column}<{upper_s})
                    OR ({column}>={lower_ms} AND {column}<{upper_ms})
                    OR ({column}>={lower_us} AND {column}<{upper_us})
                    OR ({column}>={lower_ns} AND {column}<{upper_ns})"
            )
        })
        .unwrap_or_default()
}
