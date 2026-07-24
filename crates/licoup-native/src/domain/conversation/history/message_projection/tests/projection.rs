use std::path::Path;

use serde_json::json;

use super::super::projection::{
    clean_native_message_text, plain_history_message, structured_history_message,
};
use super::super::semantic::HistoryMessageKind;
use crate::domain::conversation::source_catalog::HistoryAdapter;

#[test]
fn plain_projection_keeps_thread_semantics_and_filters_generated_context() {
    let message = plain_history_message(
        HistoryAdapter::Codex,
        Path::new("fixture/session.jsonl"),
        1,
        0,
        "user",
        "<environment_context>hidden</environment_context>Visible prompt",
        Some("2026-01-01T00:00:00Z".to_string()),
    )
    .unwrap();
    assert_eq!(message["text"], "Visible prompt");
    assert_eq!(message["layer"], "thread");
    assert!(
        clean_native_message_text(
            HistoryAdapter::Codex,
            "system",
            "<local-command-output>hidden</local-command-output>"
        )
        .is_none()
    );
}

#[test]
fn structured_projection_preserves_execution_card_without_sensitive_detail() {
    let private_path = ["/", "Users", "sample-user", "private.txt"].join("/");
    let message = structured_history_message(
        HistoryAdapter::ClaudeCode,
        Path::new("fixture/session.jsonl"),
        2,
        0,
        HistoryMessageKind::ToolCall,
        "tool_use",
        &json!({
            "name": "Read",
            "input": {"path": private_path.clone()}
        }),
        Some("2026-01-01T00:00:00Z".to_string()),
    );
    assert_eq!(message["cardTitle"], "Read");
    assert_eq!(message["text"], "Invocation details are hidden.");
    assert_eq!(message["layer"], "execution");
    assert!(!message.to_string().contains(&private_path));
}
