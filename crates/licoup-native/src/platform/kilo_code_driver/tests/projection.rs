use super::*;

#[test]
fn projection_extracts_direct_and_list_shaped_assistant_parts() {
    assert_eq!(
        extract_assistant_text(&json!({"parts": [{"type": "text", "text": "direct"}]})),
        "direct"
    );
    assert_eq!(
        extract_assistant_text(&json!([
            {"parts": [{"type": "text", "text": "one"}]},
            {"parts": [{"type": "text", "text": "-two"}]}
        ])),
        "one-two"
    );
}

#[test]
fn projection_keeps_effective_settings_and_bounded_capability_claims() {
    let mut config = test_config("prompt", "native");
    config.model = Some("provider/model".into());
    config.allow_all = Some(true);
    let outcome = project_turn(
        &json!({"parts": [{"type": "text", "text": "answer"}]}),
        Vec::new(),
        "native".into(),
        "turn".into(),
        &config,
    )
    .unwrap();
    assert_eq!(outcome.output, "answer");
    assert_eq!(outcome.events.len(), 1);
    assert_eq!(outcome.effective.model.as_deref(), Some("provider/model"));
    assert_eq!(outcome.effective.allow_all, Some(true));
    let capabilities = serve_capabilities();
    assert!(capabilities.load_session && capabilities.resume_session);
    assert!(!capabilities.delete_session);
}
