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
    assert!(matches!(
        result.transitions.last(),
        Some(crate::platform::native_agent_parser::Transition::Failed { code, .. })
            if code == "opencode_serve_working_directory_invalid"
    ));
}

#[test]
fn serve_message_capture_keeps_private_guidance_separate_and_non_durable() {
    let config = ProtocolConfig::from_params(
        &json!({"model": "provider/model", "runtimeAgent": "reviewer"}),
        "private prompt",
        "",
        Some(absolute_test_cwd().as_path()),
    )
    .unwrap();
    let body = build_serve_message_body(&config, Some("private system guidance"));
    assert_eq!(body["parts"][0]["text"], "private prompt");
    assert_eq!(body["system"], "private system guidance");
    assert!(
        !body["parts"][0]["text"]
            .as_str()
            .unwrap()
            .contains("private system guidance")
    );
    assert_eq!(body["model"]["providerID"], "provider");
    assert_eq!(body["model"]["modelID"], "model");
    assert_eq!(body["agent"], "reviewer");
    let returned = crate::platform::native_agent_parser::adapters::opencode::message(&json!({
        "parts": [{"type": "text", "text": "answer"}]
    }))
    .unwrap();
    assert_eq!(returned.output, "answer");
    assert!(!returned.transitions.iter().any(|transition| matches!(
        transition,
        crate::platform::native_agent_parser::Transition::Text { text, .. }
            if text.contains("private system guidance")
    )));
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
fn serve_start_health_and_attach_failures_keep_stable_stages() {
    for (source, code, stage) in [
        (
            "opencode_executable_missing",
            "opencode_serve_executable_missing",
            "serve/start",
        ),
        (
            "opencode_serve_port_exhausted",
            "opencode_serve_port_exhausted",
            "serve/start",
        ),
        (
            "opencode_serve_start_failed",
            "opencode_serve_start_failed",
            "serve/start",
        ),
        (
            "opencode_serve_health_failed",
            "opencode_serve_health_failed",
            "serve/health",
        ),
        (
            "opencode_serve_attach_probe_failed",
            "opencode_serve_attach_probe_failed",
            "serve/attach",
        ),
    ] {
        let failure = endpoint_failure(source);
        assert_eq!(failure.code, code);
        assert_eq!(failure.stage, stage);
    }
}

#[test]
fn serve_first_failure_is_write_once_across_http_sse_deadline_and_cleanup() {
    let first = FirstFailure::default();
    let session = request_failure(HttpFailure::NotFound, "session/load", Some("s"));
    first.record(session.clone());
    first.record(request_failure(
        HttpFailure::Status(500),
        "session/prompt",
        Some("s"),
    ));
    first.record(request_failure(
        HttpFailure::Status(500),
        "turn/control",
        Some("s"),
    ));
    first.record(sse_failure(
        crate::platform::opencode_serve::EventStreamFailure::Framing(
            crate::platform::local_service::sse::SseFailure::FrameTooLarge,
        ),
        "s",
    ));
    first.record(turn_timeout_failure());
    first.record(ProtocolFailure::new(
        "opencode_serve_cleanup_failed",
        "cleanup",
        "serve/cleanup",
    ));
    // A disconnected observer arriving after a terminal failure cannot replace it.
    first.record(sse_failure(
        crate::platform::opencode_serve::EventStreamFailure::Closed,
        "s",
    ));
    let retained = first.get().unwrap();
    assert_eq!(retained.code, session.code);
    assert_eq!(retained.stage, "session/load");
}

#[test]
fn serve_http_deadline_and_cleanup_phase_codes_are_stable() {
    let session = request_failure(HttpFailure::NotFound, "session/load", Some("s"));
    assert_eq!(
        (session.code.as_str(), session.stage),
        ("opencode_serve_not_found", "session/load")
    );
    let message = request_failure(HttpFailure::Status(500), "session/prompt", Some("s"));
    assert_eq!(
        (message.code.as_str(), message.stage),
        ("opencode_serve_message_failed", "session/prompt")
    );
    let control = request_failure(HttpFailure::Status(500), "turn/control", Some("s"));
    assert_eq!(
        (control.code.as_str(), control.stage),
        ("opencode_serve_control_failed", "turn/control")
    );
    let health = request_failure(HttpFailure::Unavailable, "serve/health", None);
    assert_eq!(
        (health.code.as_str(), health.stage),
        ("opencode_serve_health_failed", "serve/health")
    );
    let deadline = turn_timeout_failure();
    assert_eq!(
        (deadline.code.as_str(), deadline.stage),
        ("opencode_serve_deadline_exceeded", "turn/deadline")
    );
    let cleanup = ProtocolFailure::new("opencode_serve_cleanup_failed", "cleanup", "serve/cleanup");
    assert_eq!(
        (cleanup.code.as_str(), cleanup.stage),
        ("opencode_serve_cleanup_failed", "serve/cleanup")
    );
}

#[test]
fn serve_sse_framing_and_closure_have_distinct_stable_codes() {
    let framing = sse_failure(
        crate::platform::opencode_serve::EventStreamFailure::Framing(
            crate::platform::local_service::sse::SseFailure::LineTooLarge,
        ),
        "s",
    );
    assert_eq!(framing.code, "opencode_serve_sse_line_too_large");
    assert_eq!(framing.stage, "serve/sse");
    let closed = sse_failure(
        crate::platform::opencode_serve::EventStreamFailure::Closed,
        "s",
    );
    assert_eq!(closed.code, "opencode_serve_sse_closed");
    assert_eq!(closed.stage, "serve/sse");
}

#[test]
fn terminal_completion_rejects_a_later_observer_disconnect() {
    let first = FirstFailure::default();
    let completed = AtomicBool::new(true);
    record_preterminal_failure(
        &first,
        &completed,
        sse_failure(
            crate::platform::opencode_serve::EventStreamFailure::Closed,
            "s",
        ),
    );
    assert!(first.get().is_none());
}

#[test]
fn serve_request_fails_before_network_io_after_the_turn_deadline() {
    let failure = wait_post_json(
        "http://invalid.test/session/native/message",
        &json!({}),
        Some(Instant::now()),
    )
    .unwrap_err();
    assert_eq!(failure.code, "opencode_serve_deadline_exceeded");
    assert_eq!(failure.stage, "turn/deadline");
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
