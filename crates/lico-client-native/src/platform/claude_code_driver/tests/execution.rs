use super::*;

#[test]
fn live_process_continuation_cancel_cleanup_and_redaction_close_end_to_end() {
    let (directory, executable) = compile_fake_claude("lico-claude-execution");
    let executable_text = executable.to_string_lossy().to_string();
    let params = json!({
        "model": "fake-model",
        "reasoningEffort": "high",
        "permissionMode": "plan"
    });
    let first = execute(
        &executable_text,
        &params,
        "fake-claude-private-prompt-1",
        "",
        Some(&directory),
        10_000,
        1024 * 1024,
        1024,
    );
    assert!(first.ok, "first turn failed: {:?}", first.error);
    assert_eq!(first.output, "fake Claude final answer 1");
    assert_eq!(first.session_id, "fake-claude-session");
    assert!(has_live_session(&first.session_id));
    let second = execute(
        &executable_text,
        &json!({}),
        "fake-claude-private-prompt-2",
        &first.session_id,
        Some(&directory),
        10_000,
        1024 * 1024,
        1024,
    );
    assert!(second.ok, "second turn failed: {:?}", second.error);
    assert_eq!(second.output, "fake Claude final answer 2");
    assert_eq!(second.session_id, first.session_id);
    assert_eq!(
        cleanup_session(&second.session_id),
        ControlDisposition::Accepted
    );
    let unavailable = execute(
        &executable_text,
        &json!({}),
        "third",
        &second.session_id,
        Some(&directory),
        1_000,
        1024,
        1024,
    );
    assert_eq!(
        unavailable.error.unwrap().code,
        "claude_code_live_session_unavailable"
    );

    let working_dir = directory.clone();
    let executable_for_cancel = executable_text.clone();
    let run = thread::spawn(move || {
        execute(
            &executable_for_cancel,
            &json!({
                "model": "fake-model",
                "reasoningEffort": "high",
                "permissionMode": "plan"
            }),
            "fake-claude-cancel-prompt",
            "",
            Some(&working_dir),
            10_000,
            1024 * 1024,
            1024,
        )
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    let disposition = loop {
        let disposition = cancel("fake-claude-session");
        if disposition == ControlDisposition::Accepted || Instant::now() >= deadline {
            break disposition;
        }
        thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(disposition, ControlDisposition::Accepted);
    let cancelled = run.join().unwrap();
    assert_eq!(cancelled.error.unwrap().code, "claude_code_turn_failed");
    assert_eq!(
        cleanup_session("fake-claude-session"),
        ControlDisposition::Accepted
    );
    let _ = fs::remove_dir_all(directory);
}
