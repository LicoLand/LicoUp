use super::*;

#[test]
fn fake_child_streams_redacted_events_and_drains_stderr() {
    let (directory, executable) = compile_fake_openclaw("lico-openclaw-execution");
    let result = execute(
        executable.to_string_lossy().as_ref(),
        &json!({
            "reasoningEffort": "medium",
            "gatewayWsUrl": "ws://127.0.0.1:9"
        }),
        "private-openclaw-prompt",
        "",
        Some(directory.as_path()),
        10_000,
        128 * 1024,
        8 * 1024,
    );
    assert!(result.ok, "OpenClaw fake failure: {:?}", result.error);
    assert_eq!(result.output, "native answer");
    assert_eq!(result.session_id, "agent:main:acp:native-session");
    assert_eq!(result.turn_status, "end_turn");
    assert_eq!(result.events.len(), 2);
    assert!(
        result
            .events
            .iter()
            .all(|event| event.get("_meta").is_none())
    );
    assert!(result.events.iter().all(|event| {
        event.pointer("/content/text").and_then(Value::as_str) != Some("must-not-project")
    }));
    assert!(result.stderr_truncated);
    let _ = fs::remove_dir_all(directory);
}
