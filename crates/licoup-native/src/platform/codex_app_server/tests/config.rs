use super::support::config;
use crate::platform::codex_app_server::config::{ProtocolConfig, spark_default_reasoning_effort};
use serde_json::json;

#[test]
fn invalid_resume_path_fails_closed_without_echoing_the_path() {
    let failure = ProtocolConfig::from_params(
        &json!({"sessionPath": "/sessions/not-a-thread.jsonl"}),
        "prompt",
        "",
        None,
    )
    .unwrap_err();
    assert_eq!(failure.code, "codex_invalid_resume_target");
    assert_eq!(failure.stage, "thread/resume");
    assert!(!failure.message.contains("sessions"));
}

#[test]
fn unsupported_sandbox_shape_fails_closed() {
    let failure = ProtocolConfig::from_params(
        &json!({"sandbox": {"type": "workspaceWrite"}}),
        "prompt",
        "",
        None,
    )
    .unwrap_err();
    assert_eq!(failure.code, "codex_invalid_sandbox");
    assert_eq!(failure.stage, "thread/configure");
}

#[test]
fn spark_defaults_to_supported_low_effort_only_when_unspecified() {
    assert_eq!(
        spark_default_reasoning_effort(Some("gpt-spark")),
        Some("low".to_string())
    );
    assert_eq!(spark_default_reasoning_effort(Some("gpt-standard")), None);
    assert_eq!(
        config(
            json!({"model": "gpt-spark", "reasoningEffort": "high"}),
            "p",
            ""
        )
        .reasoning_effort
        .as_deref(),
        Some("high")
    );
}
