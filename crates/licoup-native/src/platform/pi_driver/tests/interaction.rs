use super::*;

#[test]
fn extension_ui_request_fails_closed() {
    let config = ProtocolConfig::from_params(
        &json!({}),
        "hello",
        "",
        Some(Path::new("/workspace/project")),
    )
    .unwrap();
    let mut protocol = PiProtocol::new(config);
    let effects = protocol.handle_message(json!({
        "type": "extension_ui_request",
        "id": "ui-1",
        "method": "confirm"
    }));
    assert!(matches!(
        effects[0],
        ProtocolEffect::Fail(ProtocolFailure {
            code: "pi_user_interaction_required",
            user_interaction_required: true,
            ..
        })
    ));
}
