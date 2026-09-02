use super::super::serve::SessionEventProjection;
use serde_json::json;

fn message_updated(session_id: &str, message_id: &str, role: &str) -> String {
    json!({
        "type": "message.updated",
        "properties": {
            "info": {"id": message_id, "role": role, "sessionID": session_id}
        }
    })
    .to_string()
}

fn part_updated(session_id: &str, message_id: &str, part_type: &str, text: &str) -> String {
    json!({
        "type": "message.part.updated",
        "properties": {
            "sessionID": session_id,
            "part": {
                "id": "prt-1",
                "messageID": message_id,
                "sessionID": session_id,
                "type": part_type,
                "text": text
            }
        }
    })
    .to_string()
}

#[test]
fn user_prompt_echo_never_projects_as_assistant_content() {
    // Real OpenCode 1.17.18 sequence: the user message and its text part are
    // published before the assistant message streams.
    let mut projection = SessionEventProjection::default();
    assert_eq!(
        projection.observe("s-1", &message_updated("s-1", "msg-user", "user")),
        None
    );
    assert_eq!(
        projection.observe(
            "s-1",
            &part_updated("s-1", "msg-user", "text", "private-prompt")
        ),
        None,
        "the user's own text part must not render as assistant output"
    );
    assert_eq!(
        projection.observe("s-1", &message_updated("s-1", "msg-agent", "assistant")),
        None
    );
    assert_eq!(
        projection
            .observe(
                "s-1",
                &part_updated("s-1", "msg-agent", "reasoning", "thinking")
            )
            .as_deref(),
        None,
        "reasoning parts are not final answer content"
    );
    assert_eq!(
        projection
            .observe(
                "s-1",
                &part_updated("s-1", "msg-agent", "text", "real answer")
            )
            .as_deref(),
        Some("real answer")
    );
}

#[test]
fn parts_with_unknown_role_fail_closed_and_cross_session_parts_drop() {
    let mut projection = SessionEventProjection::default();
    assert_eq!(
        projection.observe("s-1", &part_updated("s-1", "msg-unseen", "text", "early")),
        None,
        "a part whose message role is not yet known must fail closed"
    );
    assert_eq!(
        projection.observe("s-1", &message_updated("s-1", "msg-agent", "assistant")),
        None
    );
    assert_eq!(
        projection.observe("s-1", &part_updated("s-2", "msg-agent", "text", "private")),
        None,
        "cross-session parts never project"
    );
    let unknown = json!({
        "type": "tool.updated",
        "properties": {"sessionID": "s-1", "part": {"text": "private"}}
    });
    assert_eq!(projection.observe("s-1", &unknown.to_string()), None);
}
