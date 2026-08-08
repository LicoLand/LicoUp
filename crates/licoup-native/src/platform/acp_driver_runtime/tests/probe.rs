use super::*;

#[test]
fn acp_probe_rejects_relative_working_directory_before_launch() {
    let driver = AcpDriverSpec::new("test-acp", &["acp"]);
    let failure = probe_acp(driver, "unused", Path::new("relative"), 10, Some(16), 16).unwrap_err();
    assert_eq!(failure.code, "acp_working_directory_invalid");
}
