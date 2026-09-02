use super::*;

#[test]
fn probe_rejects_relative_workspace_before_process_or_http_work() {
    let failure = capability_probe("unused", Path::new("relative"), 10, Some(16), 16).unwrap_err();
    assert_eq!(failure.code, "kilo_code_serve_working_directory_invalid");
}

#[test]
fn endpoint_failures_preserve_the_local_service_diagnostic() {
    for (source, expected) in [
        ("kilo_executable_missing", "kilo_executable_missing"),
        (
            "kilo_code_serve_port_exhausted",
            "kilo_code_serve_port_exhausted",
        ),
        (
            "kilo_code_serve_start_failed",
            "kilo_code_serve_start_failed",
        ),
        (
            "kilo_code_serve_health_failed",
            "kilo_code_serve_health_failed",
        ),
        (
            "kilo_code_serve_attach_probe_failed",
            "kilo_code_serve_attach_probe_failed",
        ),
        (
            "kilo_code_serve_state_invalid",
            "kilo_code_serve_state_invalid",
        ),
    ] {
        assert_eq!(endpoint_failure(source).code, expected);
    }
}
