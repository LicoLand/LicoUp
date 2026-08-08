use super::super::adapter::adapter_for_agent;
use super::super::dispatch::{params_with_workspace, send_message};
use super::super::params::message_param;
use super::super::{MAX_MESSAGE_BYTES, RuntimeAdapter};
use serde_json::json;
use std::path::Path;

#[test]
fn adapter_aliases_resolve_to_canonical_ids() {
    assert_eq!(
        adapter_for_agent("claude").map(RuntimeAdapter::id),
        Some("claude-code")
    );
    assert_eq!(
        adapter_for_agent("github-copilot").map(RuntimeAdapter::id),
        Some("copilot")
    );
    assert_eq!(
        adapter_for_agent("kilocode").map(RuntimeAdapter::id),
        Some("kilo-code")
    );
    assert_eq!(
        adapter_for_agent("cursor-agent").map(RuntimeAdapter::id),
        Some("cursor")
    );
}

#[test]
fn message_body_is_not_normalized() {
    let body = "\n  indented code  \n";
    assert_eq!(
        message_param(&json!({"text": body}), &["text"]),
        Some(body.to_string())
    );
}

#[test]
fn oversized_message_is_rejected_before_runtime_launch() {
    let oversized = "x".repeat(MAX_MESSAGE_BYTES + 1);
    let error = send_message(&json!({
        "agent": "codex",
        "text": oversized,
        "binaryPath": "/runtime/must-not-launch"
    }))
    .unwrap_err();

    assert_eq!(
        error.to_string(),
        "agent message request exceeds the input limit"
    );
}

#[test]
fn configured_command_fallback_has_been_removed() {
    let error = send_message(&json!({
        "agent": "claude-code",
        "text": "private prompt",
        "binary": "/definitely/not/a/claude-binary",
        "command": "/bin/echo",
        "args": ["{prompt}"]
    }))
    .unwrap_err();

    assert_eq!(error.to_string(), "native agent executable is unavailable");
}

/// Every driver reads its working directory from the request, so the resolved
/// workspace has to replace the requested one under both keys.
#[test]
fn a_local_turn_republishes_only_the_resolved_workspace() {
    let resolved = params_with_workspace(
        &json!({
            "agent": "cursor",
            "text": "hello",
            "cwd": "/synthetic/path/user",
            "workingDirectory": "/synthetic/path/user"
        }),
        Path::new("/synthetic/state/agent-workspace"),
    );

    assert_eq!(resolved["cwd"], "/synthetic/state/agent-workspace");
    assert_eq!(
        resolved["workingDirectory"],
        "/synthetic/state/agent-workspace"
    );
    assert_eq!(resolved["text"], "hello");
}

#[test]
fn unknown_runtime_adapter_is_rejected() {
    let error = send_message(&json!({"agent": "unknown", "text": "hello"})).unwrap_err();
    assert!(error.to_string().contains("unsupported runtime adapter"));
}
