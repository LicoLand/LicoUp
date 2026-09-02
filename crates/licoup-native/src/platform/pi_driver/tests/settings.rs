use super::*;

#[test]
fn model_override_requires_provider_and_uses_rpc() {
    let failure = ProtocolConfig::from_params(
        &json!({"model": "model-without-provider"}),
        "hello",
        "",
        Some(absolute_test_cwd().as_path()),
    )
    .unwrap_err();
    assert_eq!(failure.code, "pi_model_provider_required");

    let config = ProtocolConfig::from_params(
        &json!({"model": "provider/model"}),
        "hello",
        "",
        Some(absolute_test_cwd().as_path()),
    )
    .unwrap();
    let mut protocol = PiProtocol::new(config);
    let _ = protocol.initial_request();
    let effects = protocol.handle_message(json!({
        "id": "lico-pi-initial-state",
        "type": "response",
        "command": "get_state",
        "success": true,
        "data": {"sessionId": "session-model"}
    }));
    let ProtocolEffect::Send(request) = &effects[0] else {
        panic!("initial state must advance to model configuration");
    };
    assert_eq!(request["type"], "set_model");
    assert_eq!(request["provider"], "provider");
    assert_eq!(request["modelId"], "model");
}

#[test]
fn thinking_override_uses_the_rpc_configuration_step() {
    let config = ProtocolConfig::from_params(
        &json!({"thinking": "high"}),
        "hello",
        "",
        Some(absolute_test_cwd().as_path()),
    )
    .unwrap();
    let mut protocol = PiProtocol::new(config);
    let _ = protocol.initial_request();
    let effects = protocol.handle_message(json!({
        "id": "lico-pi-initial-state",
        "type": "response",
        "command": "get_state",
        "success": true,
        "data": {"sessionId": "session-thinking"}
    }));
    let ProtocolEffect::Send(request) = &effects[0] else {
        panic!("initial state must advance to thinking configuration");
    };
    assert_eq!(request["type"], "set_thinking_level");
    assert_eq!(request["level"], "high");
}
