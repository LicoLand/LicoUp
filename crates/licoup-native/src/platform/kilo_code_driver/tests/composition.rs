use super::*;

#[test]
fn facade_owns_only_the_fixed_kilo_serve_contract() {
    assert_eq!(RUNTIME_PROTOCOL, "kilo-code-serve-http-v1");
    assert_eq!(KILO_CODE_DRIVER.launch_args, &["serve"]);
    assert_eq!(KILO_CODE_DRIVER.agent_id, "kilo-code-serve");
    assert_eq!(KILO_CODE_DRIVER.error_prefix, "kilo_code_serve");
    assert!(KILO_CODE_DRIVER.launch_args.iter().all(|argument| {
        *argument != "acp"
            && !argument.contains("continue")
            && !argument.contains("session")
            && !argument.contains("prompt")
    }));
}
