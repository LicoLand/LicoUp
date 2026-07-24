use super::*;

#[test]
fn empty_prompt_fails_closed() {
    let failure =
        ProtocolConfig::from_params(&json!({}), "   ", "", Some(absolute_test_cwd().as_path()))
            .unwrap_err();
    assert_eq!(failure.code, "pi_empty_prompt");
}

#[test]
fn unsupported_turn_overrides_and_invalid_thinking_fail_before_launch() {
    for (params, expected) in [
        (
            json!({"sandbox": "workspace"}),
            "pi_sandbox_override_unsupported",
        ),
        (
            json!({"approvalPolicy": "never"}),
            "pi_approval_override_unsupported",
        ),
        (
            json!({"thinking": "unbounded"}),
            "pi_invalid_thinking_level",
        ),
    ] {
        let failure =
            ProtocolConfig::from_params(&params, "hello", "", Some(absolute_test_cwd().as_path()))
                .unwrap_err();
        assert_eq!(failure.code, expected);
    }
}

#[test]
fn relative_cwd_fails_closed() {
    let failure = ProtocolConfig::from_params(&json!({}), "hello", "", Some(Path::new("relative")))
        .unwrap_err();
    assert_eq!(failure.code, "pi_absolute_cwd_required");
}
