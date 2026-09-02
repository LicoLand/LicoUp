use serde_json::json;

use super::super::{local_service, project_event};

#[test]
fn target_event_lane_projects_only_assistant_text_parts() {
    let mut projection = local_service::serve::SessionEventProjection::default();
    let assistant_seen = json!({
        "type": "message.updated",
        "properties": {"info": {"id": "msg-agent", "role": "assistant", "sessionID": "kilo-1"}}
    });
    assert_eq!(
        project_event(&mut projection, "kilo-1", &assistant_seen.to_string()),
        None
    );
    let event = json!({
        "type": "message.part.updated",
        "properties": {
            "sessionID": "kilo-1",
            "part": {"id": "prt-1", "messageID": "msg-agent", "type": "text", "text": "answer"}
        }
    });
    assert_eq!(
        project_event(&mut projection, "kilo-1", &event.to_string()).as_deref(),
        Some("answer")
    );
    assert_eq!(
        project_event(&mut projection, "kilo-2", &event.to_string()),
        None
    );
    let user_part = json!({
        "type": "message.part.updated",
        "properties": {
            "sessionID": "kilo-1",
            "part": {"id": "prt-2", "messageID": "msg-user", "type": "text", "text": "private"}
        }
    });
    assert_eq!(
        project_event(&mut projection, "kilo-1", &user_part.to_string()),
        None
    );
    let missing_session = json!({
        "type": "message.part.updated",
        "properties": {
            "part": {"id": "prt-3", "messageID": "msg-agent", "type": "text", "text": "private"}
        }
    });
    assert_eq!(
        project_event(&mut projection, "kilo-1", &missing_session.to_string()),
        None
    );
}
