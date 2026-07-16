use super::test_support::*;

#[test]
fn native_history_merges_delegated_subagent_prompt_sessions() {
    let dir = temp_dir("native-subagent-prompt");
    fs::write(
        dir.join("project.jsonl"),
        [
            r#"{"timestamp":"2026-06-01T00:00:00Z","sessionId":"real-session","type":"user","message":{"role":"user","content":"Why are history titles unreadable?"}}"#,
            r#"{"timestamp":"2026-06-01T00:00:01Z","sessionId":"subagent-session","type":"user","message":{"role":"user","content":"You are A1: Old-path Migration Batch. Inspect the repository and report."}}"#,
            r#"{"timestamp":"2026-06-01T00:00:02Z","sessionId":"subagent-session","type":"assistant","message":{"role":"assistant","content":"I need to find old-path files in the LicoLite repo."}}"#,
            r#"{"timestamp":"2026-06-01T00:00:03Z","sessionId":"real-session","type":"assistant","message":{"role":"assistant","content":"I will fix the title extraction."}}"#,
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
    assert_eq!(sessions[0]["nativeSessionId"], "real-session");
    assert_eq!(sessions[0]["title"], "Why are history titles unreadable?");
    let messages = sessions[0]["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3);
    assert_eq!(messages[1]["role"], "subagent");
    assert_eq!(messages[1]["cardType"], "subagent");
    assert_eq!(messages[1]["cardTitle"], "A1: Old-path Migration Batch");
    assert_eq!(
        messages[1]["messages"][0]["text"],
        "I need to find old-path files in the LicoLite repo."
    );
    assert!(!messages.iter().any(|message| {
        message["text"]
            .as_str()
            .unwrap_or_default()
            .contains("You are A1")
    }));
    assert!(looks_like_delegated_agent_prompt(
        "You are discovery worker round-05/worker-03 for a Codex Security Deep Security Scan. You are not the coordinator."
    ));
}

#[test]
fn codex_history_merges_explicit_subagent_lineage_into_parent_thread() {
    let dir = temp_dir("codex-explicit-subagent-lineage");
    let sessions = dir.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    fs::write(
        sessions.join("rollout-parent.jsonl"),
        [
            r#"{"timestamp":"2026-07-12T00:00:00Z","type":"session_meta","payload":{"id":"parent-session","cwd":"/workspace/project"}}"#,
            r#"{"timestamp":"2026-07-12T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Audit this page"}]}}"#,
            r#"{"timestamp":"2026-07-12T00:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Merged the worker result."}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        sessions.join("rollout-child.jsonl"),
        [
            r#"{"timestamp":"2026-07-12T00:00:02Z","type":"session_meta","payload":{"id":"child-session","cwd":"/workspace/project","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","agent_nickname":"reviewer"}}}}}"#,
            r#"{"timestamp":"2026-07-12T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Found one issue."}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], "parent-session");
    let messages = sessions[0]["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 3);
    assert_eq!(messages[1]["role"], "subagent");
    assert_eq!(messages[1]["cardTitle"], "reviewer");
    assert_eq!(messages[1]["messages"][0]["text"], "Found one issue.");
}

#[test]
fn codex_history_merges_forked_rollout_continuations_by_lineage() {
    let dir = temp_dir("codex-fork-lineage-merge");
    let sessions = dir.join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    fs::write(
        sessions.join("rollout-root.jsonl"),
        [
            r#"{"timestamp":"2026-07-12T01:00:00Z","type":"session_meta","payload":{"id":"root-session","cwd":"/workspace/project"}}"#,
            r#"{"timestamp":"2026-07-12T01:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请验收当前 Lico Arc 客户端"}]}}"#,
            r#"{"timestamp":"2026-07-12T01:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"先看第一轮"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        sessions.join("rollout-fork-a.jsonl"),
        [
            r#"{"timestamp":"2026-07-12T02:00:00Z","type":"session_meta","payload":{"id":"fork-a","cwd":"/workspace/project","forked_from_id":"root-session"}}"#,
            r#"{"timestamp":"2026-07-12T02:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请验收当前 Lico Arc 客户端"}]}}"#,
            r#"{"timestamp":"2026-07-12T02:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"先看第一轮"}]}}"#,
            r#"{"timestamp":"2026-07-12T02:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"继续第二轮"}]}}"#,
            r#"{"timestamp":"2026-07-12T02:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"第二轮完成"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        sessions.join("rollout-fork-b.jsonl"),
        [
            r#"{"timestamp":"2026-07-12T03:00:00Z","type":"session_meta","payload":{"id":"fork-b","cwd":"/workspace/project","forked_from_id":"fork-a"}}"#,
            r#"{"timestamp":"2026-07-12T03:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请验收当前 Lico Arc 客户端"}]}}"#,
            r#"{"timestamp":"2026-07-12T03:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"先看第一轮"}]}}"#,
            r#"{"timestamp":"2026-07-12T03:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"继续第二轮"}]}}"#,
            r#"{"timestamp":"2026-07-12T03:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"第二轮完成"}]}}"#,
            r#"{"timestamp":"2026-07-12T03:00:05Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"再继续第三轮"}]}}"#,
            r#"{"timestamp":"2026-07-12T03:00:06Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"第三轮完成"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        sessions.join("rollout-unrelated.jsonl"),
        [
            r#"{"timestamp":"2026-07-12T04:00:00Z","type":"session_meta","payload":{"id":"unrelated-session","cwd":"/workspace/project"}}"#,
            r#"{"timestamp":"2026-07-12T04:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请验收当前 Lico Arc 客户端"}]}}"#,
            r#"{"timestamp":"2026-07-12T04:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"这是无关会话"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 2);
    let lineage = sessions
        .iter()
        .find(|session| session["lineageRootId"] == "root-session")
        .expect("lineage session");
    assert_eq!(lineage["nativeSessionId"], "fork-b");
    assert_eq!(lineage["lineageRootId"], "root-session");
    let lineage_ids = lineage["lineageSessionIds"].as_array().unwrap();
    assert_eq!(lineage_ids.len(), 3);
    assert!(lineage_ids.iter().any(|value| value == "root-session"));
    assert!(lineage_ids.iter().any(|value| value == "fork-a"));
    assert!(lineage_ids.iter().any(|value| value == "fork-b"));
    let texts = lineage["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|message| message.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>();
    assert!(texts.contains(&"第三轮完成"));
    assert_eq!(
        texts
            .iter()
            .filter(|text| **text == "请验收当前 Lico Arc 客户端")
            .count(),
        1
    );
    let unrelated = sessions
        .iter()
        .find(|session| session["nativeSessionId"] == "unrelated-session")
        .expect("unrelated session");
    assert_eq!(unrelated["title"], "请验收当前 Lico Arc 客户端");
}

#[test]
fn codex_history_dedupes_same_native_session_across_active_and_archive_paths() {
    let dir = temp_dir("codex-active-archive-dedupe");
    let active = dir.join("sessions");
    let archived = dir.join("archived_sessions");
    fs::create_dir_all(&active).unwrap();
    fs::create_dir_all(&archived).unwrap();
    let body = [
        r#"{"timestamp":"2026-07-12T05:00:00Z","type":"session_meta","payload":{"id":"shared-session","cwd":"/workspace/project"}}"#,
        r#"{"timestamp":"2026-07-12T05:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Same thread"}]}}"#,
        r#"{"timestamp":"2026-07-12T05:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Same reply"}]}}"#,
    ]
    .join("\n");
    fs::write(active.join("rollout-shared.jsonl"), &body).unwrap();
    fs::write(archived.join("rollout-shared.jsonl"), &body).unwrap();

    let listed = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy()
    }))
    .unwrap();
    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], "shared-session");
}
