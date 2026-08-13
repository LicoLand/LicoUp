use super::test_support::*;

fn windows_path(parts: &[&str]) -> String {
    parts.join(&char::from(92).to_string())
}

#[test]
fn exact_session_filter_matches_projection_or_native_identity() {
    let projection = HistoryScanConfig::from_params(&json!({
        "sessionId": "projection-1"
    }));
    let native = HistoryScanConfig::from_params(&json!({
        "sessionId": "native-1"
    }));
    let other = HistoryScanConfig::from_params(&json!({
        "sessionId": "other"
    }));
    let multiple = HistoryScanConfig::from_params(&json!({
        "sessionIds": ["projection-1", "other"]
    }));
    let session = json!({
        "id": "projection-1",
        "nativeSessionId": "native-1",
        "messages": []
    });

    assert!(projection.has_single_session_filter());
    assert!(!multiple.has_single_session_filter());
    assert!(projection.matches_session(&session));
    assert!(native.matches_session(&session));
    assert!(!other.matches_session(&session));
}

#[test]
fn default_history_home_uses_windows_userprofile_when_home_is_missing() {
    let profile = windows_path(&["C:", "Profile", "LicoMesh"]);
    let resolved = home_dir_from_env(|name| match name {
        "USERPROFILE" => Some(OsString::from(&profile)),
        _ => None,
    });

    assert_eq!(resolved, PathBuf::from(profile));
}

#[test]
fn default_history_home_uses_windows_drive_and_homepath_fallback() {
    let home_path = windows_path(&["", "Profile", "LicoMesh"]);
    let resolved = home_dir_from_env(|name| match name {
        "HOMEDRIVE" => Some(OsString::from("C:")),
        "HOMEPATH" => Some(OsString::from(&home_path)),
        _ => None,
    });

    assert_eq!(
        resolved,
        PathBuf::from(windows_path(&["C:", "Profile", "LicoMesh"]))
    );
}

#[test]
fn expand_home_accepts_windows_style_tilde_paths() {
    let profile = PathBuf::from(windows_path(&["C:", "Profile", "LicoMesh"]));
    let sessions = windows_path(&[".codex", "sessions"]);
    let expanded = expand_home_from(&windows_path(&["~", ".codex", "sessions"]), || {
        profile.clone()
    });

    assert_eq!(expanded, profile.join(sessions));
}

#[test]
fn history_roots_follow_home_override_for_xdg_backed_targets() {
    let home = temp_dir("history-home-override");

    let cursor = history_roots(
        HistoryAdapter::Cursor,
        &json!({"homeDir": display_path(&home)}),
    );
    let code = history_roots(
        HistoryAdapter::Code,
        &json!({"homeDir": display_path(&home)}),
    );
    let copilot = history_roots(
        HistoryAdapter::Copilot,
        &json!({"homeDir": display_path(&home)}),
    );

    assert!(
        cursor
            .iter()
            .any(|root| root.path == home.join(".config/Cursor/User/workspaceStorage"))
    );
    assert!(
        code.iter()
            .any(|root| root.path == home.join(".config/Code/User/workspaceStorage"))
    );
    assert!(
        copilot
            .iter()
            .any(|root| root.path == home.join(".config/Code/User/globalStorage"))
    );
}

#[test]
fn history_roots_cover_kimi_app_data_locations() {
    let home = temp_dir("history-kimi-roots");

    let roots = history_roots(
        HistoryAdapter::Kimi,
        &json!({"homeDir": display_path(&home)}),
    );

    assert!(
        roots
            .iter()
            .any(|root| root.path == home.join("Library/Application Support/Kimi"))
    );
    assert!(
        roots
            .iter()
            .any(|root| root.path == home.join("Library/Application Support/com.moonshot.kimi"))
    );
    assert!(
        roots
            .iter()
            .any(|root| root.path == home.join(".config/Kimi"))
    );
    assert!(
        roots
            .iter()
            .any(|root| root.path == home.join(".local/share/Kimi"))
    );
}

#[test]
fn conversations_list_paginates_native_history_sessions() {
    let dir = temp_dir("codex-history-pagination");
    let lines = (0..120)
        .map(|index| {
            format!(
                r#"{{"sessionId":"page-session-{index}","role":"user","content":"Paged history prompt {index}","createdAt":{}}}"#,
                1_787_616_000_000i64 + index * 1000
            )
        })
        .collect::<Vec<_>>();
    fs::write(dir.join("history.jsonl"), lines.join("\n")).unwrap();

    let page_two = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy(),
        "limit": 50,
        "offset": 50
    }))
    .unwrap();
    let sessions = page_two["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 50);
    assert_eq!(sessions[0]["nativeSessionId"], "page-session-69");
    assert_eq!(page_two["page"]["offset"], 50);
    assert_eq!(page_two["page"]["limit"], 50);
    assert_eq!(page_two["page"]["totalSessions"], 120);
    assert_eq!(page_two["page"]["hasMore"], true);

    let last_page = conversation_list(&json!({
        "agent": "codex",
        "root": dir.to_string_lossy(),
        "limit": 50,
        "offset": 100
    }))
    .unwrap();
    assert_eq!(last_page["sessions"].as_array().unwrap().len(), 20);
    assert_eq!(last_page["page"]["hasMore"], false);
}

