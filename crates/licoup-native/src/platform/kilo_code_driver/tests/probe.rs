use super::*;

#[test]
fn probe_rejects_relative_workspace_before_process_or_http_work() {
    let failure = capability_probe("unused", Path::new("relative"), 10, Some(16), 16).unwrap_err();
    assert_eq!(failure.code, "kilo_code_serve_working_directory_invalid");
}
