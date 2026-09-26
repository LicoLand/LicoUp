use super::test_support::*;

#[test]
fn codex_runtime_activity_requires_open_rollout_and_unfinished_task() {
    let dir = temp_dir("codex-runtime-activity");
    let running = dir.join("rollout-running.jsonl");
    let completed = dir.join("rollout-completed.jsonl");
    fs::write(
        &running,
        [
            r#"{"type":"event_msg","payload":{"type":"task_started"}}"#.to_string(),
            format!(
                "{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"agent_reasoning\",\"text\":\"{}\"}}}}",
                "x".repeat(
                    (super::super::codex::CODEX_RUNTIME_SCAN_CHUNK_BYTES as usize) + 128
                )
            ),
            r#"{"type":"event_msg","payload":{"type":"agent_reasoning"}}"#.to_string(),
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        &completed,
        [
            r#"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            r#"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let observation =
        CodexRuntimeObservation::from_open_rollouts([running.clone(), completed.clone()]);
    assert!(observation.is_running(&running));
    assert!(!observation.is_running(&completed));
    assert!(!CodexRuntimeObservation::from_open_rollouts([]).is_running(&running));

    let mut sessions = vec![
        json!({"sourcePath": running.to_string_lossy()}),
        json!({"sourcePath": completed.to_string_lossy(), "running": true}),
    ];
    mark_codex_runtime_activity(&mut sessions, &observation);
    assert_eq!(sessions[0]["running"], true);
    assert!(sessions[1].get("running").is_none());
}

#[test]
fn conversations_scan_codex_jsonl_history() {
    let dir = temp_dir("codex-history");
    let history = dir.join("history.jsonl");
    fs::write(
        &history,
        [
            r#"{"sessionId":"codex-history","role":"user","content":"Build LicoMesh native history","createdAt":"2026-06-12T00:00:00Z"}"#,
            r#"{"sessionId":"codex-history","role":"assistant","content":"Use Codex history adapter","createdAt":"2026-06-12T00:00:01Z"}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    assert_eq!(listed["mode"], "native-history");
    assert_eq!(listed["readOnly"], true);
    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["agentId"], "codex");
    assert_eq!(sessions[0]["native"], true);
    assert_eq!(sessions[0]["messages"].as_array().unwrap().len(), 2);
    assert_eq!(
        sessions[0]["messages"][0]["text"],
        "Build LicoMesh native history"
    );
}

#[test]
fn explicit_total_reconciles_inclusive_cache_read_tokens() {
    let usage = extract_token_usage(&json!({
        "usage": {
            "input_tokens": 100,
            "cache_read_input_tokens": 40,
            "output_tokens": 10,
            "total_tokens": 110
        }
    }))
    .expect("explicit usage");

    assert_eq!(usage["promptTokens"], 100);
    assert_eq!(usage["cachedInputTokens"], 40);
    assert_eq!(usage["completionTokens"], 10);
    assert_eq!(usage["totalTokens"], 110);
    assert_eq!(
        usage["promptTokens"].as_u64().unwrap() + usage["completionTokens"].as_u64().unwrap(),
        usage["totalTokens"].as_u64().unwrap()
    );
}

#[test]
fn parent_usage_marks_the_last_content_block_as_request_response_scope() {
    let messages = messages_from_json(
        HistoryAdapter::OpenCode,
        Path::new("fixture.json"),
        0,
        &json!({
            "role": "assistant",
            "content": [
                {"type": "output_text", "text": "first"},
                {"type": "output_text", "text": "second"},
                {"type": "tool_use", "name": "read_fixture", "input": {}}
            ],
            "usage": {
                "input_tokens": 100,
                "cached_input_tokens": 40,
                "output_tokens": 10,
                "total_tokens": 110
            }
        }),
    );

    assert_eq!(messages.len(), 3);
    assert!(messages[0].get("usage").is_none());
    assert!(messages[1].get("usage").is_none());
    assert_eq!(messages[2]["cardType"], "tool-call");
    assert_eq!(messages[2]["usageScope"], "request-response");
    assert_eq!(messages[2]["usage"]["totalTokens"], 110);
}

#[test]
fn codex_jsonl_groups_by_native_session_id() {
    let dir = temp_dir("codex-session-groups");
    fs::write(
        dir.join("session.jsonl"),
        [
            r#"{"sessionId":"codex-session-1","role":"user","content":"First session prompt"}"#,
            r#"{"sessionId":"codex-session-2","role":"user","content":"Second session prompt"}"#,
            r#"{"sessionId":"codex-session-2","role":"assistant","content":"Second session answer"}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    assert_eq!(listed["adapterId"], "codex");
    assert_eq!(listed["importMode"], "precise-adapter");
    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 2);
    assert!(
        sessions
            .iter()
            .any(|session| session["nativeSessionId"] == "codex-session-2"
                && session["messages"].as_array().unwrap().len() == 2)
    );

    let native_filtered = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy(),
        "sessionId": "codex-session-2"
    }))
    .unwrap();
    let native_sessions = native_filtered["sessions"].as_array().unwrap();
    assert_eq!(native_sessions.len(), 1);
    assert_eq!(native_sessions[0]["nativeSessionId"], "codex-session-2");

    let projection_id = native_sessions[0]["id"].as_str().unwrap();
    let projection_error = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy(),
        "sessionId": projection_id
    }))
    .unwrap_err();
    assert_eq!(
        projection_error.to_string(),
        "native_history_session_not_found"
    );
}

