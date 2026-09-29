use crate::platform::codex_app_server::launch::{
    CodexLaunchSpec, apply_launch_environment, apply_launch_environment_with_root,
};
use serde_json::json;
use std::ffi::{OsStr, OsString};
use std::path::Path;
use std::process::Command;

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

fn command_environment(command: &Command, key: &str) -> Option<String> {
    command
        .get_envs()
        .find(|(name, _)| *name == OsStr::new(key))
        .and_then(|(_, value)| value)
        .map(|value| value.to_string_lossy().into_owned())
}

#[test]
fn launch_forwards_caller_context_and_inherits_the_portable_root() {
    let previous_root = licoup_foundation::platform::paths::set_portable_data_dir_override(Some(
        std::path::PathBuf::from("/synthetic/licoup-home"),
    ));
    let mut command = Command::new("codex-test");
    apply_launch_environment(
        &mut command,
        Some(&json!({
            "agentId": "codex",
            "conversationId": "conversation:fixture",
            "membershipId": "membership:codex",
            "dispatchId": "turn:direct"
        })),
    )
    .expect("the selected data root should be available to the child");

    assert_eq!(
        command_environment(&command, "LICOUP_MCP_CALLER_PROVIDER").as_deref(),
        Some("codex")
    );
    assert_eq!(
        command_environment(&command, "LICOUP_MCP_CONVERSATION_ID").as_deref(),
        Some("conversation:fixture")
    );
    assert_eq!(
        command_environment(&command, "LICOUP_MCP_MEMBERSHIP_ID").as_deref(),
        Some("membership:codex")
    );
    assert_eq!(
        command_environment(&command, "LICOUP_HOME").as_deref(),
        Some("/synthetic/licoup-home")
    );
    assert_eq!(
        command_environment(&command, "LICOUP_MCP_PARENT_DISPATCH_ID"),
        None
    );
    licoup_foundation::platform::paths::set_portable_data_dir_override(previous_root);
}

#[test]
fn launch_binds_only_the_live_process_portable_root() {
    let _snapshot =
        crate::platform::user_shell_environment::pin_process_env_snapshot_for_testing(&[
            ("LICOUP_HOME", "/shell/home"),
            ("LICOUP_PORTABLE_DIR", "/shell/legacy"),
        ]);

    // Without a live process root the launch environment never binds
    // either root name, even when a captured shell value carries one.
    let mut command = Command::new("codex-test");
    apply_launch_environment_with_root(
        &mut command,
        Some(&json!({
            "agentId": "codex",
            "conversationId": "conversation:fixture",
            "membershipId": "membership:codex"
        })),
        None,
    );
    assert_eq!(command_environment(&command, "LICOUP_HOME"), None);
    assert_eq!(command_environment(&command, "LICOUP_PORTABLE_DIR"), None);

    // The plugin server forwards the legacy name through its released
    // allowlist, but both names carry the same selected root.
    let mut command = Command::new("codex-test");
    apply_launch_environment_with_root(
        &mut command,
        None,
        Some(OsString::from("/portable/lico-up")),
    );
    assert_eq!(
        command_environment(&command, "LICOUP_HOME").as_deref(),
        Some("/portable/lico-up")
    );
    assert_eq!(
        command_environment(&command, "LICOUP_PORTABLE_DIR").as_deref(),
        Some("/portable/lico-up")
    );
}