#[test]
fn every_supported_agent_has_dedicated_history_adapter() {
    for agent in [
        "antigravity",
        "claude-code",
        "code",
        "codex",
        "copilot",
        "cursor",
        "hermes",
        "kilo-code",
        "kimi",
        "openclaw",
        "opencode",
    ] {
        let dir = temp_dir(&format!("{}-adapter", agent));
        fs::write(
            dir.join("session.json"),
            format!(
                r#"{{
                  "sessions": [{{
                    "sessionId": "{agent}-session",
                    "messages": [
                      {{"role": "user", "text": "{agent} native prompt"}},
                      {{"role": "assistant", "text": "{agent} native answer"}}
                    ]
                  }}]
                }}"#
            ),
        )
        .unwrap();

        let listed = conversation_list(&json!({
            "agent": agent,
            "root": dir.to_string_lossy()
        }))
        .unwrap();

        assert_eq!(listed["adapterId"], agent);
        assert_eq!(listed["importMode"], "precise-adapter");
        assert_eq!(listed["sessions"][0]["adapterId"], agent);
        assert_eq!(
            listed["sessions"][0]["nativeSessionId"],
            format!("{}-session", agent)
        );
    }
}

#[test]
fn unsupported_history_adapter_is_rejected() {
    let error = conversation_list(&json!({"agent": "unknown-agent"})).unwrap_err();
    assert!(
        error
            .to_string()
            .contains("unsupported native history adapter")
    );
}

#[test]
fn native_history_is_read_only() {
    assert!(conversation_append(&json!({})).is_err());
    assert!(conversation_delete(&json!({})).is_err());
}

#[test]
fn native_history_skips_dependency_directories() {
    let dir = temp_dir("dependency-history");
    let dependency = dir.join("node_modules/pkg");
    fs::create_dir_all(&dependency).unwrap();
    fs::write(
        dependency.join("README.md"),
        "user: unrelated dependency mentions pact\nassistant: not history",
    )
    .unwrap();
    fs::write(
        dir.join("session.md"),
        "user: real pact conversation\nassistant: archived",
    )
    .unwrap();

    let listed = conversation_list(&json!({
        "agent": "opencode",
        "root": dir.to_string_lossy()
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(
        sessions[0]["sourcePath"],
        display_path(&dir.join("session.md"))
    );
    assert!(
        listed["sources"]["skipped"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["reason"] == "excluded_non_history_directory")
    );
}
#[test]
fn exact_cursor_read_avoids_unrelated_project_trees() {
    let home = temp_dir("exact-cursor-directed");
    let wanted_id = "019f0000-0000-7000-8000-0000000000f1";
    let transcript = home
        .join(".cursor/projects/wanted-project/agent-transcripts")
        .join(wanted_id)
        .join(format!("{wanted_id}.jsonl"));
    fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    fs::write(
        &transcript,
        concat!(
            r#"{"role":"user","message":{"content":[{"type":"text","text":"Directed prompt"}]}}"#,
            "\n",
            r#"{"role":"assistant","message":{"content":[{"type":"text","text":"Directed reply"}]}}"#,
            "\n",
        ),
    )
    .unwrap();
    // Wide unrelated trees: two other projects with their own conversation
    // directories, each carrying delegated-looking subdirectories.
    for (index, project) in ["other-one", "other-two"].iter().enumerate() {
        let other_id = format!("019f0000-0000-7000-8000-0000000000f{}", index + 2);
        let other_root = home
            .join(".cursor/projects")
            .join(project)
            .join("agent-transcripts")
            .join(&other_id);
        fs::create_dir_all(other_root.join("subagents")).unwrap();
        fs::write(
            other_root.join(format!("{other_id}.jsonl")),
            r#"{"role":"user","message":{"content":[{"type":"text","text":"unrelated"}]}}"#,
        )
        .unwrap();
        fs::write(
            other_root.join("subagents/delegated.jsonl"),
            r#"{"role":"user","message":{"content":[{"type":"text","text":"unrelated task"}]}}"#,
        )
        .unwrap();
    }

    let listed = conversation_list(&json!({
        "agent": "cursor",
        "homeDir": display_path(&home),
        "sessionIds": [wanted_id]
    }))
    .unwrap();

    let sessions = listed["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["nativeSessionId"], wanted_id);
    assert!(
        sessions[0]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|message| message["text"] == "Directed prompt")
    );
    // Directory pruning keeps the walk on the requested layout paths: the
    // unrelated conversation directories are skipped, never descended.
    assert_eq!(listed["sources"]["filesSeen"], 1);
    assert!(
        listed["sources"]["directoryEntriesSeen"].as_u64().unwrap() <= 10,
        "directed exact lookup avoids unrelated trees"
    );
    assert!(
        listed["sources"]["skipped"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["reason"] == "exact_session_miss")
    );
}

#[test]
fn query_test_temp_dir_cleans_on_normal_return_and_unwind() {
    let normal_path = {
        let dir = temp_dir("guard-normal");
        let path = dir.to_path_buf();
        assert!(path.is_dir());
        path
    };
    assert!(!normal_path.exists());

    let observed = std::cell::RefCell::new(None);
    let unwind = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let dir = temp_dir("guard-unwind");
        observed.replace(Some(dir.to_path_buf()));
        panic!("synthetic guard unwind");
    }));
    assert!(unwind.is_err());
    assert!(!observed.into_inner().unwrap().exists());
}

#[cfg(unix)]
#[test]
fn query_test_temp_dir_refuses_symlink_replacement() {
    use std::os::unix::fs::symlink;

    let external = temp_dir("guard-symlink-external");
    let guarded = temp_dir("guard-symlink-root");
    let guarded_path = guarded.to_path_buf();
    fs::remove_dir(&guarded_path).unwrap();
    symlink(external.as_path(), &guarded_path).unwrap();
    let error = guarded.close().unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
    assert!(external.is_dir());
    fs::remove_file(guarded_path).unwrap();
}