#[test]
fn codex_exact_session_readback_parses_only_the_bound_rollout() {
    let home = temp_dir("codex-exact-readback");
    let sessions = home.join(".codex").join("sessions").join("2000/01/01");
    fs::create_dir_all(&sessions).unwrap();
    let session_id = "00000000-0000-4000-8000-000000000001";
    for index in 0..64 {
        fs::write(
            sessions.join(format!("rollout-unrelated-{index:03}.jsonl")),
            "not-json",
        )
        .unwrap();
    }
    fs::write(
        sessions.join(format!("rollout-2000-01-01T00-00-00-{session_id}.jsonl")),
        [
            format!(
                r#"{{"timestamp":"2000-01-01T00:00:00Z","type":"session_meta","payload":{{"id":"{session_id}","cwd":"/workspace/project"}}}}"#
            ),
            r#"{"timestamp":"2000-01-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Exact readback prompt"}]}}"#.to_string(),
            r#"{"timestamp":"2000-01-01T00:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Exact readback reply"}]}}"#.to_string(),
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        home.join(".codex").join("session_index.jsonl"),
        format!(r#"{{"id":"{session_id}","thread_name":"index-title-must-not-be-read"}}"#),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "homeDir": home.to_string_lossy(),
        "sessionId": session_id,
        "limit": 1
    }))
    .unwrap();

    assert_eq!(listed["sources"]["filesSeen"], 1);
    assert!(listed["sources"]["directoryEntriesSeen"].as_u64().unwrap() < 128);
    let found = listed["sessions"].as_array().unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0]["nativeSessionId"], session_id);
    assert_eq!(found[0]["messages"].as_array().unwrap().len(), 2);
    assert_ne!(found[0]["title"], "index-title-must-not-be-read");
}

