use super::*;

#[test]
fn event_projection_keeps_text_delta_and_removes_vendor_metadata() {
    let private_path = ["/", "private", "path"].join("/");
    let message = json!({
        "type": "stream_event",
        "session_id": "private-session",
        "event": {
            "type": "content_block_delta",
            "delta": {"type": "text_delta", "text": "visible"}
        },
        "tool_input": {"path": private_path.clone()}
    });
    assert_eq!(partial_text_delta(&message), Some("visible"));
    let projected = project_event(&message).unwrap();
    assert_eq!(
        projected.pointer("/event/delta/text"),
        Some(&json!("visible"))
    );
    let encoded = projected.to_string();
    assert!(!encoded.contains("private-session"));
    assert!(!encoded.contains(&private_path));
}

#[test]
fn assistant_projection_does_not_copy_message_content() {
    let projected = project_event(&json!({
        "type": "assistant",
        "message": {"content": [{"text": "uncommitted draft"}]}
    }))
    .unwrap();
    assert_eq!(
        projected,
        json!({"type": "assistant", "contentAvailable": true})
    );
}
