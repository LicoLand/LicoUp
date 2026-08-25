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

#[test]
fn omitted_permission_mode_defers_to_the_launch_default() {
    // An omitted mode is not an explicit selection at the config level: the
    // LaunchIdentity launch default (bypassPermissions, the vendor YOLO mode)
    // resolves it before argv and effective settings are projected, which
    // keeps process continuation compatible while a fresh or resumed launch
    // still starts in YOLO.
    let fresh = config(json!({}), "hello", "");
    assert_eq!(fresh.permission_mode.as_deref(), None);
    let resumed = config(json!({}), "hello", "native-session");
    assert_eq!(resumed.permission_mode.as_deref(), None);
}

#[test]
fn explicit_permission_modes_override_the_yolo_default() {
    let cases = [
        (json!({"permissionMode": "plan"}), "plan"),
        (json!({"permissionMode": "default"}), "default"),
        (json!({"permissionMode": "manual"}), "manual"),
        (json!({"permissionMode": "acceptEdits"}), "acceptEdits"),
        (json!({"permissionMode": "auto"}), "auto"),
        (json!({"permissionMode": "dontAsk"}), "dontAsk"),
        (
            json!({"permissionMode": "bypassPermissions"}),
            "bypassPermissions",
        ),
        (json!({"permissionMode": "on-request"}), "default"),
        (json!({"permissionMode": "never"}), "dontAsk"),
        (json!({"permission_mode": "never"}), "dontAsk"),
        (json!({"approvalPolicy": "on-request"}), "default"),
        (json!({"approval_policy": "never"}), "dontAsk"),
    ];
    for (params, expected) in cases {
        let config = config(params, "hello", "");
        assert_eq!(
            config.permission_mode.as_deref(),
            Some(expected),
            "explicit {expected} must stay authoritative"
        );
    }
}
