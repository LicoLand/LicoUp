use super::*;

#[test]
fn interrupt_message_carries_no_session_or_prompt() {
    let message = interrupt_request();
    assert_eq!(message["type"], "control_request");
    assert_eq!(
        message.pointer("/request/subtype"),
        Some(&json!("interrupt"))
    );
    assert!(message.get("session_id").is_none());
    assert!(message.get("prompt").is_none());
}

#[test]
fn permission_denial_echoes_only_request_identity_and_static_error() {
    let response = denied_control_response(&json!({
        "request_id": "request-1",
        "request": {"subtype": "can_use_tool", "input": {"secret": "value"}}
    }))
    .unwrap();
    assert_eq!(
        response.pointer("/response/request_id"),
        Some(&json!("request-1"))
    );
    assert!(!response.to_string().contains("secret"));
}
