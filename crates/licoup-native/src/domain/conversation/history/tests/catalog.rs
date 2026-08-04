use super::test_support::*;

fn now_epoch_seconds() -> i64 {
    OffsetDateTime::now_utc().unix_timestamp()
}

fn now_epoch_millis() -> i64 {
    now_epoch_seconds() * 1_000
}

fn iso_days_ago(days: i64) -> String {
    (OffsetDateTime::now_utc() - time::Duration::days(days))
        .format(&Rfc3339)
        .unwrap()
}

fn codex_rollout_fixture(session_id: &str, prompt: &str, reply: &str) -> String {
    [
        format!(
            r#"{{"timestamp":"2026-08-01T00:00:00Z","type":"session_meta","payload":{{"id":"{session_id}","cwd":"/workspace/catalog"}}}}"#
        ),
        format!(
            r#"{{"timestamp":"2026-08-01T00:00:01Z","type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"{prompt}"}}]}}}}"#
        ),
        format!(
            r#"{{"timestamp":"2026-08-01T00:00:02Z","type":"response_item","payload":{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"{reply}"}}]}}}}"#
        ),
    ]
    .join("\n")
}

fn create_codex_state_db(path: &Path, threads: &[(&str, &str, i64, i64, &str, i64)]) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT,
                created_at INTEGER,
                updated_at INTEGER,
                title TEXT,
                archived INTEGER,
                cwd TEXT,
                model TEXT
            )",
            [],
        )
        .unwrap();
    for (id, rollout_path, created_at, updated_at, title, archived) in threads {
        connection
            .execute(
                "INSERT INTO threads VALUES (?1, ?2, ?3, ?4, ?5, ?6, '/workspace/catalog', 'gpt-test')",
                (id, rollout_path, created_at, updated_at, title, archived),
            )
            .unwrap();
    }
}

