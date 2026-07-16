use super::*;

#[test]
fn setting_application_requires_the_requested_value() {
    let change = ConfigChange {
        id: "model".to_string(),
        value: ConfigValue::Select("provider/model".to_string()),
    };
    assert!(setting_applied(
        &[json!({
            "id": "model",
            "currentValue": "provider/model"
        })],
        &change
    ));
    assert!(!setting_applied(
        &[json!({
            "id": "model",
            "currentValue": "different"
        })],
        &change
    ));
}

#[test]
fn unsupported_requested_setting_fails_before_prompt_dispatch() {
    let config = ProtocolConfig::from_params(
        &json!({"model": "provider/model"}),
        "prompt",
        "native",
        Some(absolute_test_cwd().as_path()),
    )
    .unwrap();
    let failure = requested_config_changes(&config.settings, &[], Some("native")).unwrap_err();
    assert_eq!(failure.code, "acp_setting_unsupported");
    assert_eq!(failure.session_id.as_deref(), Some("native"));
}
