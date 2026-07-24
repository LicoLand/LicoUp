use crate::platform::codex_app_server::launch::CodexLaunchSpec;
use std::path::Path;

#[test]
fn launch_spec_has_no_prompt_channel_and_uses_official_stdio() {
    let prompt = "must-not-appear-in-process-metadata";
    let launch = CodexLaunchSpec::new("codex-test", Some(Path::new("/workspace/project")));
    assert_eq!(launch.executable, "codex-test");
    assert_eq!(launch.args, ["app-server", "--stdio"]);
    assert!(!launch.executable.contains(prompt));
    assert!(
        launch
            .args
            .iter()
            .all(|argument| !argument.contains(prompt))
    );
}
