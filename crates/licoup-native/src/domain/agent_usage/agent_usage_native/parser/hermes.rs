use super::{opaque_scope, positive, read_only_connection, select_column, table_columns};
use crate::domain::agent_usage::agent_usage_native::models::{
    CumulativeSnapshot, CumulativeTotals, ParseResult,
};
use crate::domain::agent_usage::window::UsageWindow;
use std::path::Path;

pub(super) fn parse_hermes_usage_database(
    path: &Path,
    calendar: &UsageWindow,
) -> Option<ParseResult> {
    let connection = read_only_connection(path)?;
    let columns = table_columns(&connection, "session_model_usage");
    let required = ["session_id", "model", "input_tokens", "output_tokens"];
    if required.iter().any(|column| !columns.contains(*column)) {
        return None;
    }
    let cache_read = select_column(&columns, &["cache_read_tokens", "cached_input_tokens"]);
    let cache_write = select_column(&columns, &["cache_write_tokens"]);
    let reasoning = select_column(&columns, &["reasoning_tokens"]);
    let first_seen = select_column(&columns, &["first_seen", "first_seen_at"]);
    let last_seen = select_column(&columns, &["last_seen", "last_seen_at"]);
    if first_seen == "NULL" || last_seen == "NULL" {
        return None;
    }
    let sql = format!(
        "SELECT session_id, model, input_tokens, output_tokens, {cache_read},
         {cache_write}, {reasoning}, {first_seen}, {last_seen}
         FROM session_model_usage"
    );
    let mut statement = connection.prepare(&sql).ok()?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<i64>>(2)?.unwrap_or(0),
                row.get::<_, Option<i64>>(3)?.unwrap_or(0),
                row.get::<_, Option<i64>>(4)?.unwrap_or(0),
                row.get::<_, Option<i64>>(5)?.unwrap_or(0),
                row.get::<_, Option<i64>>(6)?.unwrap_or(0),
                row.get::<_, Option<String>>(7)?,
                row.get::<_, Option<String>>(8)?,
            ))
        })
        .ok()?;
    let mut cumulative_snapshots = Vec::new();
    for (session, model, input, output, cache_read, cache_write, reasoning, first, last) in
        rows.flatten()
    {
        let (Some(first), Some(last)) = (first, last) else {
            continue;
        };
        let (Some(first_day), Some(last_day)) =
            (calendar.date_key(&first), calendar.date_key(&last))
        else {
            continue;
        };
        if !calendar.contains(&last_day) {
            continue;
        }
        let prompt = positive(input)
            .saturating_add(positive(cache_read))
            .saturating_add(positive(cache_write));
        let completion = positive(output).saturating_add(positive(reasoning));
        if prompt == 0 && completion == 0 {
            continue;
        }
        let session = session.unwrap_or_default();
        let model = model.filter(|value| !value.trim().is_empty());
        cumulative_snapshots.push(CumulativeSnapshot {
            usage_key: opaque_scope(&format!(
                "{session}\0{}",
                model.as_deref().unwrap_or_default()
            )),
            session_key: opaque_scope(&session),
            model,
            first_day,
            observed_day: last_day,
            totals: CumulativeTotals {
                prompt,
                cached: positive(cache_read).min(prompt),
                completion,
            },
            projects_usage: true,
        });
    }
    Some(ParseResult {
        cumulative_snapshots,
        ..ParseResult::default()
    })
}
