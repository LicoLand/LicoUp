use serde_json::json;

use super::super::semantic::HistoryMessageKind;
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }

use super::super::structured_privacy::{
    looks_like_raw_structured_payload, sanitize_structured_event_text, structured_event_text,
    structured_reasoning_summary,
};

#[test]
fn structured_text_redacts_credentials_paths_and_opaque_values() {
    let opaque = "A".repeat(48);
    let private_path = ["/", "home", "sample-user", "private.txt"].join("/");
    let text = format!("failed at {private_path} with access_token=private and Bearer {opaque}");
    let sanitized = sanitize_structured_event_text(&text).unwrap();
    assert!(!sanitized.contains(&private_path));
    assert!(!sanitized.contains("private"));
    assert!(!sanitized.contains(&opaque));
    assert!(sanitized.contains("[redacted]"));
    assert!(sanitized.contains("[local path hidden]"));
}

#[test]
fn raw_payloads_and_chain_of_thought_stay_hidden_but_provider_summary_survives() {
    let sv_value = synthetic_value("value");
    assert!(looks_like_raw_structured_payload(format!(r#"{{"secret":"{}"}}"#, sv_value.clone())));
    assert_eq!(
        structured_event_text(
            HistoryMessageKind::Reasoning,
            &json!({"thinking": "private reasoning"}),
            "Reasoning details are redacted.",
        ),
        "Reasoning details are redacted."
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
