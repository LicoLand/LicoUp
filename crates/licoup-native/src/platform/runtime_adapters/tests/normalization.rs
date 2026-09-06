use super::super::model::{NormalizedEffectiveSettings, NormalizedExecution};
use super::super::normalization::{execution_response, normalize_codex, normalize_cursor};
use super::super::{RUNTIME_SCHEMA_VERSION, RuntimeAdapter};
use crate::platform::{codex_app_server, opencode_driver};
use serde_json::json;

#[test]
fn codex_response_uses_the_canonical_shape() {
    let response = execution_response(
        RuntimeAdapter::Codex,
        normalize_codex(codex_app_server::RunResult {
            ok: true,
            output: "answer".to_string(),
            transitions:
                crate::platform::native_agent_parser::adapters::codex::completed_transitions(
                    "answer",
                ),
            error: None,
            session_id: "session-1".to_string(),
            thread_id: "thread-1".to_string(),
            turn_id: "turn-1".to_string(),
            turn_status: "completed".to_string(),
            effective: codex_app_server::EffectiveSettings {
                cwd: Some("/workspace/project".to_string()),
                model: Some("model-1".to_string()),
                reasoning_effort: Some("high".to_string()),
                sandbox: Some(json!({"type": "workspaceWrite"})),
                approval_policy: Some(json!("on-request")),
            },
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at: "1".to_string(),
        }),
    );

    assert_eq!(response["schemaVersion"], RUNTIME_SCHEMA_VERSION);
    assert_eq!(response["driverId"], "codex-app-server");
    assert_eq!(
        response["runtimeProtocol"],
        codex_app_server::RUNTIME_PROTOCOL
    );
    assert_eq!(response["threadId"], "thread-1");
    assert_eq!(response["nativeSessionId"], "thread-1");
    assert_eq!(response["sessionId"], "thread-1");
    assert_eq!(response["effective"]["model"], "model-1");
    assert_eq!(response["approvalOwner"], "user");
}

#[test]
fn codex_usage_limit_response_preserves_safe_resolution_contract() {
    let failure = codex_app_server::model::ProtocolFailure::new(
        "codex_usage_limit_exceeded",
        "Codex usage limit exceeded.",
        "turn/completed",
    )
    .with_resolution(
        "native_cli",
        false,
        "select_available_model_or_wait_for_quota_reset",
    );
    let response = execution_response(
        RuntimeAdapter::Codex,
        normalize_codex(codex_app_server::RunResult {
            ok: false,
            output: String::new(),
            transitions: Vec::new(),
            error: Some(failure),
            session_id: String::new(),
            thread_id: String::new(),
            turn_id: String::new(),
            turn_status: "failed/UsageLimitExceeded".to_string(),
            effective: codex_app_server::EffectiveSettings::default(),
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at: "1".to_string(),
        }),
    );

    assert_eq!(response["error"]["code"], "codex_usage_limit_exceeded");
    assert_eq!(response["error"]["component"], "native_cli");
    assert_eq!(response["error"]["retryable"], false);
    assert_eq!(
        response["error"]["recovery"],
        "select_available_model_or_wait_for_quota_reset"
    );
    // The driver-provided exact recovery wins; the funnel still attaches the
    // bounded root-cause class.
    assert_eq!(response["error"]["rootCause"], "quota");
    assert_eq!(response["error"]["message"], "Codex usage limit exceeded.");
}

#[test]
fn spawn_failure_response_carries_env_mismatch_root_cause_and_recovery() {
    let failure = codex_app_server::model::ProtocolFailure::new(
        "codex_app_server_start_failed",
        "The Codex executable is not available.",
        "process/start",
    );
    let response = execution_response(
        RuntimeAdapter::Codex,
        normalize_codex(codex_app_server::RunResult {
            ok: false,
            output: String::new(),
            transitions: Vec::new(),
            error: Some(failure),
            session_id: String::new(),
            thread_id: String::new(),
            turn_id: String::new(),
            turn_status: "failed".to_string(),
            effective: codex_app_server::EffectiveSettings::default(),
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at: "1".to_string(),
        }),
    );

    assert_eq!(response["error"]["code"], "codex_app_server_start_failed");
    assert_eq!(response["error"]["rootCause"], "env_mismatch");
    assert_eq!(
        response["error"]["recovery"],
        "subagent_env_mismatch: LicoUp-launched CLI environment differs from user terminal"
    );
}

