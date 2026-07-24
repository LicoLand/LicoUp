use serde_json::{Value, json};
use std::fs;

use super::support::TestRoot;

#[test]
fn activity_jsonl_is_filterable_bounded_and_path_redacted() {
    let root = TestRoot::new("activity");
    let store = super::super::ClientStateStore::new(root.path().join("state")).unwrap();
    let log = store.activity_log();
    log.append(
        "target.config.applied",
        json!({
            "target": "opencode",
            "configPath": root.path().join("private-config"),
            "accessToken": "activity-token-canary"
        }),
    )
    .unwrap();
    log.append("skill.hidden", json!({"target": "codex"}))
        .unwrap();

    let listed = log
        .list(&json!({"target": "opencode", "limit": 1}))
        .unwrap();
    let events = listed["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["type"], "target.config.applied");
    assert_eq!(
        events[0]["payload"]["configPath"],
        super::super::policy::REDACTED_LOCAL_PATH
    );
    assert_eq!(
        events[0]["payload"]["accessToken"],
        super::super::policy::REDACTED_SECRET
    );
    assert_eq!(listed["path"], "activity/activity.jsonl");
    assert!(!listed.to_string().contains(root.path().to_str().unwrap()));

    let raw = fs::read_to_string(
        store
            .root()
            .join(super::super::policy::ACTIVITY_DIR)
            .join(super::super::policy::ACTIVITY_FILE),
    )
    .unwrap();
    assert!(
        raw.lines()
            .all(|line| serde_json::from_str::<Value>(line).is_ok())
    );
    assert!(!raw.contains("activity-token-canary"));
}

#[test]
fn activity_limit_keeps_only_the_latest_matching_events() {
    let root = TestRoot::new("activity-limit");
    let store = super::super::ClientStateStore::new(root.path().join("state")).unwrap();
    let log = store.activity_log();
    for index in 0..4 {
        log.append("task.finished", json!({"target": "codex", "index": index}))
            .unwrap();
    }

    let listed = log.list(&json!({"limit": 2})).unwrap();
    assert_eq!(listed["events"].as_array().unwrap().len(), 2);
    assert_eq!(listed["events"][0]["payload"]["index"], 2);
    assert_eq!(listed["events"][1]["payload"]["index"], 3);
}

#[test]
fn activity_rejects_unbounded_or_path_shaped_event_types() {
    let root = TestRoot::new("activity-type");
    let store = super::super::ClientStateStore::new(root.path().join("state")).unwrap();
    let log = store.activity_log();

    assert!(log.append("../../private", json!({})).is_err());
    assert!(
        log.append(
            &"x".repeat(super::super::policy::MAX_ACTIVITY_TYPE_BYTES + 1),
            json!({})
        )
        .is_err()
    );
}
