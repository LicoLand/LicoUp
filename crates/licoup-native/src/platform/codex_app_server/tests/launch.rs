use crate::platform::codex_app_server::launch::{CodexLaunchSpec, apply_launch_environment};
use serde_json::json;
use std::ffi::OsStr;
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
    let mut command = Command::new("codex-test");
    apply_launch_environment(
        &mut command,
        Some(&json!({
            "agentId": "codex",
            "conversationId": "conversation:fixture",
            "membershipId": "membership:codex",
            "dispatchId": "turn:direct"
        })),
    );

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
        command_environment(&command, "LICOUP_MCP_PARENT_DISPATCH_ID"),
        None
    );
    assert_eq!(command_environment(&command, "LICOUP_PORTABLE_DIR"), None);
}
