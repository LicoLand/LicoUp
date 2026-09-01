use serde_json::json;

use crate::platform::native_agent_parser::adapters::opencode::ServeEventParser;

#[test]
fn target_event_lane_projects_only_assistant_text_parts() {
    let mut projection = ServeEventParser::new("open-1");
    let assistant_seen = json!({
        "type": "message.updated",
        "properties": {"info": {"id": "msg-agent", "role": "assistant", "sessionID": "open-1"}}
    });
    assert_eq!(projection.observe(&assistant_seen.to_string()), Ok(None));
    let event = json!({
        "type": "message.part.updated",
        "properties": {
            "sessionId": "open-1",
            "part": {"id": "prt-1", "messageID": "msg-agent", "type": "text", "text": "answer"}
        }
    });
    assert_eq!(
        projection.observe(&event.to_string()),
        Ok(Some("answer".into()))
    );
    assert_eq!(
        ServeEventParser::new("open-2").observe(&event.to_string()),
        Ok(None)
    );
    let user_part = json!({
        "type": "message.part.updated",
        "properties": {
            "sessionID": "open-1",
            "part": {"id": "prt-2", "messageID": "msg-user", "type": "text", "text": "private"}
        }
    });
    assert_eq!(projection.observe(&user_part.to_string()), Ok(None));
    let unknown = json!({
        "type": "tool.updated",
        "properties": {"sessionId": "open-1", "text": "private"}
    });
    assert_eq!(projection.observe(&unknown.to_string()), Ok(None));
}
