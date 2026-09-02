use super::*;

#[test]
fn fixed_stream_command_keeps_prompt_off_argv_and_resumes_by_session_flag() {
    let prompt = "private prompt must stay off argv";
    let session = "native-session-1";
    let driver_config = config(
        json!({
            "model": "claude-test-model",
            "reasoningEffort": "xhigh",
            "permissionMode": "plan"
        }),
        prompt,
        session,
    );
    let identity = LaunchIdentity::new("claude-test", &driver_config, Some(&absolute_test_cwd()));
    let args = identity.args();
    assert!(FIXED_STREAM_ARGS.contains(&"--include-partial-messages"));
    assert!(!FIXED_STREAM_ARGS.contains(&"--no-session-persistence"));
    // The prompt never leaves the stdin transport; resuming a native
    // conversation requires the CLI's --resume session flag (like Cursor).
    assert!(args.iter().all(|argument| !argument.contains(prompt)));
    let resume_position = args.iter().position(|argument| argument == "--resume");
    assert_eq!(
        resume_position.map(|index| args[index + 1].as_str()),
        Some(session)
    );
    let fresh = config(json!({}), prompt, "");
    let fresh_identity = LaunchIdentity::new("claude-test", &fresh, Some(&absolute_test_cwd()));
    assert!(
        !fresh_identity
            .args()
            .iter()
            .any(|argument| argument == "--resume")
    );
}

#[test]
fn executable_directory_precedes_inherited_runtime_path() {
    let inherited = std::ffi::OsStr::new("/usr/bin:/bin");
    let path = executable_augmented_path("/runtime/bin/claude", Some(inherited)).unwrap();
    let entries = std::env::split_paths(&path).collect::<Vec<_>>();

    assert_eq!(entries[0], std::path::PathBuf::from("/runtime/bin"));
    assert_eq!(entries[1], std::path::PathBuf::from("/usr/bin"));
    assert_eq!(entries[2], std::path::PathBuf::from("/bin"));
}