fn session_ids(listed: &Value) -> Vec<String> {
    listed["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|session| session["nativeSessionId"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn codex_catalog_uses_state_threads_and_supplements_fresh_rollouts() {
    let home = temp_dir("codex-catalog-tiered");
    let sessions_dir = home.join(".codex/sessions/2026/08/01");
    fs::create_dir_all(&sessions_dir).unwrap();
    let recent_id = "019f0000-0000-7000-8000-0000000000a1";
    let fresh_id = "019f0000-0000-7000-8000-0000000000b2";
    let recent_rollout =
        sessions_dir.join(format!("rollout-2026-08-01T00-00-00-{recent_id}.jsonl"));
    fs::write(
        &recent_rollout,
        codex_rollout_fixture(recent_id, "Recent prompt", "Recent reply"),
    )
    .unwrap();
    fs::write(
        sessions_dir.join(format!("rollout-2026-08-01T00-00-01-{fresh_id}.jsonl")),
        codex_rollout_fixture(fresh_id, "Fresh prompt", "Fresh reply"),
    )
    .unwrap();
    let now = now_epoch_seconds();
    create_codex_state_db(
        &home.join(".codex/state_5.sqlite"),
        &[
            (
                recent_id,
                &*recent_rollout.to_string_lossy(),
                now - 10,
                now,
                "Recent thread",
                0,
            ),
            // Archived threads never enter the browse catalog.
            (
                "019f0000-0000-7000-8000-0000000000c3",
                "/missing/archived.jsonl",
                now - 10,
                now,
                "Archived thread",
                1,
            ),
            // Threads outside the thirty-day window are not loaded.
            (
                "019f0000-0000-7000-8000-0000000000d4",
                "/missing/old.jsonl",
                now - 41 * 86_400,
                now - 40 * 86_400,
                "Old thread",
                0,
            ),
        ],
    );

    let listed = conversation_list(&json!({
        "agent": "codex",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    let ids = session_ids(&listed);
    assert_eq!(ids.len(), 2);
    assert!(ids.contains(&recent_id.to_string()));
    assert!(ids.contains(&fresh_id.to_string()));
    assert_eq!(listed["page"]["totalSessions"], 2);
    let sessions = listed["sessions"].as_array().unwrap();
    let recent = sessions
        .iter()
        .find(|session| session["nativeSessionId"] == recent_id)
        .unwrap();
    assert_eq!(recent["title"], "Recent thread");
    assert_eq!(recent["workingDirectory"], "/workspace/catalog");
    // Page sessions are hydrated from their rollout content.
    let messages = recent["messages"].as_array().unwrap();
    assert!(
        messages
            .iter()
            .any(|message| message["text"] == "Recent reply")
    );
    let fresh = sessions
        .iter()
        .find(|session| session["nativeSessionId"] == fresh_id)
        .unwrap();
    assert!(
        fresh["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["text"] == "Fresh prompt")
    );
}

#[test]
fn codex_catalog_rejects_unrecognized_state_schema_and_falls_back_to_rollouts() {
    let home = temp_dir("codex-catalog-fail-closed");
    let sessions_dir = home.join(".codex/sessions/2026/08/01");
    fs::create_dir_all(&sessions_dir).unwrap();
    let session_id = "019f0000-0000-7000-8000-0000000000e5";
    fs::write(
        sessions_dir.join(format!("rollout-2026-08-01T00-00-00-{session_id}.jsonl")),
        codex_rollout_fixture(session_id, "Fallback prompt", "Fallback reply"),
    )
    .unwrap();
    let connection = Connection::open(home.join(".codex/state_5.sqlite")).unwrap();
    connection
        .execute("CREATE TABLE threads (id TEXT PRIMARY KEY, note TEXT)", [])
        .unwrap();
    drop(connection);

    let listed = conversation_list(&json!({
        "agent": "codex",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    assert_eq!(session_ids(&listed), vec![session_id.to_string()]);
    assert!(
        listed["sources"]["skipped"]
            .as_array()
            .unwrap()
            .iter()
            .any(|skip| skip["reason"] == "codex_state_schema_unrecognized")
    );
    assert!(
        listed["sessions"][0]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["text"] == "Fallback reply")
    );
}

#[test]
fn codex_catalog_leaves_archived_rollouts_out_of_browse_lists() {
    let home = temp_dir("codex-catalog-archived-excluded");
    let archived_dir = home.join(".codex/archived_sessions");
    fs::create_dir_all(&archived_dir).unwrap();
    let archived_id = "019f0000-0000-7000-8000-0000000000f6";
    fs::write(
        archived_dir.join(format!("rollout-2026-08-01T00-00-00-{archived_id}.jsonl")),
        codex_rollout_fixture(archived_id, "Archived prompt", "Archived reply"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    assert_eq!(listed["page"]["totalSessions"], 0);
    assert!(listed["sessions"].as_array().unwrap().is_empty());
}

#[test]
fn codex_search_still_scans_archived_rollouts_without_a_window() {
    let home = temp_dir("codex-catalog-search-full-scan");
    let archived_dir = home.join(".codex/archived_sessions");
    fs::create_dir_all(&archived_dir).unwrap();
    let archived_id = "019f0000-0000-7000-8000-0000000000a7";
    fs::write(
        archived_dir.join(format!("rollout-2026-08-01T00-00-00-{archived_id}.jsonl")),
        codex_rollout_fixture(
            archived_id,
            "needleword archived prompt",
            "needleword reply",
        ),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "homeDir": display_path(&home),
        "matchTerm": "needleword",
        "limit": 20
    }))
    .unwrap();

    assert!(
        !listed["sessions"].as_array().unwrap().is_empty(),
        "explicit search must cover archived history without the recency window"
    );
}

#[test]
fn codex_catalog_paginates_and_hydrates_only_the_returned_page() {
    let home = temp_dir("codex-catalog-paging");
    let sessions_dir = home.join(".codex/sessions/2026/08/01");
    fs::create_dir_all(&sessions_dir).unwrap();
    let first_id = "019f0000-0000-7000-8000-000000000011";
    let second_id = "019f0000-0000-7000-8000-000000000022";
    fs::write(
        sessions_dir.join(format!("rollout-2026-08-01T00-00-00-{first_id}.jsonl")),
        codex_rollout_fixture(first_id, "First prompt", "First reply"),
    )
    .unwrap();
    fs::write(
        sessions_dir.join(format!("rollout-2026-08-01T00-00-01-{second_id}.jsonl")),
        codex_rollout_fixture(second_id, "Second prompt", "Second reply"),
    )
    .unwrap();
    // Pin the recency order so the page assignment is deterministic.
    let now = SystemTime::now();
    fs::OpenOptions::new()
        .write(true)
        .open(sessions_dir.join(format!("rollout-2026-08-01T00-00-00-{first_id}.jsonl")))
        .unwrap()
        .set_modified(now)
        .unwrap();
    fs::OpenOptions::new()
        .write(true)
        .open(sessions_dir.join(format!("rollout-2026-08-01T00-00-01-{second_id}.jsonl")))
        .unwrap()
        .set_modified(now - std::time::Duration::from_secs(60))
        .unwrap();

    let page_one = conversation_list(&json!({
        "agent": "codex",
        "homeDir": display_path(&home),
        "limit": 1
    }))
    .unwrap();
    assert_eq!(page_one["page"]["totalSessions"], 2);
    assert_eq!(page_one["page"]["hasMore"], true);
    let sessions = page_one["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], first_id);
    assert!(
        sessions[0]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["text"] == "First reply")
    );

    let page_two = conversation_list(&json!({
        "agent": "codex",
        "homeDir": display_path(&home),
        "limit": 1,
        "offset": 1
    }))
    .unwrap();
    let sessions = page_two["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], second_id);
    assert!(
        sessions[0]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["text"] == "Second reply")
    );
    assert_eq!(page_two["page"]["hasMore"], false);
}

fn create_openagent_catalog_db(path: &Path) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute(
            "CREATE TABLE session (
                id TEXT PRIMARY KEY,
                parent_id TEXT,
                title TEXT,
                directory TEXT,
                model TEXT,
                time_created INTEGER,
                time_updated INTEGER,
                time_archived INTEGER
            )",
            [],
        )
        .unwrap();
    let now = now_epoch_millis();
    for (id, parent, archived, updated) in [
        ("ses_keep", None, None, Some(now)),
        ("ses_sub", Some("ses_keep"), None, Some(now)),
        ("ses_arch", None, Some(now), Some(now)),
        ("ses_old", None, None, Some(now - 40 * 86_400_000)),
    ] {
        connection
            .execute(
                "INSERT INTO session VALUES (?1, ?2, ?3, '/workspace/openagent', 'gpt-test', ?4, ?4, ?5)",
                (
                    id,
                    parent,
                    format!("Title {id}"),
                    updated,
                    archived,
                ),
            )
            .unwrap();
    }
}

#[test]
fn opencode_catalog_filters_sub_sessions_alongside_archived_and_old() {
    let home = temp_dir("opencode-catalog");
    let data_dir = home.join(".local/share/opencode");
    fs::create_dir_all(&data_dir).unwrap();
    create_openagent_catalog_db(&data_dir.join("opencode.db"));

    let listed = conversation_list(&json!({
        "agent": "opencode",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    let mut ids = session_ids(&listed);
    ids.sort();
    // Sub-agent sessions stay reachable through their parent's transcript,
    // matching the kilo catalog rule.
    assert_eq!(ids, vec!["ses_keep".to_string()]);
    let sessions = listed["sessions"].as_array().unwrap();
    let keep = sessions
        .iter()
        .find(|session| session["nativeSessionId"] == "ses_keep")
        .unwrap();
    assert_eq!(keep["title"], "Title ses_keep");
    assert_eq!(keep["workingDirectory"], "/workspace/openagent");
    assert!(keep["messages"].as_array().unwrap().is_empty());
}

#[test]
fn kilo_catalog_filters_sub_sessions_alongside_archived_and_old() {
    let home = temp_dir("kilo-catalog");
    let data_dir = home.join(".local/share/kilo");
    fs::create_dir_all(&data_dir).unwrap();
    create_openagent_catalog_db(&data_dir.join("kilo.db"));

    let listed = conversation_list(&json!({
        "agent": "kilo-code",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    assert_eq!(session_ids(&listed), vec!["ses_keep".to_string()]);
}

#[test]
fn kimi_code_catalog_reads_state_json_and_hydrates_page_from_wire() {
    let home = temp_dir("kimi-code-catalog");
    let session_dir = home.join(".kimi-code/sessions/wd_project/session-a");
    fs::create_dir_all(session_dir.join("agents/main")).unwrap();
    fs::write(
        session_dir.join("state.json"),
        json!({
            "title": "Kimi fixture title",
            "createdAt": iso_days_ago(1),
            "updatedAt": iso_days_ago(0),
            "workDir": "/workspace/kimi"
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        session_dir.join("agents/main/wire.jsonl"),
        [
            r#"{"type":"metadata","protocol_version":1}"#,
            r#"{"type":"context.append_message","time":1780912800000,"message":{"role":"user","content":"Kimi catalog prompt"}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "kimi-code",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], "session-a");
    assert_eq!(sessions[0]["title"], "Kimi fixture title");
    assert_eq!(sessions[0]["workingDirectory"], "/workspace/kimi");
    assert!(
        sessions[0]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["text"] == "Kimi catalog prompt")
    );
}

#[test]
fn cursor_catalog_reads_chat_meta_and_skips_empty_chats() {
    let home = temp_dir("cursor-catalog");
    let chat_dir = home.join(".cursor/chats/ab12cd34/chat-one");
    fs::create_dir_all(&chat_dir).unwrap();
    fs::write(
        chat_dir.join("meta.json"),
        json!({
            "createdAtMs": now_epoch_millis() - 1_000,
            "updatedAtMs": now_epoch_millis(),
            "cwd": "/workspace/cursor",
            "hasConversation": true
        })
        .to_string(),
    )
    .unwrap();
    let empty_dir = home.join(".cursor/chats/ab12cd34/chat-empty");
    fs::create_dir_all(&empty_dir).unwrap();
    fs::write(
        empty_dir.join("meta.json"),
        json!({
            "createdAtMs": now_epoch_millis(),
            "updatedAtMs": now_epoch_millis(),
            "hasConversation": false
        })
        .to_string(),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "cursor",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], "chat-one");
    assert_eq!(sessions[0]["workingDirectory"], "/workspace/cursor");
}

#[test]
fn cursor_catalog_reads_project_workspace_path_for_agent_transcripts() {
    let home = temp_dir("cursor-project-cwd");
    let project_dir = home.join(".cursor/projects/Users-fixture-LicoUp");
    let transcript_dir = project_dir.join("agent-transcripts/session-one");
    fs::create_dir_all(&transcript_dir).unwrap();
    fs::write(
        project_dir.join(".workspace-trusted"),
        json!({
            "trustedAt": "2026-08-02T02:06:46.038Z",
            "workspacePath": "/workspace/licoup",
            "trustMethod": "cli-flag"
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        transcript_dir.join("session-one.jsonl"),
        concat!(
            r#"{"role":"user","message":{"content":[{"type":"text","text":"project prompt"}]}}"#,
            "\n",
            r#"{"role":"assistant","message":{"content":[{"type":"text","text":"project reply"}]}}"#,
            "\n",
        ),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "cursor",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], "session-one");
    assert_eq!(sessions[0]["workingDirectory"], "/workspace/licoup");
    assert_eq!(sessions[0]["sourceKind"], "cursor-cli-projects");
}

#[test]
fn claude_catalog_probes_head_titles_and_applies_the_recency_window() {
    let home = temp_dir("claude-catalog");
    let project_dir = home.join(".claude/projects/-workspace-project");
    fs::create_dir_all(&project_dir).unwrap();
    let recent = project_dir.join("cd2442dd-a04c-4503-8ce3-1d114047ce63.jsonl");
    fs::write(
        &recent,
        [
            r#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-01T00:00:00Z","sessionId":"cd2442dd-a04c-4503-8ce3-1d114047ce63"}"#,
            r#"{"type":"user","timestamp":"2026-08-01T00:00:01Z","sessionId":"cd2442dd-a04c-4503-8ce3-1d114047ce63","message":{"role":"user","content":[{"type":"text","text":"Claude catalog prompt"}]}}"#,
            r#"{"type":"assistant","timestamp":"2026-08-01T00:00:02Z","sessionId":"cd2442dd-a04c-4503-8ce3-1d114047ce63","message":{"role":"assistant","content":[{"type":"text","text":"Claude catalog reply"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();
    let stale = project_dir.join("00000000-0000-4000-8000-000000000000.jsonl");
    fs::write(
        &stale,
        r#"{"type":"user","message":{"role":"user","content":"stale prompt"}}"#,
    )
    .unwrap();
    fs::OpenOptions::new()
        .write(true)
        .open(&stale)
        .unwrap()
        .set_modified(SystemTime::now() - std::time::Duration::from_secs(40 * 86_400))
        .unwrap();

    let listed = conversation_list(&json!({
        "agent": "claude-code",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    let ids = session_ids(&listed);
    assert_eq!(
        ids,
        vec!["cd2442dd-a04c-4503-8ce3-1d114047ce63".to_string()]
    );
    let session = &listed["sessions"][0];
    assert_eq!(session["title"], "Claude catalog prompt");
    assert!(
        session["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["text"] == "Claude catalog reply")
    );
}

#[test]
fn pi_catalog_reads_the_session_header_line() {
    let home = temp_dir("pi-catalog");
    let session_dir = home.join(".pi/agent/sessions/--workspace-project");
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(
        session_dir.join("2026-08-01T00-00-00-000Z_019f9a4b-afeb-7c91-bb4b-fd4fa934e367.jsonl"),
        [
            r#"{"type":"session","version":3,"id":"019f9a4b-afeb-7c91-bb4b-fd4fa934e367","timestamp":"2026-08-01T00:00:00.000Z","cwd":"/workspace/pi"}"#,
            r#"{"type":"message","timestamp":"2026-08-01T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Pi catalog prompt"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "pi",
        "homeDir": display_path(&home),
        "limit": 20
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(
        sessions[0]["nativeSessionId"],
        "019f9a4b-afeb-7c91-bb4b-fd4fa934e367"
    );
    assert_eq!(sessions[0]["workingDirectory"], "/workspace/pi");
}
