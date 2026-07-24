use super::*;

#[test]
fn exact_resume_uses_session_load_inside_json_rpc() {
    let mut protocol = SessionProtocol::new(config(json!({}), "hello", "native-session"));
    let session = sent_messages(initialize(&mut protocol));
    assert_eq!(session[0]["method"], "session/load");
    assert_eq!(session[0]["params"]["sessionId"], "native-session");
}

#[test]
fn interrupted_turn_keeps_native_session_for_exact_continue() {
    let mut protocol = SessionProtocol::new(config(json!({}), "hello", "native-session"));
    initialize(&mut protocol);
    protocol.handle_message(json!({"jsonrpc": "2.0", "id": SESSION_REQUEST_ID, "result": null}));
    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0",
        "id": PROMPT_REQUEST_ID,
        "result": {"stopReason": "cancelled"}
    }));
    match &effects[0] {
        ProtocolEffect::Fail(failure) => {
            assert_eq!(failure.code, "hermes_acp_turn_not_completed");
            assert_eq!(failure.session_id.as_deref(), Some("native-session"));
            assert_eq!(failure.turn_status.as_deref(), Some("cancelled"));
        }
        _ => panic!("interrupted turn must fail closed while retaining native session id"),
    }
}
