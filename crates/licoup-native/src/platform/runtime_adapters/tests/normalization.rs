use super::super::model::{NormalizedEffectiveSettings, NormalizedExecution};
use super::super::normalization::{execution_response, normalize_codex};
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
