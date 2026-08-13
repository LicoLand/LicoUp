use super::*;

#[test]
fn empty_executable_fails_closed_without_session_fallback() {
    let cwd = std::env::current_dir().unwrap();
    let result = execute(
        "",
        &json!({}),
        "private-kilo-prompt",
        "existing-kilo-native",
        Some(&cwd),
        1_000,
        Some(1024),
        1024,
    );
    assert!(!result.ok);
    assert_eq!(result.driver_id, "kilo-code-serve");
    assert_eq!(result.runtime_protocol, RUNTIME_PROTOCOL);
    assert_eq!(
        result.error.as_ref().map(|failure| failure.code.as_str()),
        Some("kilo_code_serve_process_start_failed")
    );
}
