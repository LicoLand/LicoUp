use serde_json::json;

use crate::platform::native_agent_parser::adapters::kilo_code::ServeEventParser;

#[test]
fn target_event_lane_projects_only_assistant_text_parts() {
    let mut projection = ServeEventParser::new("kilo-1");
    let assistant_seen = json!({
        "type": "message.updated",
        "properties": {"info": {"id": "msg-agent", "role": "assistant", "sessionID": "kilo-1"}}
    });
    assert_eq!(projection.observe(&assistant_seen.to_string()), Ok(None));
    let event = json!({
        "type": "message.part.updated",
        "properties": {
            "sessionID": "kilo-1",
            "part": {"id": "prt-1", "messageID": "msg-agent", "type": "text", "text": "answer"}
        }
    });
    assert_eq!(
        projection.observe(&event.to_string()),
        Ok(Some("answer".into()))
    );
    assert_eq!(
        ServeEventParser::new("kilo-2").observe(&event.to_string()),
        Ok(None)
    );
    let user_part = json!({
        "type": "message.part.updated",
        "properties": {
            "sessionID": "kilo-1",
            "part": {"id": "prt-2", "messageID": "msg-user", "type": "text", "text": "private"}
        }
    });
    assert_eq!(projection.observe(&user_part.to_string()), Ok(None));
    let missing_session = json!({
        "type": "message.part.updated",
        "properties": {
            "part": {"id": "prt-3", "messageID": "msg-agent", "type": "text", "text": "private"}
        }
    });
    assert_eq!(projection.observe(&missing_session.to_string()), Ok(None));
}
