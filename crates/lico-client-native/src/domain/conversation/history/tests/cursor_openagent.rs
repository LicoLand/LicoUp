use super::test_support::*;

#[test]
fn normalized_openagent_tokens_keep_additive_cache_and_reasoning() {
    let usage = extract_token_usage(&json!({
        "tokens": {
            "input": 60,
            "output": 5,
            "reasoning": 2,
            "cache": {"read": 30, "write": 10},
            "total": 67
        }
    }))
    .expect("normalized usage");

    assert_eq!(usage["promptTokens"], 100);
    assert_eq!(usage["cachedInputTokens"], 30);
    assert_eq!(usage["completionTokens"], 7);
    assert_eq!(usage["totalTokens"], 107);
}

#[test]
fn opencode_adapter_imports_sqlite_message_parts() {
    let dir = temp_dir("opencode-sqlite-history");
    let database = dir.join("opencode.db");
    create_openagent_fixture_database(&database, "OpenCode prompt");

    let listed = conversation_list(&json!({
        "agent": "opencode",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["adapterId"], "opencode");
    assert_eq!(sessions[0]["title"], "OpenCode prompt");
    assert_eq!(sessions[0]["model"], "gpt-test");
    assert_eq!(sessions[0]["workingDirectory"], "/workspace/opencode");
    let messages = sessions[0]["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0]["role"], "user");
    assert_eq!(messages[0]["text"], "OpenCode prompt");
    assert_eq!(messages[1]["role"], "agent");
    assert_eq!(messages[1]["text"], "OpenCode answer");
}

#[test]
fn kilo_code_adapter_imports_sqlite_message_parts() {
    let dir = temp_dir("kilo-sqlite-history");
    let database = dir.join("kilo.db");
    create_openagent_fixture_database(&database, "Kilo prompt");

    let listed = conversation_list(&json!({
        "agent": "kilo-code",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["adapterId"], "kilo-code");
    assert_eq!(sessions[0]["title"], "Kilo prompt");
    let messages = sessions[0]["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0]["role"], "user");
    assert_eq!(messages[0]["text"], "Kilo prompt");
    assert_eq!(messages[1]["role"], "agent");
}

#[test]
fn openagent_sqlite_scan_does_not_truncate_after_one_thousand_sessions() {
    let dir = temp_dir("openagent-sqlite-unbounded-sessions");
    let database = dir.join("opencode.db");
    create_openagent_fixture_database(&database, "OpenCode prompt 0");
    let mut connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE INDEX message_session_id ON message(session_id);\
             CREATE INDEX part_session_id ON part(session_id);",
        )
        .unwrap();
    let transaction = connection.transaction().unwrap();
    for index in 1..=1_000 {
        let session_id = format!("ses_{index:04}");
        let message_id = format!("msg_{index:04}");
        let prompt = format!("OpenCode prompt {index}");
        transaction
            .execute(
                "INSERT INTO session VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                (
                    &session_id,
                    &prompt,
                    "/workspace/opencode",
                    "/workspace/opencode",
                    "build",
                    "gpt-test",
                    1_787_616_000_000i64 + index,
                    1_787_616_060_000i64 + index,
                    1i64,
                    2i64,
                    0i64,
                    0i64,
                    0i64,
                ),
            )
            .unwrap();
        transaction
            .execute(
                "INSERT INTO message VALUES (?1, ?2, ?3, ?4, ?5)",
                (
                    &message_id,
                    &session_id,
                    1_787_616_000_000i64 + index,
                    1_787_616_000_000i64 + index,
                    json!({
                        "role": "user",
                        "time": {"created": 1_787_616_000_000i64 + index},
                        "tokens": {"total": 3, "input": 1, "output": 2}
                    })
                    .to_string(),
                ),
            )
            .unwrap();
        transaction
            .execute(
                "INSERT INTO part VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                (
                    format!("part_{index:04}"),
                    &message_id,
                    &session_id,
                    1_787_616_000_000i64 + index,
                    1_787_616_000_000i64 + index,
                    json!({"type": "text", "text": prompt}).to_string(),
                ),
            )
            .unwrap();
    }
    transaction.commit().unwrap();

    let listed = conversation_list(&json!({
        "agent": "opencode",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    assert_eq!(listed["page"]["totalSessions"], 1_001);
    assert_eq!(listed["sessions"].as_array().unwrap().len(), 1_001);
}

#[test]
fn cursor_adapter_reads_sqlite_blob_chat_payloads() {
    let dir = temp_dir("cursor-history");
    let database = dir.join("state.vscdb");
    {
        let connection = Connection::open(&database).unwrap();
        connection
            .execute(
                "CREATE TABLE ItemTable (key TEXT NOT NULL, value BLOB NOT NULL)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                (
                    "composerData.session-1",
                    br#"{"messages":[{"role":"user","text":"Cursor native prompt"},{"role":"assistant","text":"Cursor native answer"}]}"#.as_slice(),
                ),
            )
            .unwrap();
    }

    let listed = conversation_list(&json!({
        "agent": "cursor",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["adapterId"], "cursor");
    assert_eq!(sessions[0]["nativeSessionId"], "composerData.session-1");
    assert_eq!(sessions[0]["messages"].as_array().unwrap().len(), 2);
}

#[test]
fn cursor_adapter_reads_disk_kv_composer_bubbles_with_model() {
    let dir = temp_dir("cursor-disk-kv");
    let database = dir.join("state.vscdb");
    let composer_id = "11111111-1111-1111-1111-111111111111";
    let user_bubble = "22222222-2222-2222-2222-222222222222";
    let agent_bubble = "33333333-3333-3333-3333-333333333333";
    {
        let connection = Connection::open(&database).unwrap();
        connection
            .execute(
                "CREATE TABLE cursorDiskKV (key TEXT NOT NULL, value BLOB NOT NULL)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                rusqlite::params![
                    format!("composerData:{composer_id}"),
                    serde_json::to_vec(&json!({
                        "composerId": composer_id,
                        "name": "Cursor model session",
                        "createdAt": 1_773_798_000_000i64,
                        "lastUpdatedAt": 1_773_798_100_000i64,
                        "modelConfig": { "modelName": "default", "maxMode": false },
                        "fullConversationHeadersOnly": [
                            { "bubbleId": user_bubble, "type": 1 },
                            { "bubbleId": agent_bubble, "type": 2 }
                        ]
                    }))
                    .unwrap()
                ],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                rusqlite::params![
                    format!("bubbleId:{composer_id}:{user_bubble}"),
                    serde_json::to_vec(&json!({
                        "bubbleId": user_bubble,
                        "type": 1,
                        "createdAt": 1_773_798_000_000i64,
                        "text": "Please review this Cursor usage scan.",
                        "tokenCount": { "inputTokens": 0, "outputTokens": 0 }
                    }))
                    .unwrap()
                ],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                rusqlite::params![
                    format!("bubbleId:{composer_id}:{agent_bubble}"),
                    serde_json::to_vec(&json!({
                        "bubbleId": agent_bubble,
                        "type": 2,
                        "createdAt": 1_773_798_050_000i64,
                        "text": "Cursor attributed this reply to the selected model.",
                        "modelInfo": { "modelName": "grok-4.5" },
                        "tokenCount": { "inputTokens": 120, "outputTokens": 40 }
                    }))
                    .unwrap()
                ],
            )
            .unwrap();
    }

    let listed = conversation_list(&json!({
        "agent": "cursor",
        "root": dir.to_string_lossy()
    }))
    .unwrap();
    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], composer_id);
    assert_eq!(sessions[0]["model"], "cursor-auto");
    assert_eq!(sessions[0]["messages"].as_array().unwrap().len(), 2);
    assert_eq!(sessions[0]["messages"][0]["role"], "user");
    assert_eq!(sessions[0]["messages"][0]["model"], "cursor-auto");
    assert_eq!(sessions[0]["messages"][1]["role"], "agent");
    assert_eq!(sessions[0]["messages"][1]["model"], "grok-4.5");
    assert_eq!(sessions[0]["messages"][1]["usage"]["promptTokens"], 120);
    assert_eq!(sessions[0]["messages"][1]["usage"]["completionTokens"], 40);

    let usage = crate::domain::agent_usage::scan(&json!({
        "agent": "cursor",
        "root": dir.to_string_lossy(),
        "historyDays": 3650,
        "forceRefresh": true,
        "stateRoot": temp_dir("cursor-usage-state").to_string_lossy()
    }))
    .unwrap();
    let history = &usage["agents"][0]["history"];
    let daily = history["dailyUsage"].as_array().unwrap();
    assert!(!daily.is_empty(), "expected cursor daily usage entries");
    let model_usage = daily[0]["modelUsage"].as_object().unwrap();
    assert!(
        model_usage.contains_key("grok-4.5"),
        "expected grok-4.5 model usage, got {model_usage:?}"
    );
    assert!(
        !model_usage.contains_key("Others"),
        "cursor models should not collapse into Others: {model_usage:?}"
    );
}

#[test]
fn cursor_adapter_prefers_selected_models_over_composer_label() {
    let dir = temp_dir("cursor-selected-models");
    let database = dir.join("state.vscdb");
    let composer_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    let user_bubble = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
    let agent_bubble = "cccccccc-cccc-cccc-cccc-cccccccccccc";
    {
        let connection = Connection::open(&database).unwrap();
        connection
            .execute(
                "CREATE TABLE cursorDiskKV (key TEXT NOT NULL, value BLOB NOT NULL)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                rusqlite::params![
                    format!("composerData:{composer_id}"),
                    serde_json::to_vec(&json!({
                        "composerId": composer_id,
                        "name": "Composer label hides selected model",
                        "createdAt": 1_773_798_000_000i64,
                        "lastUpdatedAt": 1_773_798_100_000i64,
                        "modelConfig": {
                            "modelName": "composer-2.5-fast",
                            "maxMode": false,
                            "selectedModels": [{ "modelId": "grok-4.5", "parameters": [] }]
                        },
                        "fullConversationHeadersOnly": [
                            { "bubbleId": user_bubble, "type": 1 },
                            { "bubbleId": agent_bubble, "type": 2 }
                        ]
                    }))
                    .unwrap()
                ],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                rusqlite::params![
                    format!("bubbleId:{composer_id}:{user_bubble}"),
                    serde_json::to_vec(&json!({
                        "bubbleId": user_bubble,
                        "type": 1,
                        "createdAt": 1_773_798_000_000i64,
                        "text": "Attribute Cursor usage to the selected model.",
                        "tokenCount": { "inputTokens": 0, "outputTokens": 0 },
                        "modelInfo": { "modelName": "default" }
                    }))
                    .unwrap()
                ],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)",
                rusqlite::params![
                    format!("bubbleId:{composer_id}:{agent_bubble}"),
                    serde_json::to_vec(&json!({
                        "bubbleId": agent_bubble,
                        "type": 2,
                        "createdAt": 1_773_798_050_000i64,
                        "text": "Selected model should win over Composer product label.",
                        "tokenCount": { "inputTokens": 80, "outputTokens": 20 },
                        "modelInfo": { "modelName": "default" }
                    }))
                    .unwrap()
                ],
            )
            .unwrap();
    }

    let listed = conversation_list(&json!({
        "agent": "cursor",
        "root": dir.to_string_lossy()
    }))
    .unwrap();
    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["model"], "grok-4.5");
    assert_eq!(sessions[0]["messages"][0]["model"], "grok-4.5");
    assert_eq!(sessions[0]["messages"][1]["model"], "grok-4.5");

    let usage = crate::domain::agent_usage::scan(&json!({
        "agent": "cursor",
        "root": dir.to_string_lossy(),
        "historyDays": 3650,
        "forceRefresh": true,
        "stateRoot": temp_dir("cursor-selected-usage-state").to_string_lossy()
    }))
    .unwrap();
    let model_usage = usage["agents"][0]["history"]["dailyUsage"][0]["modelUsage"]
        .as_object()
        .unwrap();
    assert_eq!(model_usage.get("grok-4.5"), Some(&json!(100)));
    assert!(
        !model_usage.contains_key("composer-2.5-fast"),
        "composer product label must not replace selected model: {model_usage:?}"
    );
    assert!(
        !model_usage.contains_key("Others"),
        "cursor selected models must not collapse into Others: {model_usage:?}"
    );
    assert!(
        !model_usage.contains_key("cursor-auto"),
        "bubble modelInfo default must fall back to selected model: {model_usage:?}"
    );
}

#[test]
fn sqlite_history_preserves_user_record_rows() {
    let dir = temp_dir("sqlite-history");
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
                ["chat.first", "user message: First native conversation turn"],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)",
                [
                    "chat.second",
                    "assistant message: Second native conversation turn",
                ],
            )
            .unwrap();
    }

    let listed = conversation_list(&json!({
        "agent": "cursor",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    let total_messages = sessions
        .iter()
        .map(|session| session["messages"].as_array().unwrap().len())
        .sum::<usize>();
    assert_eq!(total_messages, 1);
    assert!(
        sessions
            .iter()
            .any(|session| session["nativeSessionId"] == "chat.first")
    );
}
