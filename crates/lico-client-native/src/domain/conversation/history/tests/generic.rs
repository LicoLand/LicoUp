use super::test_support::*;

#[test]
fn pure_startup_logs_are_not_native_conversations() {
    let dir = temp_dir("startup-log-history");
    fs::write(
        dir.join("opencode.log"),
        [
            r#"INFO 2026-06-20T00:00:00Z args=["mcp","list"] opencode"#,
            "INFO service=config path=<user-home>/.config/opencode/config.json",
            "INFO directory=/workspace/licolite creating instance",
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "opencode",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    assert_eq!(listed["sessions"].as_array().unwrap().len(), 0);
}

#[test]
fn service_logs_with_embedded_messages_are_not_native_conversations() {
    let dir = temp_dir("embedded-message-log-history");
    fs::write(
        dir.join("opencode.log"),
        [
            r#"INFO 2026-06-20T00:00:00Z service=default directory=/repo/Pact creating instance"#,
            r#"ERROR 2026-06-20T00:00:01Z service=llm requestBodyValues={"messages":[{"role":"user","content":"Pact task"},{"role":"assistant","content":"answer"}]}"#,
            r#"INFO 2026-06-20T00:00:02Z service=server status=started"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "opencode",
        "root": dir.to_string_lossy(),
        "archiveMode": true,
        "matchTerms": ["Pact"]
    }))
    .unwrap();

    assert_eq!(listed["sessions"].as_array().unwrap().len(), 0);
}

#[test]
fn text_transcripts_are_native_conversations() {
    let dir = temp_dir("text-transcript-history");
    fs::write(
        dir.join("conversation.txt"),
        ["User: archive the LicoLite history", "Assistant: archived"].join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "opencode",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["title"], "archive the LicoLite history");
}

#[test]
fn antigravity_history_decodes_protocol_wrapped_messages() {
    let dir = temp_dir("antigravity-protocol-history");
    fs::write(
        dir.join("ag-session.json"),
        serde_json::to_string_pretty(&json!({
            "sessions": [
                {
                    "sessionId": "antigravity-session",
                    "title": "<USER_REQUEST> 请找到本项目的开发规则文档入口 </USER_REQUEST>",
                    "messages": [
                        {
                            "role": "user",
                            "content": "<SYSTEM_MESSAGE>Hidden Antigravity runtime context.</SYSTEM_MESSAGE>\n<USER_REQUEST>请找到本项目的开发规则文档入口</USER_REQUEST>"
                        },
                        {
                            "role": "assistant",
                            "content": "The following is a <SYSTEM_MESSAGE> not actually sent by the user. It is provided by the system as important information to pay attention to."
                        },
                        {
                            "role": "view_file",
                            "content": "2255 │ \"coverageContribution\": false,\n2256 │ \"artifacts\": [],\n2257 │ \"command\": \"npm\"\n2258 │ \"args\": [\n2259 │   \"run\",\n2260 │   \"verify\"\n2261 │ ]"
                        },
                        {
                            "role": "run_command",
                            "content": "npm run verify\nPASS 133 tests"
                        },
                        {
                            "role": "planner_response",
                            "content": "开发规则入口在仓库根目录的 AGENTS.md。"
                        }
                    ]
                }
            ]
        }))
        .unwrap(),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "antigravity",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["title"], "请找到本项目的开发规则文档入口");
    let messages = sessions[0]["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 4);
    assert_eq!(messages[0]["text"], "请找到本项目的开发规则文档入口");
    assert_eq!(messages[1]["role"], "tool_call");
    assert_eq!(messages[1]["cardTitle"], "View file");
    assert_eq!(messages[2]["role"], "tool_call");
    assert_eq!(messages[2]["cardTitle"], "Run command");
    assert_eq!(
        messages[3]["text"],
        "开发规则入口在仓库根目录的 AGENTS.md。"
    );
    assert!(!messages.iter().any(|message| {
        let text = message["text"].as_str().unwrap_or_default();
        text.contains("<USER_REQUEST>")
            || text.contains("<SYSTEM_MESSAGE>")
            || text.contains("not actually sent by the user")
            || text.contains("coverageContribution")
            || text.contains("npm run verify")
            || text.contains("2255")
    }));
}

#[test]
fn claude_code_adapter_extracts_nested_jsonl_messages() {
    let dir = temp_dir("claude-history");
    fs::write(
        dir.join("project.jsonl"),
        [
            r#"{"sessionId":"claude-session-1","type":"user","message":{"role":"user","content":[{"type":"text","text":"Open the LicoLite repo"}]}}"#,
            r#"{"sessionId":"claude-session-1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Repo opened"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "claude-code",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["adapterId"], "claude-code");
    assert_eq!(sessions[0]["nativeSessionId"], "claude-session-1");
    assert_eq!(sessions[0]["messages"][0]["text"], "Open the LicoLite repo");
    assert_eq!(sessions[0]["messages"][1]["role"], "agent");
}
