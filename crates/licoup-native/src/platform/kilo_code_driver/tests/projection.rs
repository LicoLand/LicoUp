use super::*;

#[test]
fn projection_extracts_direct_and_list_shaped_assistant_parts() {
    let direct = crate::platform::native_agent_parser::adapters::kilo_code::message(
        &json!({"parts": [{"type": "text", "text": "direct"}]}),
    )
    .unwrap();
    assert_eq!(direct.output, "direct");
    let list = crate::platform::native_agent_parser::adapters::kilo_code::message(&json!([
        {"parts": [{"type": "text", "text": "one"}]},
        {"parts": [{"type": "text", "text": "-two"}]}
    ]))
    .unwrap();
    assert_eq!(list.output, "one-two");
}

#[test]
fn projection_keeps_effective_settings_and_bounded_capability_claims() {
    let mut config = test_config("prompt", "native");
    config.model = Some("provider/model".into());
    config.allow_all = Some(true);
    let outcome = project_turn(
        crate::platform::native_agent_parser::adapters::kilo_code::message(
            &json!({"parts": [{"type": "text", "text": "answer"}]}),
        )
        .unwrap(),
        "native".into(),
        "turn".into(),
        &config,
    )
    .unwrap();
    assert_eq!(outcome.output, "answer");
    assert!(matches!(
        outcome.transitions.last(),
        Some(crate::platform::native_agent_parser::Transition::Lifecycle(
            crate::platform::native_agent_parser::LifecycleStage::Completed
        ))
    ));
    assert_eq!(outcome.effective.model.as_deref(), Some("provider/model"));
    assert_eq!(outcome.effective.allow_all, Some(true));
    let capabilities = serve_capabilities();
    assert!(capabilities.load_session && capabilities.resume_session);
    assert!(!capabilities.delete_session);
}
