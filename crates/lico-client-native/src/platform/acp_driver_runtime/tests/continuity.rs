use super::*;

#[test]
fn resume_uses_load_when_advertised_and_keeps_native_id() {
    let mut protocol = new_protocol(json!({}), "next", "existing-native");
    let effects = protocol.handle_message(initialize_response(true, true));
    let ProtocolEffect::Send(request) = &effects[0] else {
        panic!("expected load request")
    };
    assert_eq!(request["method"], "session/load");
    assert_eq!(request["params"]["sessionId"], "existing-native");
    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": SESSION_REQUEST_ID,
        "result": null
    }));
    assert!(matches!(effects[0], ProtocolEffect::Send(_)));
    assert_eq!(protocol.session_id.as_deref(), Some("existing-native"));
}

#[test]
fn resume_fails_closed_when_agent_does_not_advertise_it() {
    let mut protocol = new_protocol(json!({}), "next", "existing-native");
    let effects = protocol.handle_message(initialize_response(false, false));
    let ProtocolEffect::Fail(failure) = &effects[0] else {
        panic!("expected failure")
    };
    assert_eq!(failure.code, "acp_resume_unsupported");
}

#[test]
fn rejected_native_resume_never_falls_back_to_a_new_session() {
    let mut protocol = new_protocol(json!({}), "next", "missing-native");
    let effects = protocol.handle_message(initialize_response(true, true));
    let ProtocolEffect::Send(load) = &effects[0] else {
        panic!("expected load request")
    };
    assert_eq!(load["method"], "session/load");
    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": SESSION_REQUEST_ID,
        "error": {"code": -32002, "message": "not found"}
    }));
    assert_eq!(effects.len(), 1);
    let ProtocolEffect::Fail(failure) = &effects[0] else {
        panic!("expected resume failure")
    };
    assert_eq!(failure.code, "acp_native_session_not_found");
    assert_eq!(protocol.phase, ProtocolPhase::Finished);
}

#[test]
fn returned_resume_id_must_match_the_requested_native_session() {
    let config = ProtocolConfig::from_params(
        &json!({}),
        "next",
        "expected-native",
        Some(absolute_test_cwd().as_path()),
    )
    .unwrap();
    let failure = reconcile_acp_session_id(
        &config,
        AcpSessionPlan::Load,
        Some("different-native".to_string()),
    )
    .unwrap_err();
    assert_eq!(failure.code, "acp_session_id_mismatch");
    assert_eq!(failure.session_id.as_deref(), Some("expected-native"));
}
