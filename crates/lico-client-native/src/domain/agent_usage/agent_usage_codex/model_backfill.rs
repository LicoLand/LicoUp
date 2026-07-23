//! Session-dominant model backfill for unattributed token events.

use super::super::contract::UNATTRIBUTED_MODEL;
use super::super::window::UsageWindow;
use super::utils::from_i64;
use anyhow::Result;
use rusqlite::{Transaction, params};
use std::collections::BTreeMap;

/// Token events that precede the first `turn_context` in a rollout file carry
/// no model; attribute them to the dominant labeled model of their session
/// instead of the unattributed bucket.
pub(super) fn attributed_model(
    model: &Option<String>,
    session_id: Option<&String>,
    source_key: &str,
    dominant_models: &BTreeMap<String, String>,
) -> String {
    if let Some(model) = model.as_ref().filter(|value| !value.trim().is_empty()) {
        return model.clone();
    }
    let session = session_id.map(String::as_str).unwrap_or(source_key);
    dominant_models
        .get(session)
        .cloned()
        .unwrap_or_else(|| UNATTRIBUTED_MODEL.to_string())
}

/// Dominant (token-weighted) labeled model per session over the window.
pub(super) fn session_dominant_models(
    snapshot: &Transaction,
    root_key: &str,
    window: &UsageWindow,
) -> Result<BTreeMap<String, String>> {
    let mut statement = snapshot.prepare(
        "SELECT r.session_id, r.source_key, r.model,
                SUM(r.input_tokens + r.output_tokens) AS tokens
         FROM usage_rows r
         WHERE r.root_key=?1 AND r.day>=?2 AND r.day<=?3
           AND r.model IS NOT NULL AND trim(r.model)<>''
         GROUP BY r.source_key, r.session_id, r.model",
    )?;
    let rows = statement.query_map(params![root_key, &window.start, &window.end], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            from_i64(row.get(3)?),
        ))
    })?;
    let mut weights = BTreeMap::<String, BTreeMap<String, u64>>::new();
    for row in rows {
        let (session_id, source_key, model, tokens) = row?;
        let session = session_id.unwrap_or(source_key);
        *weights
            .entry(session)
            .or_default()
            .entry(model)
            .or_default() += tokens.max(1);
    }
    Ok(weights
        .into_iter()
        .filter_map(|(session, models)| {
            models
                .into_iter()
                .max_by(|(left_model, left_tokens), (right_model, right_tokens)| {
                    left_tokens
                        .cmp(right_tokens)
                        .then(right_model.cmp(left_model))
                })
                .map(|(model, _)| (session, model))
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unattributed_rows_fall_back_to_session_dominant_model() {
        let dominant = BTreeMap::from([("session-1".to_string(), "gpt-5.5".to_string())]);
        let session = "session-1".to_string();
        assert_eq!(
            attributed_model(&Some("gpt-5.6".to_string()), None, "src", &dominant),
            "gpt-5.6"
        );
        assert_eq!(
            attributed_model(&None, Some(&session), "src", &dominant),
            "gpt-5.5"
        );
        assert_eq!(
            attributed_model(&Some(" ".to_string()), None, "src-missing", &dominant),
            UNATTRIBUTED_MODEL
        );
    }
}
