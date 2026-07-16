use super::*;

#[test]
fn new_session_applies_settings_then_collects_only_matching_agent_output() {
    let mut protocol = new_protocol(json!({"model": "provider/model"}), "private", "");
    let effects = protocol.handle_message(initialize_response(true, true));
    assert!(matches!(effects[0], ProtocolEffect::Send(_)));
    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0",
        "id": SESSION_REQUEST_ID,
        "result": {
            "sessionId": "native-session",
            "configOptions": [{
                "id": "model", "name": "Model", "type": "select",
                "currentValue": "default", "options": [
                    {"value": "default", "name": "Default"},
                    {"value": "provider/model", "name": "Requested"}
                ]
            }]
        }
    }));
    let ProtocolEffect::Send(setting) = &effects[0] else {
        panic!("expected setting request")
    };
    assert_eq!(setting["method"], "session/set_config_option");
    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": FIRST_CONFIG_REQUEST_ID,
        "result": {"configOptions": [{
            "id": "model", "name": "Model", "type": "select",
            "currentValue": "provider/model", "options": []
        }]}
    }));
    let ProtocolEffect::Send(prompt) = &effects[0] else {
        panic!("expected prompt request")
    };
    assert_eq!(prompt["method"], "session/prompt");
    assert_eq!(prompt["params"]["prompt"][0]["text"], "private");
    protocol.handle_message(json!({
        "jsonrpc": "2.0", "method": "session/update",
        "params": {"sessionId": "native-session", "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "final"}
        }}
    }));
    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": PROMPT_REQUEST_ID,
        "result": {"stopReason": "end_turn"}
    }));
    let ProtocolEffect::Complete(outcome) = &effects[0] else {
        panic!("expected completion")
    };
    assert_eq!(outcome.output, "final");
    assert_eq!(outcome.session_id, "native-session");
    assert_eq!(outcome.effective.model.as_deref(), Some("provider/model"));
    assert_eq!(outcome.events.len(), 1);
}
