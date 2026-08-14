use super::support::{codex_database_path, scan_params, temp_dir, token_event};
use crate::domain::agent_usage;
use rusqlite::Connection;
use std::fs;

#[test]
fn parser_reconciles_explicit_deltas_and_model_context() {
    let history_root = temp_dir("parser-history");
    let state_root = temp_dir("parser-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"session"}}"#.to_string(),
            r#"{"timestamp":"2026-07-08T10:00:01Z","type":"turn_context","payload":{"model":"gpt-test"}}"#.to_string(),
            token_event("2026-07-08T10:00:02Z", (6, 2, 4), (6, 2, 4)),
            token_event("2026-07-08T10:00:03Z", (8, 2, 5), (2, 0, 1)),
        ]
        .join("\n"),
    )
    .unwrap();

    let result = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &result["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 13);
    assert_eq!(history["dailyUsage"][0]["modelUsage"]["gpt-test"], 13);
}

#[test]
fn parser_keeps_incomplete_jsonl_suffix_for_the_next_append() {
    let history_root = temp_dir("parser-partial-history");
    let state_root = temp_dir("parser-partial-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        r#"{"timestamp":"2026-07-08T10:00:00Z","type":"event_msg""#,
    )
    .unwrap();
    let result = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    assert_eq!(result["summary"]["totalTokens"], 0);
}

#[test]
fn parser_rolls_up_all_history_without_losing_windowed_token_deltas() {
    let history_root = temp_dir("parser-retention-history");
    let state_root = temp_dir("parser-retention-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            token_event("2026-01-01T10:00:00Z", (100, 20, 10), (100, 20, 10)),
            token_event("2026-07-08T10:00:00Z", (106, 20, 14), (6, 0, 4)),
        ]
        .join("\n"),
    )
    .unwrap();

    let result = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &result["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 10);
    assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 1);
    let database_path = codex_database_path(&state_root);
    let connection = Connection::open(database_path).unwrap();
    let retained_rows = connection
        .query_row("SELECT COUNT(*) FROM usage_daily_totals", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    assert_eq!(retained_rows, 2);
}

#[test]
fn current_day_details_are_compacted_after_the_calendar_rolls_over() {
    let history_root = temp_dir("parser-rollover-history");
    let state_root = temp_dir("parser-rollover-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        token_event("2026-07-10T10:00:00Z", (6, 2, 4), (6, 2, 4)),
    )
    .unwrap();
    let mut params = scan_params(&history_root, &state_root);
    let first = agent_usage::scan(&params).unwrap();
    assert_eq!(first["summary"]["totalTokens"], 10);
    let database_path = codex_database_path(&state_root);
    let connection = Connection::open(&database_path).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM usage_rows", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM usage_daily_totals", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        0
    );
    drop(connection);

    params["now"] = serde_json::json!("2026-07-11T12:00:00Z");
    let next_day = agent_usage::scan(&params).unwrap();
    assert_eq!(next_day["summary"]["totalTokens"], 10);
    let connection = Connection::open(database_path).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM usage_rows", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM usage_daily_totals", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        1
    );
}
