use super::*;

#[test]
fn private_prompt_uses_stdin_and_session_identity_is_implicit() {
    let config = config(
        json!({"reasoningEffort": "xhigh", "permissionMode": "on-request"}),
        "private prompt",
        "private-session",
    );
    assert_eq!(config.permission_mode.as_deref(), Some("default"));
    let input = config.stdin_message().unwrap();
    assert_eq!(
        input
            .pointer("/message/content/0/text")
            .and_then(Value::as_str),
        Some("private prompt")
    );
    assert!(!input.to_string().contains("private-session"));
}

#[test]
fn invalid_native_settings_fail_before_process_selection() {
    assert_eq!(
        DriverConfig::from_params(
            &json!({"reasoningEffort": "unsupported"}),
            "hello",
            "",
            None,
        )
        .unwrap_err()
        .code,
        "claude_code_invalid_effort"
    );
    assert_eq!(
        DriverConfig::from_params(&json!({"permissionMode": "unsupported"}), "hello", "", None,)
            .unwrap_err()
            .code,
        "claude_code_invalid_permission_mode"
    );
}

#[test]
fn private_instructions_stay_separate_from_the_exact_prompt() {
    let config = DriverConfig::from_params(
        &json!({"privateInstructions": "synthetic private instruction"}),
        "exact user prompt",
        "",
        None,
    )
    .unwrap();
    assert_eq!(config.prompt, "exact user prompt");
    assert_eq!(
        config.private_instructions.as_deref(),
        Some("synthetic private instruction")
    );
    assert_eq!(
        config.stdin_message().unwrap()["message"]["content"][0]["text"],
        "exact user prompt"
    );
}
