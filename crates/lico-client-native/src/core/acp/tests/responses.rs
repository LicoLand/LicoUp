use super::*;
use serde_json::json;

#[test]
fn initialize_response_validates_version_and_capability_types() {
    let response = validate_initialize_response(
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "protocolVersion": 1,
                "agentCapabilities": {
                    "loadSession": true,
                    "sessionCapabilities": {"resume": {}, "close": {}},
                    "promptCapabilities": {"image": true},
                    "mcpCapabilities": {"http": true, "sse": false}
                }
            }
        }),
        1,
    )
    .unwrap();
    assert!(response.capabilities.load_session);
    assert!(response.capabilities.resume_session);
    assert!(response.capabilities.close_session);
    assert!(response.capabilities.image_prompts);
    assert!(response.capabilities.mcp_http);

    let unsupported = validate_initialize_response(
        &json!({"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": 2}}),
        1,
    );
    assert_eq!(
        unsupported.unwrap_err(),
        AcpError::UnsupportedProtocolVersion { received: 2 }
    );
    let malformed = validate_initialize_response(
        &json!({
            "jsonrpc": "2.0", "id": 1,
            "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": "yes"}}
        }),
        1,
    );
    assert_eq!(malformed.unwrap_err(), AcpError::CapabilityInvalid);
}

#[test]
fn response_envelope_rejects_wrong_jsonrpc_id_and_mixed_outcomes() {
    let wrong_version = validate_initialize_response(
        &json!({"jsonrpc": "1.0", "id": 1, "result": {"protocolVersion": 1}}),
        1,
    );
    assert_eq!(wrong_version.unwrap_err(), AcpError::JsonRpcVersionInvalid);
    let wrong_id = validate_initialize_response(
        &json!({"jsonrpc": "2.0", "id": 2, "result": {"protocolVersion": 1}}),
        1,
    );
    assert_eq!(wrong_id.unwrap_err(), AcpError::ResponseIdMismatch);
    let mixed = validate_initialize_response(
        &json!({
            "jsonrpc": "2.0", "id": 1,
            "result": {"protocolVersion": 1},
            "error": {"code": -32600, "message": "invalid"}
        }),
        1,
    );
    assert_eq!(mixed.unwrap_err(), AcpError::ResponseOutcomeInvalid);
}

#[test]
fn session_response_requires_new_id_and_preserves_load_identity() {
    let created = validate_session_response(
        &json!({
            "jsonrpc": "2.0", "id": 2,
            "result": {"sessionId": "session-1", "configOptions": []}
        }),
        2,
        AcpSessionMethod::New,
    )
    .unwrap();
    assert_eq!(created.session_id.as_deref(), Some("session-1"));

    let loaded = validate_session_response(
        &json!({"jsonrpc": "2.0", "id": 2, "result": null}),
        2,
        AcpSessionMethod::Load("session-1"),
    )
    .unwrap();
    assert!(loaded.session_id.is_none());

    let object_load = validate_session_response(
        &json!({"jsonrpc": "2.0", "id": 2, "result": {"sessionId": "other"}}),
        2,
        AcpSessionMethod::Load("session-1"),
    );
    assert_eq!(object_load.unwrap_err(), AcpError::SessionResponseInvalid);
}

#[test]
fn prompt_response_is_strict_and_remote_errors_are_redacted() {
    let response = validate_prompt_response(
        &json!({"jsonrpc": "2.0", "id": 3, "result": {"stopReason": "end_turn"}}),
        3,
    )
    .unwrap();
    assert_eq!(response.stop_reason, AcpStopReason::EndTurn);

    let remote = validate_prompt_response(
        &json!({
            "jsonrpc": "2.0", "id": 3,
            "error": {"code": -32000, "message": "sensitive runtime detail"}
        }),
        3,
    )
    .unwrap_err();
    assert_eq!(remote, AcpError::RemoteError { code: -32000 });
    assert_eq!(remote.to_string(), "acp_remote_error");
}

#[test]
fn close_response_requires_an_empty_result_object() {
    validate_close_session_response(&json!({"jsonrpc": "2.0", "id": 4, "result": {}}), 4).unwrap();
    assert_eq!(
        validate_close_session_response(&json!({"jsonrpc": "2.0", "id": 4, "result": null}), 4,)
            .unwrap_err(),
        AcpError::CloseResponseInvalid
    );
    assert_eq!(
        validate_close_session_response(
            &json!({"jsonrpc": "2.0", "id": 4, "result": {"closed": true}}),
            4,
        )
        .unwrap_err(),
        AcpError::CloseResponseInvalid
    );
}

#[test]
fn session_update_validates_notification_shape_and_session_association() {
    let message = json!({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": "session-1",
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "hello"}
            }
        }
    });
    let update = validate_session_update(&message, Some("session-1")).unwrap();
    assert_eq!(update.kind, AcpSessionUpdateKind::AgentMessageChunk);
    assert_eq!(update.agent_message_text(), Some("hello"));
    assert_eq!(
        validate_session_update(&message, Some("other-session")).unwrap_err(),
        AcpError::SessionMismatch
    );

    let mut unstable = message.clone();
    unstable["params"]["update"]["sessionUpdate"] = json!("plan_update");
    assert_eq!(
        validate_session_update(&unstable, Some("session-1")).unwrap_err(),
        AcpError::SessionUpdateInvalid
    );
    let mut request_shaped = message;
    request_shaped["id"] = json!(1);
    assert_eq!(
        validate_session_update(&request_shaped, Some("session-1")).unwrap_err(),
        AcpError::NotificationEnvelopeInvalid
    );
}
