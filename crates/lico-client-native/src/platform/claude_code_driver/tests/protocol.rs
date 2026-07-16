use super::*;

#[test]
fn turn_state_binds_exact_session_and_finishes_from_terminal_result() {
    let config = config(json!({"model": "fake-model"}), "hello", "native-session");
    let identity = LaunchIdentity::new("claude", &config, Some(&absolute_test_cwd()));
    let mut state = TurnState::new(&config, &identity, Some("native-session".to_string()));
    assert!(
        state
            .handle(json!({
                "type": "system",
                "subtype": "init",
                "session_id": "native-session",
                "model": "effective-model",
                "permissionMode": "plan"
            }))
            .unwrap()
            .is_none()
    );
    assert!(
        state
            .handle(json!({
                "type": "stream_event",
                "session_id": "native-session",
                "event": {"delta": {"text": "chunk"}}
            }))
            .unwrap()
            .is_none()
    );
    let outcome = state
        .handle(json!({
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": "final answer",
            "session_id": "native-session",
            "permission_denials": []
        }))
        .unwrap()
        .unwrap();
    assert_eq!(outcome.output, "final answer");
    assert_eq!(outcome.session_id, "native-session");
    assert_eq!(outcome.effective.model.as_deref(), Some("effective-model"));
}

#[test]
fn cross_session_output_and_deferred_tools_fail_closed() {
    let config = config(json!({}), "hello", "native-session");
    let identity = LaunchIdentity::new("claude", &config, None);
    let mut state = TurnState::new(&config, &identity, Some("native-session".to_string()));
    assert_eq!(
        state
            .handle(json!({"type": "system", "session_id": "other-session"}))
            .unwrap_err()
            .code,
        "claude_code_session_mismatch"
    );

    let mut state = TurnState::new(&config, &identity, Some("native-session".to_string()));
    let failure = state
        .handle(json!({
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": "not accepted",
            "session_id": "native-session",
            "terminal_reason": "tool_deferred"
        }))
        .unwrap_err();
    assert_eq!(failure.code, "claude_code_user_interaction_required");
    assert!(failure.user_interaction_required);
}
