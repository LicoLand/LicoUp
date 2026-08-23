use super::*;

#[test]
fn wrapper_namespaces_structured_failures_without_exposing_private_values() {
    let result = execute(
        "unused",
        &json!({}),
        "private-prompt",
        "private-session",
        Some(Path::new("relative")),
        10,
        Some(10),
        10,
    );
    assert_eq!(result.driver_id, "opencode-serve");
    let failure = result.error.unwrap();
    assert_eq!(failure.code, "opencode_serve_working_directory_invalid");
    assert!(!failure.message.contains("private"));
}

#[test]
fn serve_message_body_keeps_prompt_and_exact_settings_in_http_json() {
    let config = ProtocolConfig::from_params(
        &json!({"model": "provider/model", "runtimeAgent": "reviewer"}),
        "private prompt",
        "",
        Some(absolute_test_cwd().as_path()),
    )
    .unwrap();
    let body = build_serve_message_body(&config);
    assert_eq!(body["parts"][0]["text"], "private prompt");
    assert_eq!(body["model"]["providerID"], "provider");
    assert_eq!(body["model"]["modelID"], "model");
    assert_eq!(body["agent"], "reviewer");
}

#[test]
fn workspace_routing_uses_the_query_and_keeps_session_creation_body_clean() {
    let url = workspace_request_url(
        "http://127.0.0.1:24173",
        &["session", "session/with space", "message"],
        "/workspace/with space",
    )
    .unwrap();
    let parsed = url::Url::parse(&url).unwrap();
    assert_eq!(parsed.path(), "/session/session%2Fwith%20space/message");
    assert_eq!(
        parsed.query_pairs().collect::<Vec<_>>(),
        vec![("directory".into(), "/workspace/with space".into())]
    );
    assert_eq!(build_session_create_body(), json!({}));
}

#[test]
fn serve_http_failures_keep_actionable_status_classes() {
    let authentication = request_failure(HttpFailure::Status(401), "session/new", None);
    assert_eq!(
        authentication.code,
        "opencode_serve_authentication_required"
    );
    assert!(authentication.user_interaction_required);
    assert_eq!(
        request_failure(HttpFailure::Status(422), "session/new", None).code,
        "opencode_serve_request_rejected"
    );
    assert_eq!(
        request_failure(HttpFailure::Status(429), "session/prompt", None).code,
        "opencode_serve_rate_limited"
    );
}

#[test]
fn serve_request_fails_before_network_io_after_the_turn_deadline() {
    let failure = wait_post_json(
        "http://invalid.test/session/native/message",
        &json!({}),
        Some(Instant::now()),
    )
    .unwrap_err();
    assert_eq!(failure.code, "acp_protocol_timeout");
    assert_eq!(failure.stage, "session/prompt");
}

#[test]
fn serve_request_timeout_uses_the_remaining_turn_budget_and_zero_has_no_deadline() {
    assert_eq!(remaining_turn_timeout(None).unwrap(), None);
    let remaining = remaining_turn_timeout(Some(Instant::now() + Duration::from_secs(2)))
        .unwrap()
        .unwrap();
    assert!(remaining > Duration::from_secs(1));
    assert!(remaining <= Duration::from_secs(2));
}