#[test]
fn unmatched_failure_response_carries_unknown_root_cause_with_review_hint() {
    let failure = codex_app_server::model::ProtocolFailure::new(
        "codex_final_message_missing",
        "Codex completed the turn without a final agent message.",
        "turn/completed",
    );
    let response = execution_response(
        RuntimeAdapter::Codex,
        normalize_codex(codex_app_server::RunResult {
            ok: false,
            output: String::new(),
            transitions: Vec::new(),
            error: Some(failure),
            session_id: String::new(),
            thread_id: String::new(),
            turn_id: String::new(),
            turn_status: "failed".to_string(),
            effective: codex_app_server::EffectiveSettings::default(),
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at: "1".to_string(),
        }),
    );

    assert_eq!(response["error"]["rootCause"], "unknown");
    assert_eq!(response["error"]["recovery"], "review_terminal_result");
}

#[test]
fn cursor_usage_limit_response_preserves_safe_resolution_contract() {
    let failure = crate::platform::cursor_driver::errors::CursorFailureKind::UsageLimitExceeded
        .failure(Some("synthetic-session"));
    let response = execution_response(
        RuntimeAdapter::Cursor,
        normalize_cursor(crate::platform::cursor_driver::RunResult {
            ok: false,
            output: String::new(),
            transitions: Vec::new(),
            error: Some(failure),
            session_id: "synthetic-session".to_owned(),
            thread_id: "synthetic-session".to_owned(),
            turn_id: String::new(),
            turn_status: "usage_limit_exceeded".to_owned(),
            effective: crate::platform::cursor_driver::model::EffectiveSettings::default(),
            status_code: Some(1),
            stdout_truncated: false,
            stderr_truncated: false,
            started_at: "1".to_owned(),
        }),
    );

    assert_eq!(response["error"]["code"], "cursor_cli_usage_limit_exceeded");
    assert_eq!(response["error"]["component"], "native_cli");
    assert_eq!(response["error"]["retryable"], false);
    assert_eq!(
        response["error"]["recovery"],
        "select_available_model_or_wait_for_quota_reset"
    );
    assert_eq!(response["error"]["turnStatus"], "usage_limit_exceeded");
}

#[test]
fn non_codex_response_uses_session_id_as_native_continuity_id() {
    let response = execution_response(
        RuntimeAdapter::OpenCode,
        NormalizedExecution {
            ok: true,
            output: "answer".to_string(),
            transitions:
                crate::platform::native_agent_parser::adapters::opencode::completed_transitions(
                    "answer",
                ),
            capabilities: json!({}),
            error: None,
            session_id: "native-session-1".to_string(),
            thread_id: "diagnostic-thread-1".to_string(),
            turn_id: "turn-1".to_string(),
            turn_status: "completed".to_string(),
            effective: NormalizedEffectiveSettings::default(),
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at: "1".to_string(),
            runtime_protocol: opencode_driver::RUNTIME_PROTOCOL,
            driver_id: "opencode-serve",
        },
    );

    assert_eq!(response["nativeSessionId"], "native-session-1");
    assert_eq!(response["driverId"], "opencode-serve");
    assert_eq!(response["sessionId"], "native-session-1");
    assert_eq!(response["threadId"], "diagnostic-thread-1");
}

#[test]
fn failed_outcome_does_not_echo_requested_identity_or_unverified_settings() {
    let response = execution_response(
        RuntimeAdapter::Pi,
        NormalizedExecution {
            ok: false,
            output: String::new(),
            transitions: Vec::new(),
            capabilities: json!({}),
            error: None,
            session_id: "caller-requested-session".to_string(),
            thread_id: "caller-requested-session".to_string(),
            turn_id: String::new(),
            turn_status: "failed".to_string(),
            effective: NormalizedEffectiveSettings {
                model: Some("unverified-model".to_string()),
                ..NormalizedEffectiveSettings::default()
            },
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at: "1".to_string(),
            runtime_protocol: crate::platform::pi_driver::RUNTIME_PROTOCOL,
            driver_id: "pi-rpc",
        },
    );

    assert!(response["nativeSessionId"].is_null());
    assert!(response["sessionId"].is_null());
    assert!(response["effective"]["model"].is_null());
}
