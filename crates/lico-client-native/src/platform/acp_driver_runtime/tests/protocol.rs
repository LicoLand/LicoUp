use super::*;

#[test]
fn new_session_applies_settings_then_finishes_after_prompt_quiescence() {
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
    assert!(effects.is_empty());
    assert_eq!(protocol.phase, ProtocolPhase::AwaitPromptDrain);
    let effects = protocol.finish_prompt_drain();
    let ProtocolEffect::Complete(outcome) = &effects[0] else {
        panic!("expected completion")
    };
    assert_eq!(outcome.output, "final");
    assert_eq!(outcome.session_id, "native-session");
    assert_eq!(outcome.effective.model.as_deref(), Some("provider/model"));
    assert_eq!(outcome.events.len(), 1);
}

#[test]
fn prompt_response_before_multiple_notifications_preserves_complete_ordered_output() {
    let mut protocol = new_protocol(json!({}), "private", "");
    protocol.handle_message(initialize_response(true, true));
    protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": SESSION_REQUEST_ID,
        "result": {"sessionId": "native-session", "configOptions": []}
    }));

    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": PROMPT_REQUEST_ID,
        "result": {"stopReason": "end_turn"}
    }));
    assert!(effects.is_empty());
    assert_eq!(protocol.phase, ProtocolPhase::AwaitPromptDrain);

    for text in ["late ", "ordered"] {
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "native-session", "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text}
            }}
        }));
        assert!(effects.is_empty());
        assert_eq!(protocol.phase, ProtocolPhase::AwaitPromptDrain);
    }

    let effects = protocol.finish_prompt_drain();
    let ProtocolEffect::Complete(outcome) = &effects[0] else {
        panic!("expected completion after the bounded quiet state")
    };
    assert_eq!(outcome.output, "late ordered");
    assert_eq!(outcome.events.len(), 2);
    assert_eq!(outcome.events[0]["content"]["text"], "late ");
    assert_eq!(outcome.events[1]["content"]["text"], "ordered");
    assert_eq!(protocol.phase, ProtocolPhase::Finished);
    assert!(protocol.finish_prompt_drain().is_empty());
}

#[test]
fn prompt_drain_fails_closed_when_quiescence_has_no_agent_output() {
    let mut protocol = new_protocol(json!({}), "private", "");
    protocol.handle_message(initialize_response(true, true));
    protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": SESSION_REQUEST_ID,
        "result": {"sessionId": "native-session", "configOptions": []}
    }));
    let effects = protocol.handle_message(json!({
        "jsonrpc": "2.0", "id": PROMPT_REQUEST_ID,
        "result": {"stopReason": "end_turn"}
    }));
    assert!(effects.is_empty());

    let effects = protocol.finish_prompt_drain();
    let ProtocolEffect::Fail(failure) = &effects[0] else {
        panic!("empty output after the quiet bound must fail")
    };
    assert_eq!(failure.code, "acp_final_message_missing");
    assert_eq!(failure.turn_status.as_deref(), Some("end_turn"));
    assert_eq!(protocol.phase, ProtocolPhase::Finished);
}

#[test]
fn prompt_drain_rejects_mismatched_and_malformed_late_notifications() {
    for (message, expected_code) in [
        (
            json!({
                "jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": "other-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "wrong"}
                }}
            }),
            "acp_session_mismatch",
        ),
        (
            json!({
                "jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": "native-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": "not-a-content-object"
                }}
            }),
            "acp_session_update_invalid",
        ),
    ] {
        let mut protocol = new_protocol(json!({}), "private", "");
        protocol.handle_message(initialize_response(true, true));
        protocol.handle_message(json!({
            "jsonrpc": "2.0", "id": SESSION_REQUEST_ID,
            "result": {"sessionId": "native-session", "configOptions": []}
        }));
        let effects = protocol.handle_message(json!({
            "jsonrpc": "2.0", "id": PROMPT_REQUEST_ID,
            "result": {"stopReason": "end_turn"}
        }));
        assert!(effects.is_empty());

        let effects = protocol.handle_message(message);
        let ProtocolEffect::Fail(failure) = &effects[0] else {
            panic!("invalid late notification must fail")
        };
        assert_eq!(failure.code, expected_code);
        assert_eq!(protocol.phase, ProtocolPhase::Finished);
    }
}
