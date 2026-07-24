use super::*;

#[test]
fn live_process_continuation_cancel_cleanup_and_redaction_close_end_to_end() {
    let _serial = process_local_test_guard();
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
    let history = super::super::conversation_lane::process_local_history(&json!({
        "agent": "claude-code",
        "sessionId": second.session_id
    }))
    .unwrap();
    assert_eq!(history["ok"], true);
    assert_eq!(history["continuityScope"], "process-local");
    assert_eq!(history["nativeSessionId"], second.session_id);
    assert_eq!(history["turnCount"], 2);
    assert_eq!(history["turns"].as_array().unwrap().len(), 2);
    assert_eq!(
        history
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<std::collections::BTreeSet<_>>(),
        [
            "byteCount",
            "continuityScope",
            "nativeSessionId",
            "ok",
            "turnCount",
            "turns"
        ]
        .into_iter()
        .map(str::to_string)
        .collect()
    );
    for turn in history["turns"].as_array().unwrap() {
        assert_eq!(
            turn.as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect::<std::collections::BTreeSet<_>>(),
            ["output", "turnId"]
                .into_iter()
                .map(str::to_string)
                .collect()
        );
    }
    assert_eq!(history["turns"][0]["turnId"], first.turn_id);
    assert_eq!(history["turns"][1]["turnId"], second.turn_id);
    assert_eq!(history["turns"][0]["output"], "fake Claude final answer 1");
    assert_eq!(history["turns"][1]["output"], "fake Claude final answer 2");
    let projected_bytes = history["turns"]
        .as_array()
        .unwrap()
        .iter()
        .map(|turn| turn["output"].as_str().unwrap().len())
        .sum::<usize>();
    assert_eq!(history["byteCount"], json!(projected_bytes));
    let forged = super::super::conversation_lane::process_local_history(&json!({
        "agent": "claude-code",
        "sessionId": "fake-claude-session-forged"
    }))
    .unwrap();
    assert_eq!(forged["ok"], false);
    assert_eq!(forged["error"]["code"], "claude_code_session_unavailable");
    assert_eq!(
        cleanup_session(&second.session_id),
        ControlDisposition::Accepted
    );
    let cleared = super::super::conversation_lane::process_local_history(&json!({
        "agent": "claude-code",
        "sessionId": second.session_id
    }))
    .unwrap();
    assert_eq!(cleared["ok"], false);
    assert_eq!(cleared["error"]["code"], "claude_code_session_unavailable");
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
    let failed_history = super::super::conversation_lane::process_local_history(&json!({
        "agent": "claude-code",
        "sessionId": "fake-claude-session"
    }))
    .unwrap();
    assert_eq!(failed_history["ok"], true);
    assert_eq!(failed_history["turnCount"], 0);
    assert_eq!(
        cleanup_session("fake-claude-session"),
        ControlDisposition::Accepted
    );
    let _ = fs::remove_dir_all(directory);
}

#[test]
fn native_stream_input_accepts_guidance_during_the_active_turn() {
    let _serial = process_local_test_guard();
    let (directory, executable) = compile_fake_claude("lico-claude-native-steer");
    let executable = executable.to_string_lossy().to_string();
    let working_directory = directory.clone();
    let run = thread::spawn(move || {
        execute(
            &executable,
            &json!({
                "model": "fake-model",
                "reasoningEffort": "high",
                "permissionMode": "plan"
            }),
            "fake-claude-steer-prompt",
            "",
            Some(&working_directory),
            10_000,
            1024 * 1024,
            1024,
        )
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    let disposition = loop {
        let disposition = steer("fake-claude-session", "fake-claude-steer-guidance");
        if disposition == ControlDisposition::Accepted || Instant::now() >= deadline {
            break disposition;
        }
        thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(disposition, ControlDisposition::Accepted);
    let result = run.join().unwrap();
    assert!(result.ok, "native steer turn failed: {:?}", result.error);
    assert_eq!(result.output, "fake Claude guided answer");
    assert_eq!(
        cleanup_session(&result.session_id),
        ControlDisposition::Accepted
    );
    let _ = fs::remove_dir_all(directory);
}

#[test]
fn output_overflow_fails_closed_without_recording_a_successful_turn() {
    let _serial = process_local_test_guard();
    let (directory, executable) = compile_fake_claude("lico-claude-output-overflow");
    let result = execute(
        &executable.to_string_lossy(),
        &json!({
            "model": "fake-model",
            "reasoningEffort": "high",
            "permissionMode": "plan"
        }),
        "fake-claude-private-prompt-1",
        "",
        Some(&directory),
        10_000,
        32,
        1024,
    );
    assert!(!result.ok);
    assert!(result.stdout_truncated);
    assert_eq!(result.error.unwrap().code, "claude_code_output_limit");
    assert!(!has_live_session("fake-claude-session"));
    let history = super::super::conversation_lane::process_local_history(&json!({
        "agent": "claude-code",
        "sessionId": "fake-claude-session"
    }))
    .unwrap();
    assert_eq!(history["ok"], false);
    let _ = fs::remove_dir_all(directory);
}

#[test]
fn successful_utf8_output_history_reports_exact_encoded_byte_count() {
    let _serial = process_local_test_guard();
    let (directory, executable) = compile_fake_claude("lico-claude-utf8-history");
    let result = execute(
        &executable.to_string_lossy(),
        &json!({
            "model": "fake-model",
            "reasoningEffort": "high",
            "permissionMode": "plan"
        }),
        "fake-claude-private-prompt-1 fake-claude-utf8-output",
        "",
        Some(&directory),
        10_000,
        1024 * 1024,
        1024,
    );
    let expected = "多字节🙂";
    assert!(result.ok, "UTF-8 fixture turn failed: {:?}", result.error);
    assert_eq!(result.output, expected);
    assert_ne!(expected.as_bytes().len(), expected.chars().count());

    let history = super::super::conversation_lane::process_local_history(&json!({
        "agent": "claude-code",
        "sessionId": result.session_id,
    }))
    .unwrap();
    assert_eq!(history["ok"], true);
    assert_eq!(history["turnCount"], 1);
    assert_eq!(history["turns"][0]["turnId"], result.turn_id);
    assert_eq!(history["turns"][0]["output"], expected);
    assert_eq!(history["byteCount"], json!(expected.as_bytes().len()));
    assert_eq!(
        cleanup_session(result.session_id.as_str()),
        ControlDisposition::Accepted
    );
    let _ = fs::remove_dir_all(directory);
}

#[test]
fn authentication_failure_is_a_stable_redacted_blocker_and_closes_the_transport() {
    let _serial = process_local_test_guard();
    let (directory, executable) = compile_fake_claude("lico-claude-authentication");
    let result = execute(
        &executable.to_string_lossy(),
        &json!({
            "model": "fake-model",
            "reasoningEffort": "high",
            "permissionMode": "plan"
        }),
        "fake-claude-auth-prompt",
        "",
        Some(&directory),
        10_000,
        1024 * 1024,
        1024,
    );
    assert!(!result.ok);
    let failure = result.error.unwrap();
    assert_eq!(failure.code, "claude_code_authentication_required");
    assert!(
        !failure
            .message
            .contains("synthetic private authentication detail")
    );
    let directory_text = directory.to_string_lossy();
    assert!(!failure.message.contains(directory_text.as_ref()));
    assert!(!has_live_session("fake-claude-session"));
    let _ = fs::remove_dir_all(directory);
}
