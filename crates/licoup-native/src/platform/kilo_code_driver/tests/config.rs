use super::*;

#[test]
fn configuration_requires_an_absolute_workspace() {
    let failure =
        ServeTurnConfig::from_params(&json!({}), "prompt", "native", Some(Path::new("relative")))
            .unwrap_err();
    assert_eq!(failure.code, "acp_working_directory_invalid");
}

#[test]
fn configuration_projects_only_explicit_turn_settings() {
    let cwd = std::env::current_dir().unwrap();
    let config = ServeTurnConfig::from_params(
        &json!({
            "model": "provider/model",
            "runtimeAgent": "reviewer",
            "reasoningEffort": "high",
            "mode": "plan",
            "allowAll": true
        }),
        "prompt",
        " native ",
        Some(&cwd),
    )
    .unwrap();
    assert_eq!(config.requested_session_id, "native");
    assert_eq!(config.model.as_deref(), Some("provider/model"));
    assert_eq!(config.runtime_agent.as_deref(), Some("reviewer"));
    assert_eq!(config.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(config.mode.as_deref(), Some("plan"));
    assert_eq!(config.allow_all, Some(true));
}
