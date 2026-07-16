use super::test_support::*;

#[test]
fn kimi_code_history_roots_are_isolated_from_desktop_history() {
    let home = temp_dir("history-kimi-code-roots");
    let custom = home.join("custom-kimi-code");

    let default_roots = history_roots(
        HistoryAdapter::KimiCode,
        &json!({"homeDir": display_path(&home)}),
    );
    assert_eq!(default_roots[0].path, home.join(".kimi-code/sessions"));
    assert_eq!(default_roots[0].source_kind, "kimi-code-session-store");
    assert_eq!(default_roots.len(), 1);

    let custom_roots = history_roots(
        HistoryAdapter::KimiCode,
        &json!({
            "homeDir": display_path(&home),
            "kimiCodeHome": display_path(&custom),
        }),
    );
    assert_eq!(custom_roots[0].path, custom.join("sessions"));
    assert!(HistoryAdapter::KimiCode.accepts_file(
        &custom.join("sessions/wd/session/agents/main/wire.jsonl"),
        "jsonl",
    ));
    assert!(
        !HistoryAdapter::KimiCode
            .accepts_file(&custom.join("sessions/wd/session/state.json"), "json",)
    );
}

#[test]
fn kimi_code_wire_usage_records_preserve_model_and_exact_token_fields() {
    let root = temp_dir("kimi-code-wire");
    let wire = root.join("wd_project/session-1/agents/main/wire.jsonl");
    fs::create_dir_all(wire.parent().unwrap()).unwrap();
    fs::write(
        &wire,
        [
            r#"{"type":"metadata","protocol_version":1}"#,
            r#"{"type":"context.append_message","time":1780912800000,"message":{"role":"user","content":"Review the synthetic Kimi Code fixture"}}"#,
            r#"{"type":"usage.record","time":1780912801000,"model":"kimi-code/kimi-for-coding","usageScope":"turn","usage":{"inputOther":100,"inputCacheRead":20,"inputCacheCreation":5,"output":30}}"#,
            r#"{"type":"usage.record","time":1780912802000,"model":"kimi-code/kimi-for-coding","usageScope":"session","usage":{"inputOther":9999,"inputCacheRead":0,"inputCacheCreation":0,"output":9999}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "kimi-code",
        "root": display_path(&root),
    }))
    .unwrap();
    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["adapterId"], "kimi-code");
    assert_eq!(sessions[0]["adapterLabel"], "Kimi Code - CLI");
    assert_eq!(sessions[0]["nativeSessionId"], "session-1");

    let messages = sessions[0]["messages"].as_array().unwrap();
    assert!(messages.iter().any(|message| {
        message["role"] == "user" && message["text"] == "Review the synthetic Kimi Code fixture"
    }));
    let usage = messages
        .iter()
        .find(|message| message["sourceEventType"] == "usage.record")
        .unwrap();
    assert_eq!(usage["model"], "kimi-code/kimi-for-coding");
    assert_eq!(usage["usage"]["promptTokens"], 125);
    assert_eq!(usage["usage"]["cachedInputTokens"], 20);
    assert_eq!(usage["usage"]["completionTokens"], 30);
    assert_eq!(usage["usage"]["totalTokens"], 155);
    assert_eq!(
        messages
            .iter()
            .filter(|message| message["sourceEventType"] == "usage.record")
            .count(),
        1,
    );
}

#[test]
fn kimi_code_wire_readback_preserves_session_and_structured_order() {
    let root = temp_dir("kimi-code-structured-wire");
    let session_root = root.join("work-key/native-session-42");
    let wire = session_root.join("agents/main/wire.jsonl");
    fs::create_dir_all(wire.parent().unwrap()).unwrap();
    fs::write(
        session_root.join("state.json"),
        r#"{"title":"Synthetic Kimi Code session"}"#,
    )
    .unwrap();
    let reasoning_canary = "PRIVATE_REASONING_CANARY";
    let argument_canary = "api_key=PRIVATE_ARGUMENT_CANARY";
    fs::write(
        &wire,
        [
            r#"{"type":"turn.prompt","turnId":"turn-1","time":"2026-07-10T00:00:00Z","input":"Kimi Code synthetic prompt"}"#,
            &format!(r#"{{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:01Z","event":{{"type":"content.part","step":1,"part":{{"type":"think","think":"{reasoning_canary} "}}}}}}"#),
            r#"{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:01Z","event":{"type":"content.part","step":1,"part":{"type":"think","think":"second private chunk"}}}"#,
            &format!(r#"{{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:02Z","event":{{"type":"tool.call","name":"exec","arguments":{{"command":"{argument_canary}"}}}}}}"#),
            r#"{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:03Z","event":{"type":"tool.result","name":"exec","result":"completed"}}"#,
            r#"{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:04Z","event":{"type":"content.part","step":2,"part":{"type":"text","text":"Final "}}}"#,
            r#"{"type":"context.append_loop_event","turnId":"turn-1","time":"2026-07-10T00:00:04Z","event":{"type":"content.part","step":2,"part":{"type":"text","text":"answer"}}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "kimi-code",
        "root": display_path(&root),
    }))
    .unwrap();
    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["adapterId"], "kimi-code");
    assert_eq!(sessions[0]["adapterLabel"], "Kimi Code - CLI");
    assert_eq!(sessions[0]["nativeSessionId"], "native-session-42");

    let messages = sessions[0]["messages"].as_array().unwrap();
    let roles = messages
        .iter()
        .map(|message| message["role"].as_str().unwrap_or_default())
        .collect::<Vec<_>>();
    assert_eq!(
        roles,
        vec!["user", "reasoning", "tool_call", "tool_result", "agent"]
    );
    assert_eq!(messages[0]["text"], "Kimi Code synthetic prompt");
    assert_eq!(messages[1]["text"], "Reasoning details are redacted.");
    assert!(messages[1].get("providerSummary").is_none());
    assert_eq!(messages[2]["cardType"], "tool-call");
    assert_eq!(messages[2]["text"], "Invocation details are hidden.");
    assert_eq!(messages[3]["cardType"], "tool-result");
    assert_eq!(messages[4]["text"], "Final answer");
    assert_eq!(
        messages
            .iter()
            .filter(|message| message["role"] == "reasoning")
            .count(),
        1
    );
    assert_eq!(
        messages
            .iter()
            .filter(|message| message["role"] == "agent")
            .count(),
        1
    );
    let serialized = serde_json::to_string(messages).unwrap();
    assert!(!serialized.contains(reasoning_canary));
    assert!(!serialized.contains(argument_canary));
}
