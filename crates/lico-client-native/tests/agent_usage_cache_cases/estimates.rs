use super::support::*;

#[test]
fn codex_usage_merges_uncovered_session_estimates_with_explicit_events() {
    let history_root = temp_dir("codex-usage-mixed-coverage-history");
    let state_root = temp_dir("codex-usage-mixed-coverage-state");
    fs::write(
        history_root.join("explicit.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"explicit-session"}}"#,
            r#"{"timestamp":"2026-07-08T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ignored estimate"}]}}"#,
            &token_event("2026-07-08T10:00:02Z", (6, 2, 4), (6, 2, 4)),
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        history_root.join("estimated.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T11:00:00Z","type":"session_meta","payload":{"id":"estimated-session"}}"#,
            r#"{"timestamp":"2026-07-08T11:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"abcd"}]}}"#,
            r#"{"timestamp":"2026-07-08T11:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"wxyz"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let report = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 12);
    assert_eq!(history["tokenSourceBreakdown"]["explicitTotalTokens"], 10);
    assert_eq!(history["tokenSourceBreakdown"]["estimatedTotalTokens"], 2);
    assert_eq!(history["confidence"], "medium");
    assert_eq!(
        history["source"],
        "codex-local-token-events+history-estimate"
    );
}

#[test]
fn codex_usage_estimates_uncovered_tail_after_last_explicit_event() {
    let history_root = temp_dir("codex-usage-partial-session-history");
    let state_root = temp_dir("codex-usage-partial-session-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"partial-session"}}"#.to_string(),
            token_event("2026-07-08T10:00:01Z", (6, 2, 4), (6, 2, 4)),
            r#"{"timestamp":"2026-07-08T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"abcd"}]}}"#.to_string(),
            r#"{"timestamp":"2026-07-08T10:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"wxyz"}]}}"#.to_string(),
        ]
        .join("\n"),
    )
    .unwrap();

    let report = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 12);
    assert_eq!(history["tokenSourceBreakdown"]["estimatedTotalTokens"], 2);
    assert_eq!(history["confidence"], "medium");
}
