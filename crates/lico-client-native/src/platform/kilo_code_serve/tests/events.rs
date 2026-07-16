use serde_json::json;

use super::super::project_event;

#[test]
fn target_event_lane_rejects_cross_session_and_unknown_payloads() {
    let event = json!({
        "type": "message.part.delta",
        "properties": {"sessionID": "kilo-1", "part": {"text": "answer"}}
    });
    assert_eq!(
        project_event("kilo-1", &event.to_string()).as_deref(),
        Some("answer")
    );
    assert_eq!(project_event("kilo-2", &event.to_string()), None);
    let missing_session = json!({
        "type": "message.part.delta",
        "properties": {"part": {"text": "private"}}
    });
    assert_eq!(project_event("kilo-1", &missing_session.to_string()), None);
}
