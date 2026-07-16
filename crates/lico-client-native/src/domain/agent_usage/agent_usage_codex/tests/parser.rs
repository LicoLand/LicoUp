use super::support::{scan_params, temp_dir, token_event};
use crate::domain::agent_usage;
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