#[test]
fn codex_adapter_extracts_rollout_payload_sessions() {
    let dir = temp_dir("codex-rollout");
    let sessions = dir.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let rollout =
        sessions.join("rollout-2000-01-01T00-00-00-00000000-0000-4000-8000-000000000001.jsonl");
    fs::write(
        &rollout,
        [
            r#"{"timestamp":"2000-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"00000000-0000-4000-8000-000000000001","cwd":"/workspace/fixture-project","originator":"codex","cli_version":"1.2.3"}}"#,
            r#"{"timestamp":"2000-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Read the synthetic fixture"}]}}"#,
            r#"{"timestamp":"2000-01-01T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Synthetic fixture response"}]}}"#,
            r#"{"timestamp":"2000-01-01T00:00:04.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Checked the synthetic fixture at /workspace/fixture-project with authorization=Bearer abcdefghijklmnopqrstuvwxyz0123456789"}],"text":"Private chain of thought"}}"#,
            r#"{"timestamp":"2000-01-01T00:00:05.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\"cmd\":\"rg fixture /workspace/fixture-project\",\"access_token\":\"secret-value\"}"}}"#,
            r#"{"timestamp":"2000-01-01T00:00:06.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"{\"path\":\"/workspace/fixture-project\",\"access_token\":\"secret-value\",\"ok\":true}"}}"#,
            r#"{"timestamp":"2000-01-01T00:00:07.000Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"Command failed in /workspace/fixture-project with authorization=Bearer abcdefghijklmnopqrstuvwxyz0123456789"}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy(),
        "archiveMode": true
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    let session = &sessions[0];
    assert_eq!(session["adapterId"], "codex");
    assert_eq!(
        session["nativeSessionId"],
        "00000000-0000-4000-8000-000000000001"
    );
    assert_eq!(session["workingDirectory"], "/workspace/fixture-project");
    let messages = session["messages"].as_array().unwrap();
    assert!(!messages.iter().any(|message| {
        message["text"]
            .as_str()
            .unwrap_or_default()
            .contains("/workspace/fixture-project")
    }));
    assert!(
        messages
            .iter()
            .any(|message| message["text"] == "Read the synthetic fixture")
    );
    assert!(messages.iter().any(|message| message["role"] == "agent"));
    let reasoning = messages
        .iter()
        .find(|message| message["role"] == "reasoning")
        .expect("reasoning card");
    assert_eq!(reasoning["cardType"], "reasoning");
    assert_eq!(reasoning["collapsed"], true);
    // Recorded chain of thought is the detail body; the provider summary
    // becomes the collapsed headline preview instead of a separate card.
    assert!(reasoning.get("providerSummary").is_none());
    assert_eq!(reasoning["text"], "Private chain of thought");
    assert_eq!(
        reasoning["cardSubtitle"],
        "Checked the synthetic fixture at [local path hidden] with authorization: [redacted] [redacted]"
    );
    let tool_call = messages
        .iter()
        .find(|message| message["role"] == "tool_call")
        .expect("tool call card");
    assert_eq!(tool_call["cardType"], "tool-call");
    assert_eq!(tool_call["cardTitle"], "exec_command");
    assert_eq!(
        tool_call["text"],
        "access_token: [redacted]\ncmd: rg fixture [local path hidden]"
    );
    let tool_result = messages
        .iter()
        .find(|message| message["role"] == "tool_result")
        .expect("tool result card");
    assert_eq!(tool_result["cardType"], "tool-result");
    assert_eq!(
        tool_result["text"],
        "access_token: [redacted]\nok: true\npath: [local path hidden]"
    );
    let error = messages
        .iter()
        .find(|message| message["role"] == "error")
        .expect("error card");
    assert_eq!(error["cardType"], "error");
    assert_eq!(error["collapsed"], false);
    let serialized = serde_json::to_string(messages).unwrap();
    assert!(!serialized.contains("secret-value"));
    assert!(!serialized.contains("abcdefghijklmnopqrstuvwxyz0123456789"));
    assert!(!messages.iter().any(|message| {
        message["text"]
            .as_str()
            .unwrap_or_default()
            .contains("/workspace/fixture-project")
    }));
}

#[test]
fn codex_adapter_skips_background_context_prompt_messages() {
    let dir = temp_dir("codex-background-context");
    let sessions = dir.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let rollout =
        sessions.join("rollout-2000-01-01T00-00-00-00000000-0000-4000-8000-000000000001.jsonl");
    fs::write(
        &rollout,
        [
            r#"{"timestamp":"2000-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"00000000-0000-4000-8000-000000000001","cwd":"/workspace/fixture-project"}}"#,
            r##"{"timestamp":"2000-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\n\n<INSTRUCTIONS>\n1. Background repo rule.\n</INSTRUCTIONS>\n<environment_context>\n  <cwd>fixture-workspace</cwd>\n</environment_context>"}]}}"##,
            r#"{"timestamp":"2000-01-01T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Show only the user request"}]}}"#,
            r#"{"timestamp":"2000-01-01T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Only the request is shown"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let session = &listed["sessions"].as_array().unwrap()[0];
    assert_eq!(session["title"], "Show only the user request");
    let messages = session["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert!(messages.iter().any(|message| {
        message["role"] == "user" && message["text"] == "Show only the user request"
    }));
    assert!(!messages.iter().any(|message| {
        let text = message["text"].as_str().unwrap_or_default();
        text.contains("AGENTS.md")
            || text.contains("Background repo rule")
            || text.contains("<environment_context>")
            || text.contains("fixture-workspace")
    }));
}

#[test]
fn codex_adapter_skips_apps_instructions_prompt_messages() {
    let dir = temp_dir("codex-apps-instructions-context");
    let sessions = dir.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let rollout = sessions.join("rollout-2000-01-01T00-00-00-00000000-0000-4000-8000-apps.jsonl");
    fs::write(
        &rollout,
        [
            r#"{"timestamp":"2000-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<apps_instructions>\n# Apps (Connectors)\nApps can be explicitly triggered.\n</appsinstructions>"}]}}"#,
            r#"{"timestamp":"2000-01-01T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"真正的用户问题"}]}}"#,
            r#"{"timestamp":"2000-01-01T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"真正的回答"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let session = &listed["sessions"].as_array().unwrap()[0];
    assert_eq!(session["title"], "真正的用户问题");
    let messages = session["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert!(messages.iter().any(|message| {
        message["role"] == "user" && message["text"] == "真正的用户问题"
    }));
    assert!(!messages.iter().any(|message| {
        let text = message["text"].as_str().unwrap_or_default();
        text.contains("Apps (Connectors)") || text.contains("<apps_instructions>")
    }));
}

#[test]
fn codex_adapter_extracts_real_user_request_from_app_wrapper() {
    let dir = temp_dir("codex-user-wrapper");
    let sessions = dir.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let rollout =
        sessions.join("rollout-2000-01-01T00-00-00-00000000-0000-4000-8000-000000000001.jsonl");
    fs::write(
        &rollout,
        [
            r#"{"timestamp":"2000-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"00000000-0000-4000-8000-000000000001"}}"#,
            r##"{"timestamp":"2000-01-01T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# Files mentioned by the user:\n\n## synthetic-image.png: fixture/synthetic-image.png\n\n## My request:\n请读取合成图片\n<image name=[Image #1] path=\"fixture/synthetic-image.png\">\nsynthetic image metadata\n</image>"}]}}"##,
            r#"{"timestamp":"2000-01-01T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Synthetic image response"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let session = &listed["sessions"].as_array().unwrap()[0];
    let messages = session["messages"].as_array().unwrap();
    let user_message = messages
        .iter()
        .find(|message| message["role"] == "user")
        .expect("user message");
    assert_eq!(user_message["text"], "请读取合成图片");
    assert_eq!(user_message["images"][0]["mediaType"], "image/png");
    assert_eq!(
        user_message["images"][0]["path"],
        "fixture/synthetic-image.png"
    );
    assert!(!messages.iter().any(|message| {
        let text = message["text"].as_str().unwrap_or_default();
        text.contains("Files mentioned")
            || text.contains("synthetic-image")
            || text.contains("<image")
            || text.contains("synthetic image metadata")
    }));
}
