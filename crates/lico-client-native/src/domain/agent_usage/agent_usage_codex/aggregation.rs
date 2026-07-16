use super::super::contract::{HistoryUsageSummary, UNATTRIBUTED_MODEL};
use super::super::window::UsageWindow;
use super::models::ScanStats;
use super::utils::from_i64;
use anyhow::{Context, Result};
use rusqlite::{Connection, TransactionBehavior, params};
use std::collections::BTreeSet;

#[derive(Debug)]
struct UsageRow {
    source_key: String,
    session_id: Option<String>,
    day: String,
    model: Option<String>,
    input: u64,
    cached: u64,
    output: u64,
}

#[derive(Debug)]
struct UsageEstimateRow {
    source_key: String,
    session_id: Option<String>,
    day: String,
    model: Option<String>,
    role: String,
    tokens: u64,
}

pub(super) fn aggregate_cached_usage(
    connection: &mut Connection,
    root_key: &str,
    window: &UsageWindow,
    stats: ScanStats,
) -> Result<HistoryUsageSummary> {
    let snapshot = connection
        .transaction_with_behavior(TransactionBehavior::Deferred)
        .context("agent usage cache snapshot transaction failed")?;
    let mut summary = HistoryUsageSummary {
        source: Some("codex-local-token-events"),
        scan_cache: Some(stats.to_json()),
        ..HistoryUsageSummary::default()
    };
    let mut sessions = BTreeSet::<String>::new();
    {
        let mut statement = snapshot.prepare(
            "SELECT r.source_key, r.session_id, r.day, r.model,
                    r.input_tokens, r.cached_input_tokens, r.output_tokens
             FROM usage_rows r
             INNER JOIN usage_files f
               ON f.root_key=r.root_key AND f.source_key=r.source_key
             WHERE r.root_key=?1 AND r.day>=?2 AND r.day<=?3
               AND NOT EXISTS (
                 SELECT 1
                 FROM usage_rows prior
                 INNER JOIN usage_files prior_file
                   ON prior_file.root_key=prior.root_key
                  AND prior_file.source_key=prior.source_key
                 WHERE prior.root_key=r.root_key
                   AND prior.event_identity=r.event_identity
                   AND prior_file.lineage_scope=f.lineage_scope
                   AND (
                     CASE WHEN prior_file.forked_from_id IS NULL THEN 0 ELSE 1 END,
                     prior.day,
                     prior.source_key,
                     prior.event_index
                   ) < (
                     CASE WHEN f.forked_from_id IS NULL THEN 0 ELSE 1 END,
                     r.day,
                     r.source_key,
                     r.event_index
                   )
               )
             ORDER BY r.day, r.source_key, r.event_index",
        )?;
        let rows = statement.query_map(params![root_key, &window.start, &window.end], |row| {
            Ok(UsageRow {
                source_key: row.get(0)?,
                session_id: row.get(1)?,
                day: row.get(2)?,
                model: row.get(3)?,
                input: from_i64(row.get(4)?),
                cached: from_i64(row.get(5)?),
                output: from_i64(row.get(6)?),
            })
        })?;
        for row in rows {
            let row = row?;
            sessions.insert(
                row.session_id
                    .clone()
                    .unwrap_or_else(|| row.source_key.clone()),
            );
            let total = row.input.saturating_add(row.output);
            summary.explicit_prompt_tokens =
                summary.explicit_prompt_tokens.saturating_add(row.input);
            summary.explicit_cached_input_tokens = summary
                .explicit_cached_input_tokens
                .saturating_add(row.cached.min(row.input));
            summary.explicit_completion_tokens = summary
                .explicit_completion_tokens
                .saturating_add(row.output);
            summary.explicit_total_tokens = summary.explicit_total_tokens.saturating_add(total);
            summary.explicit_records = summary.explicit_records.saturating_add(1);
            summary.message_count = summary.message_count.saturating_add(1);
            let daily = summary.daily_usage.entry(row.day).or_default();
            daily.prompt_tokens = daily.prompt_tokens.saturating_add(row.input);
            daily.cached_input_tokens = daily
                .cached_input_tokens
                .saturating_add(row.cached.min(row.input));
            daily.completion_tokens = daily.completion_tokens.saturating_add(row.output);
            daily.total_tokens = daily.total_tokens.saturating_add(total);
            daily.message_count = daily.message_count.saturating_add(1);
            daily.explicit_records = daily.explicit_records.saturating_add(1);
            let model = row
                .model
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| UNATTRIBUTED_MODEL.to_string());
            daily.add_model_usage(model, row.input, row.cached, row.output, total);
        }
    }

    {
        let mut statement = snapshot.prepare(
            "SELECT e.source_key, e.session_id, e.day, e.model, e.role,
                    e.estimated_tokens
             FROM usage_estimates e
             INNER JOIN usage_files f
               ON f.root_key=e.root_key AND f.source_key=e.source_key
             WHERE e.root_key=?1 AND e.day>=?2 AND e.day<=?3
               AND NOT EXISTS (
                 SELECT 1
                 FROM usage_estimates prior
                 INNER JOIN usage_files prior_file
                   ON prior_file.root_key=prior.root_key
                  AND prior_file.source_key=prior.source_key
                 WHERE prior.root_key=e.root_key
                   AND prior.event_identity=e.event_identity
                   AND prior_file.lineage_scope=f.lineage_scope
                   AND (
                     CASE WHEN prior_file.forked_from_id IS NULL THEN 0 ELSE 1 END,
                     prior.day,
                     prior.source_key,
                     prior.estimate_index
                   ) < (
                     CASE WHEN f.forked_from_id IS NULL THEN 0 ELSE 1 END,
                     e.day,
                     e.source_key,
                     e.estimate_index
                   )
               )
               AND NOT EXISTS (
                 SELECT 1
                 FROM usage_estimate_coverage coverage
                 INNER JOIN usage_files coverage_file
                   ON coverage_file.root_key=coverage.root_key
                  AND coverage_file.source_key=coverage.source_key
                 WHERE coverage.root_key=e.root_key
                   AND coverage.event_identity=e.event_identity
                   AND coverage_file.lineage_scope=f.lineage_scope
               )
             ORDER BY e.day, e.source_key, e.estimate_index",
        )?;
        let rows = statement.query_map(params![root_key, &window.start, &window.end], |row| {
            Ok(UsageEstimateRow {
                source_key: row.get(0)?,
                session_id: row.get(1)?,
                day: row.get(2)?,
                model: row.get(3)?,
                role: row.get(4)?,
                tokens: from_i64(row.get(5)?),
            })
        })?;
        for row in rows {
            let row = row?;
            sessions.insert(
                row.session_id
                    .clone()
                    .unwrap_or_else(|| row.source_key.clone()),
            );
            let completion = matches!(row.role.as_str(), "agent" | "assistant");
            if completion {
                summary.estimated_completion_tokens = summary
                    .estimated_completion_tokens
                    .saturating_add(row.tokens);
            } else {
                summary.estimated_prompt_tokens =
                    summary.estimated_prompt_tokens.saturating_add(row.tokens);
            }
            summary.estimated_total_tokens =
                summary.estimated_total_tokens.saturating_add(row.tokens);
            summary.estimated_records = summary.estimated_records.saturating_add(1);
            summary.message_count = summary.message_count.saturating_add(1);
            let daily = summary.daily_usage.entry(row.day).or_default();
            if completion {
                daily.completion_tokens = daily.completion_tokens.saturating_add(row.tokens);
            } else {
                daily.prompt_tokens = daily.prompt_tokens.saturating_add(row.tokens);
            }
            daily.total_tokens = daily.total_tokens.saturating_add(row.tokens);
            daily.message_count = daily.message_count.saturating_add(1);
            daily.estimated_records = daily.estimated_records.saturating_add(1);
            let model = row
                .model
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| UNATTRIBUTED_MODEL.to_string());
            daily.add_model_usage(
                model,
                if completion { 0 } else { row.tokens },
                0,
                if completion { row.tokens } else { 0 },
                row.tokens,
            );
        }
    }
    snapshot
        .commit()
        .context("agent usage cache snapshot commit failed")?;
    summary.session_count = sessions.len() as u64;
    summary.source = match (summary.explicit_records > 0, summary.estimated_records > 0) {
        (true, true) => Some("codex-local-token-events+history-estimate"),
        (true, false) => Some("codex-local-token-events"),
        (false, true) => Some("codex-local-history-estimate"),
        (false, false) => None,
    };
    if summary.explicit_records > 0 || summary.estimated_records > 0 {
        summary
            .source_paths
            .insert("codex-local-usage-store".to_string());
    }
    Ok(summary)
}
