use serde_json::json;

use super::super::semantic::HistoryMessageKind;
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }

use super::super::structured_privacy::{
    looks_like_raw_structured_payload, sanitize_structured_event_text, structured_event_text,
    structured_metadata_detail, structured_reasoning_detail, structured_reasoning_summary,
    structured_tool_call_detail,
};

#[test]
fn structured_text_redacts_credentials_paths_and_opaque_values() {
    let opaque = "A".repeat(48);
    let private_path = format!("/{}", ["home", "sample-user", "private.txt"].join("/"));
    let text = format!("failed at {private_path} with access_token=private and Bearer {opaque}");
    let sanitized = sanitize_structured_event_text(&text).unwrap();
    assert!(!sanitized.contains(&private_path));
    assert!(!sanitized.contains("private"));
    assert!(!sanitized.contains(&opaque));
    assert!(sanitized.contains("[redacted]"));
    assert!(sanitized.contains("[local path hidden]"));
}

#[test]
fn raw_whole_document_payloads_stay_hidden_but_detail_channels_survive() {
    let sv_value = synthetic_value("value");
    assert!(looks_like_raw_structured_payload(format!(r#"{{"secret":"{}"}}"#, sv_value.clone())));
    assert!(!looks_like_raw_structured_payload(
        format!(r#"command: {{"secret": "{}"}}"#, sv_value.clone())
    ));
    assert_eq!(
        structured_event_text(
            HistoryMessageKind::Reasoning,
            &json!({"thinking": "private reasoning"}),
            "Reasoning details are redacted.",
        ),
        "private reasoning"
    );
    assert_eq!(
        structured_reasoning_summary(&json!({
            "summary": {"type": "summary_text", "text": "Provider summary"},
            "thinking": "private reasoning"
        }))
        .as_deref(),
        Some("Provider summary")
    );
}

#[test]
fn reasoning_detail_returns_only_recorded_thinking_text() {
    assert_eq!(
        structured_reasoning_detail(&json!({"text": "CoT", "summary": "Summary"})).as_deref(),
        Some("CoT")
    );
    assert_eq!(
        structured_reasoning_detail(&json!({"think": "  Claude thinking  "})).as_deref(),
        Some("Claude thinking")
    );
    assert_eq!(
        structured_reasoning_detail(&json!({"summary": "Summary only"})),
        None
    );
}

#[test]
fn tool_call_detail_formats_arguments_and_redacts_secrets() {
    let sv_marker_value = synthetic_value("marker-value");
    let detail = structured_tool_call_detail(&json!({
        "type": "tool_use",
        "name": "Bash",
        "input": {"command": "ls /fixture-root/private", "access_token": sv_marker_value.as_str()}
    }))
    .unwrap();
    assert_eq!(
        detail,
        format!("access_token: {}\ncommand: ls /fixture-root/private", sv_marker_value.clone())
    );
    assert_eq!(
        structured_event_text(
            HistoryMessageKind::ToolCall,
            &json!({
                "type": "tool_use",
                "name": "Bash",
                "input": {"command": "ls /fixture-root/private", "access_token": sv_marker_value.as_str()}
            }),
            "Invocation details are hidden.",
        ),
        "access_token: [redacted]\ncommand: ls [local path hidden]"
    );
    assert_eq!(
        structured_tool_call_detail(&json!({"type": "tool", "tool": "bash", "input": {}})),
        None
    );
}

#[test]
fn metadata_detail_unfolds_json_content_and_keeps_key_values() {
    let sv_fixture_credential_canar = synthetic_value("fixture-credential-canary");
    let detail = structured_metadata_detail(&json!({
        "type": "metadata",
        "content": format!(r#"{{"cwd": "/workspace/project", "access_token": "{}"}}"#, sv_fixture_credential_canar.clone())
    }))
    .unwrap();
    assert_eq!(
        detail,
        format!("access_token: {}\ncwd: /workspace/project", sv_fixture_credential_canar.clone())
    );
    assert_eq!(
        structured_event_text(
            HistoryMessageKind::Metadata,
            &json!({
                "type": "metadata",
                "content": format!(r#"{{"cwd": "/workspace/project", "access_token": "{}"}}"#, sv_fixture_credential_canar.clone())
            }),
            "Sensitive native metadata is hidden.",
        ),
        "access_token: [redacted]\ncwd: [local path hidden]"
    );
    assert_eq!(
        structured_metadata_detail(&json!({
            "type": "token-count",
            "usage": {"input_tokens": 120},
            "model": "test-model"
        }))
        .unwrap(),
        "model: test-model\nusage: {\"input_tokens\":120}"
    );
}
