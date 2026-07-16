use super::super::constants::{CACHE_SCHEMA_VERSION, PARSER_REVISION};
use super::support::{scan_params, temp_dir, token_event};
use crate::domain::agent_usage;
use serde_json::json;
use std::fs;

#[test]
fn aggregation_attributes_missing_models_without_losing_tokens_or_paths() {
    let history_root = temp_dir("aggregation-history");
    let state_root = temp_dir("aggregation-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"session"}}"#.to_string(),
            token_event("2026-07-08T10:00:01Z", (6, 2, 4), (6, 2, 4)),
            json!({
                "timestamp": "2026-07-08T10:00:02Z",
                "type": "response_item",
                "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "abcd"}]}
            })
            .to_string(),
        ]
        .join("\n"),
    )
    .unwrap();

    let result = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &result["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 11);
    assert_eq!(history["dailyUsage"][0]["modelUsage"]["Others"], 11);
    assert_eq!(history["scanCache"]["schemaVersion"], CACHE_SCHEMA_VERSION);
    assert_eq!(history["scanCache"]["parserRevision"], PARSER_REVISION);
    let serialized = result.to_string();
    assert!(!serialized.contains(&history_root.to_string_lossy().to_string()));
    assert!(!serialized.contains("abcd"));
}
