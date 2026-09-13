use super::super::constants::{CACHE_SCHEMA_VERSION, PARSER_REVISION};
use super::support::{codex_database_path, scan_params, temp_dir, token_event};
use crate::domain::agent_usage;
use rusqlite::Connection;
use serde_json::json;
use std::fs;

#[test]
fn aggregation_keeps_unknown_models_separate_from_explicit_turn_models() {
    let history_root = temp_dir("aggregation-history");
    let state_root = temp_dir("aggregation-state");
    let mut model_event: serde_json::Value =
        serde_json::from_str(&token_event("2026-07-10T10:00:06Z", (78, 2, 4), (7, 0, 0))).unwrap();
    model_event["payload"]["info"]["modelID"] = json!("gpt-5.6");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            json!({"type":"session_meta","payload":{"id":"session"}}).to_string(),
            token_event("2026-07-10T10:00:01Z", (6, 2, 4), (6, 2, 4)),
            json!({"type":"turn_context","payload":{"turn_id":"one","model":"gpt-5.5"}}).to_string(),
            json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"one"}}).to_string(),
            token_event("2026-07-10T10:00:02Z", (26, 2, 4), (20, 0, 0)),
            json!({"type":"turn_context","payload":{"turn_id":"one"}}).to_string(),
            token_event("2026-07-10T10:00:03Z", (31, 2, 4), (5, 0, 0)),
            json!({"type":"turn_context","payload":{"turn_id":"one","model":"gpt-5.5"}}).to_string(),
            token_event("2026-07-10T10:00:04Z", (41, 2, 4), (10, 0, 0)),
            json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"two"}}).to_string(),
            token_event("2026-07-10T10:00:05Z", (71, 2, 4), (30, 0, 0)),
            model_event.to_string(),
            token_event("2026-07-10T10:00:07Z", (81, 2, 4), (3, 0, 0)),
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"two"}}).to_string(),
            token_event("2026-07-10T10:00:08Z", (85, 2, 4), (4, 0, 0)),
            json!({"type":"turn_context","payload":{"turn_id":"three","model":"gpt-5.5"}}).to_string(),
            json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"four"}}).to_string(),
            token_event("2026-07-10T10:00:09Z", (86, 2, 4), (1, 0, 0)),
            json!({
                "timestamp": "2026-07-10T10:00:10Z",
                "type": "response_item",
                "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "abcd"}]}
            })
            .to_string(),
        ]
        .join("\n"),
    )
    .unwrap();

    let mut params = scan_params(&history_root, &state_root);
    let result = agent_usage::scan(&params).unwrap();
    let history = &result["agents"][0]["history"];
    let expected = json!({"Others":50,"gpt-5.5":30,"gpt-5.6":10});
    assert_eq!(history["totalTokens"], 90);
    assert_eq!(history["dailyUsage"][0]["modelUsage"], expected);
    assert_eq!(history["scanCache"]["schemaVersion"], CACHE_SCHEMA_VERSION);
    assert_eq!(history["scanCache"]["parserRevision"], PARSER_REVISION);
    let serialized = result.to_string();
    assert!(!serialized.contains(&history_root.to_string_lossy().to_string()));
    assert!(!serialized.contains("abcd"));
    let connection = Connection::open(codex_database_path(&state_root)).unwrap();
    let models = connection
        .prepare("SELECT model FROM usage_rows ORDER BY event_index")
        .unwrap()
        .query_map([], |row| row.get::<_, Option<String>>(0))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    assert_eq!(
        models,
        [
            None,
            Some("gpt-5.5"),
            None,
            Some("gpt-5.5"),
            None,
            Some("gpt-5.6"),
            Some("gpt-5.6"),
            None,
            None
        ]
        .map(|model| model.map(str::to_owned))
    );
    drop(connection);
    params["now"] = json!("2026-07-11T12:00:00Z");
    let rolled = agent_usage::scan(&params).unwrap();
    assert_eq!(rolled["summary"]["totalTokens"], 90);
    assert_eq!(
        rolled["agents"][0]["history"]["dailyUsage"][0]["modelUsage"],
        expected
    );
}
