use super::super::serve::project_session_text;
use serde_json::json;

#[test]
fn event_projection_requires_allowlisted_type_and_exact_session() {
    let accepted = json!({
        "type": "message.part.delta",
        "properties": {"sessionID": "s-1", "part": {"text": "hello"}}
    });
    assert_eq!(
        project_session_text("s-1", &accepted.to_string()).as_deref(),
        Some("hello")
    );
    let missing_session = json!({
        "type": "message.part.delta",
        "properties": {"part": {"text": "private"}}
    });
    assert_eq!(
        project_session_text("s-1", &missing_session.to_string()),
        None
    );
    let unknown = json!({
        "type": "tool.updated",
        "properties": {"sessionID": "s-1", "part": {"text": "private"}}
    });
    assert_eq!(project_session_text("s-1", &unknown.to_string()), None);
}
