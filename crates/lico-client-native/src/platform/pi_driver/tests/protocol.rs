use super::*;

#[test]
fn new_session_prompt_stays_on_stdio_channel() {
    let config = ProtocolConfig::from_params(
        &json!({}),
        "private-pi-prompt",
        "",
        Some(absolute_test_cwd().as_path()),
    )
    .unwrap();
    let mut protocol = PiProtocol::new(config);
    let request = protocol.initial_request();
    assert_eq!(request["type"], "get_state");
    let effects = protocol.handle_message(json!({
        "id": "lico-pi-initial-state",
        "type": "response",
        "command": "get_state",
        "success": true,
        "data": {"sessionId": "new-session"}
    }));
    let ProtocolEffect::Send(prompt) = &effects[0] else {
        panic!("initial state must advance to prompt");
    };
    assert_eq!(prompt["type"], "prompt");
    assert_eq!(prompt["message"], "private-pi-prompt");
    let launch = LaunchSpec::new("pi", absolute_test_cwd().as_path());
    assert!(
        !launch
            .args
            .iter()
            .any(|arg| arg.contains("private-pi-prompt"))
    );
}

#[test]
fn switched_state_must_confirm_requested_identity() {
    let config = resume_config(
        "continue",
        "expected-session",
        absolute_test_cwd().join("session.jsonl"),
    );
    let mut protocol = PiProtocol::new(config);
    let _ = protocol.initial_request();
    let switch = protocol.handle_message(json!({
        "id": "lico-pi-switch",
        "type": "response",
        "command": "switch_session",
        "success": true,
        "data": {"cancelled": false}
    }));
    assert!(matches!(switch[0], ProtocolEffect::Send(_)));
    let state = protocol.handle_message(json!({
        "id": "lico-pi-switched-state",
        "type": "response",
        "command": "get_state",
        "success": true,
        "data": {"sessionId": "wrong-session"}
    }));
    assert!(matches!(
        state[0],
        ProtocolEffect::Fail(ProtocolFailure {
            code: "pi_session_identity_mismatch",
            ..
        })
    ));
}
