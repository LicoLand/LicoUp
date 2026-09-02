use super::test_support::*;

#[test]
fn pi_session_jsonl_history_preserves_native_session_and_roles() {
    let root = temp_dir("pi-session-history");
    let session = root.join("--workspace--/20260101T000000_pi-native-session.jsonl");
    fs::create_dir_all(session.parent().unwrap()).unwrap();
    fs::write(
        &session,
        [
            r#"{"type":"session","version":3,"id":"pi-native-session","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/workspace/project"}"#,
            r#"{"type":"session_info","id":"n1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","name":"Pi fixture"}"#,
            r#"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"user","content":"List the fixtures"}}"#,
            r#"{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"assistant","model":"pi-test-model","content":[{"type":"text","text":"Found one fixture"}],"usage":{"input":10,"output":5},"stopReason":"stop"}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "pi",
        "root": display_path(&root),
    }))
    .unwrap();
    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["adapterId"], "pi");
    assert_eq!(sessions[0]["adapterLabel"], "Pi Agent - CLI");
    assert_eq!(sessions[0]["nativeSessionId"], "pi-native-session");
    assert_eq!(sessions[0]["title"], "Pi fixture");
    let messages = sessions[0]["messages"].as_array().unwrap();
    assert!(
        messages
            .iter()
            .any(|message| { message["role"] == "user" && message["text"] == "List the fixtures" })
    );
    assert!(
        messages.iter().any(|message| {
            message["role"] == "agent" && message["text"] == "Found one fixture"
        })
    );
    let agent = messages
        .iter()
        .find(|message| message["role"] == "agent")
        .unwrap();
    assert_eq!(agent["model"], "pi-test-model");
    assert_eq!(agent["usage"]["totalTokens"], 15);

    let usage_state = temp_dir("pi-exact-usage-state");
    let usage = crate::domain::agent_usage::scan(&json!({
        "agent": "pi",
        "root": display_path(&root),
        "stateRoot": display_path(&usage_state),
        "now": "2026-01-01T12:00:00Z",
        "forceRefresh": true
    }))
    .unwrap();
    assert_eq!(usage["agents"][0]["history"]["totalTokens"], 15);
}

#[test]
fn copilot_adapter_imports_transcript_events() {
    let dir = temp_dir("copilot-transcript-history");
    let transcript_dir = dir.join("GitHub.copilot-chat/transcripts");
    fs::create_dir_all(&transcript_dir).unwrap();
    fs::write(
        transcript_dir.join("copilot-session.jsonl"),
        [
            r#"{"type":"session.start","data":{"sessionId":"copilot-session"},"timestamp":"2026-06-12T00:00:00Z"}"#,
            r#"{"type":"user.message","data":{"messageId":"u1","content":"Ask Copilot to inspect routing"},"timestamp":"2026-06-12T00:00:01Z"}"#,
            r#"{"type":"assistant.message","data":{"messageId":"a0","content":""},"timestamp":"2026-06-12T00:00:02Z"}"#,
            r#"{"type":"tool.execution_start","data":{"toolName":"readFile"},"timestamp":"2026-06-12T00:00:03Z"}"#,
            r#"{"type":"assistant.message","data":{"messageId":"a1","content":"Copilot answer","model":"copilot-test-model","usage":{"input_tokens":20,"output_tokens":6}},"timestamp":"2026-06-12T00:00:04Z"}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "copilot",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["adapterId"], "copilot");
    assert_eq!(sessions[0]["nativeSessionId"], "copilot-session");
    assert_eq!(sessions[0]["title"], "Ask Copilot to inspect routing");
    let messages = sessions[0]["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3);
    assert_eq!(messages[0]["role"], "user");
    assert_eq!(messages[1]["role"], "tool_call");
    assert_eq!(messages[1]["cardType"], "tool-call");
    assert_eq!(messages[1]["cardTitle"], "readFile");
    assert_eq!(messages[2]["role"], "agent");
    assert_eq!(messages[2]["model"], "copilot-test-model");
    assert_eq!(messages[2]["usage"]["totalTokens"], 26);
}

#[test]
fn copilot_adapter_imports_item_table_chat_sessions() {
    let dir = temp_dir("copilot-history");
    let database = dir.join("state.vscdb");
    {
        let connection = Connection::open(&database).unwrap();
        connection
            .execute(
                "CREATE TABLE ItemTable (key TEXT NOT NULL, value TEXT NOT NULL)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                [
                    "github.copilot-chat.chatSessions",
                    r#"{"chatSessions":[{"id":"copilot-chat-1","messages":[{"role":"user","content":"Ask Copilot about LicoMesh"},{"role":"assistant","content":"Copilot answer"}]}]}"#,
                ],
            )
            .unwrap();
    }

    let listed = conversation_list(&json!({
        "agent": "copilot",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["adapterId"], "copilot");
    assert_eq!(
        sessions[0]["messages"][0]["text"],
        "Ask Copilot about LicoMesh"
    );
}
