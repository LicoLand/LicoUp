use serde_json::json;

use super::super::project_event;

#[test]
fn target_event_lane_rejects_cross_session_and_unknown_payloads() {
    let event = json!({
        "type": "message.part.updated",
        "properties": {"sessionId": "open-1", "text": "answer"}
    });
    assert_eq!(
        project_event("open-1", &event.to_string()).as_deref(),
        Some("answer")
    );
    assert_eq!(project_event("open-2", &event.to_string()), None);
    let unknown = json!({
        "type": "tool.updated",
        "properties": {"sessionId": "open-1", "text": "private"}
    });
    assert_eq!(project_event("open-1", &unknown.to_string()), None);
}
