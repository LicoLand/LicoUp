use super::*;

#[test]
fn fixed_stream_command_excludes_prompt_and_session() {
    let prompt = "private prompt must stay off argv";
    let session = "private session must stay off argv";
    let config = config(
        json!({
            "model": "claude-test-model",
            "reasoningEffort": "xhigh",
            "permissionMode": "plan"
        }),
        prompt,
        session,
    );
    let identity = LaunchIdentity::new("claude-test", &config, Some(&absolute_test_cwd()));
    let args = identity.args();
    assert!(FIXED_STREAM_ARGS.contains(&"--include-partial-messages"));
    assert!(!FIXED_STREAM_ARGS.contains(&"--no-session-persistence"));
    assert!(
        args.iter()
            .all(|argument| !argument.contains(prompt) && !argument.contains(session))
    );
    assert!(!args.iter().any(|argument| argument == "--resume"));
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
