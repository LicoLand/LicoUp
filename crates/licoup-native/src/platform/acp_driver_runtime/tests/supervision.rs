use super::*;

#[test]
fn launch_arguments_are_fixed_and_do_not_contain_prompt_or_path() {
    let cwd = absolute_test_cwd();
    let driver = AcpDriverSpec::new("test-acp", &["acp"]);
    let launch = LaunchSpec::new("test-agent", driver, &cwd);
    assert_eq!(launch.driver.launch_args, &["acp"]);
    assert!(
        !launch
            .driver
            .launch_args
            .iter()
            .any(|arg| *arg == "private")
    );
    assert!(
        !launch
            .driver
            .launch_args
            .iter()
            .any(|arg| *arg == cwd.to_string_lossy())
    );
    assert!(
        !launch
            .driver
            .launch_args
            .iter()
            .any(|arg| *arg == "native-session" || *arg == "provider/model")
    );
}
