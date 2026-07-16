use super::*;

#[test]
fn permission_request_is_cancelled_and_reported_as_user_interaction() {
    let mut protocol = new_protocol(json!({}), "prompt", "");
    protocol.handle_message(initialize_response(true, true));
    protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": SESSION_REQUEST_ID,
        "result": {"sessionId": "native", "configOptions": []}
    }));
    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": 91, "method": "session/request_permission",
        "params": {"sessionId": "native", "options": []}
    }));
    assert_eq!(effects.len(), 2);
    let ProtocolEffect::Send(response) = &effects[0] else {
        panic!("expected permission response")
    };
    assert_eq!(response["result"]["outcome"]["outcome"], "cancelled");
    let ProtocolEffect::Send(cancel) = &effects[1] else {
        panic!("expected ACP cancel notification")
    };
    assert_eq!(cancel["method"], acp::SESSION_CANCEL_METHOD);
    assert_eq!(cancel["params"]["sessionId"], "native");
    assert!(cancel.get("id").is_none());
    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": PROMPT_REQUEST_ID,
        "result": {"stopReason": "cancelled"}
    }));
    let ProtocolEffect::Fail(failure) = &effects[0] else {
        panic!("expected interaction failure")
    };
    assert!(failure.user_interaction_required);
}
