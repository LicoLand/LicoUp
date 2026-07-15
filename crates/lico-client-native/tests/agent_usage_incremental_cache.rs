use lico_client_native::domain::agent_usage;
use lico_client_native::domain::conversations;
use lico_client_native::platform::client_state::ClientStateStore;
use rusqlite::Connection as SqliteConnection;
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn codex_usage_reconciles_subsets_duplicates_and_divergent_totals() {
    let history_root = temp_dir("codex-usage-reconcile-history");
    let state_root = temp_dir("codex-usage-reconcile-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"session-reconcile"}}"#.to_string(),
            r#"{"timestamp":"2026-07-08T10:00:01Z","type":"turn_context","payload":{"model":"gpt-test-codex"}}"#.to_string(),
            token_event("2026-07-08T10:00:02Z", (100, 20, 10), (100, 20, 10)),
            token_event("2026-07-08T10:00:03Z", (100, 20, 10), (100, 20, 10)),
            token_event("2026-07-08T10:00:04Z", (160, 40, 16), (60, 20, 6)),
            token_event("2026-07-08T10:00:05Z", (1000, 900, 100), (40, 30, 5)),
            token_event("2026-07-08T10:00:06Z", (1050, 930, 110), (50, 30, 10)),
            token_event("2026-07-08T10:00:07Z", (1050, 930, 110), (50, 30, 10)),
        ]
        .join("\n"),
    )
    .unwrap();

    let report = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["promptTokens"], 250);
    assert_eq!(history["cachedInputTokens"], 100);
    assert_eq!(history["completionTokens"], 31);
    assert_eq!(history["totalTokens"], 281);
}

#[test]
fn codex_usage_warm_scan_reuses_files_and_append_scan_reads_only_suffix() {
    let history_root = temp_dir("codex-usage-cache-history");
    let state_root = temp_dir("codex-usage-cache-state");
    let rollout = history_root.join("rollout.jsonl");
    fs::write(
        &rollout,
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"session-cache"}}"#.to_string(),
            token_event("2026-07-08T10:00:01Z", (6, 2, 4), (6, 2, 4)),
        ]
        .join("\n")
            + "\n",
    )
    .unwrap();
    let params = scan_params(&history_root, &state_root);

    let cold = agent_usage::scan(&params).unwrap();
    assert_eq!(
        cold["agents"][0]["history"]["scanCache"]["rescannedFiles"],
        1
    );

    let warm = agent_usage::scan(&params).unwrap();
    assert_eq!(warm["agents"][0]["history"]["scanCache"]["reusedFiles"], 1);
    assert_eq!(warm["agents"][0]["history"]["scanCache"]["parsedBytes"], 0);

    let mut file = fs::OpenOptions::new().append(true).open(&rollout).unwrap();
    writeln!(
        file,
        "{}",
        token_event("2026-07-08T10:00:02Z", (8, 2, 5), (2, 0, 1))
    )
    .unwrap();

    let appended = agent_usage::scan(&params).unwrap();
    assert_eq!(appended["agents"][0]["history"]["totalTokens"], 13);
    assert_eq!(
        appended["agents"][0]["history"]["scanCache"]["appendedFiles"],
        1
    );
}

#[test]
fn codex_usage_rewrite_to_larger_same_file_forces_full_rescan() {
    let history_root = temp_dir("codex-usage-rewrite-history");
    let state_root = temp_dir("codex-usage-rewrite-state");
    let rollout = history_root.join("rollout.jsonl");
    fs::write(
        &rollout,
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"old-session"}}"#.to_string(),
            token_event("2026-07-08T10:00:01Z", (6, 2, 4), (6, 2, 4)),
        ]
        .join("\n"),
    )
    .unwrap();
    let params = scan_params(&history_root, &state_root);
    let first = agent_usage::scan(&params).unwrap();
    assert_eq!(first["summary"]["totalTokens"], 10);
    let old_size = fs::metadata(&rollout).unwrap().len();

    let padding = "rewritten-content-".repeat(128);
    let replacement = [
        r#"{"timestamp":"2026-07-08T11:00:00Z","type":"session_meta","payload":{"id":"replacement-session"}}"#.to_string(),
        format!(
            r#"{{"timestamp":"2026-07-08T11:00:01Z","type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"{padding}"}}]}}}}"#
        ),
        token_event("2026-07-08T11:00:02Z", (15, 3, 5), (15, 3, 5)),
    ]
    .join("\n");
    fs::write(&rollout, replacement).unwrap();
    assert!(fs::metadata(&rollout).unwrap().len() > old_size);

    let rewritten = agent_usage::scan(&params).unwrap();
    let history = &rewritten["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 20);
    assert_eq!(history["scanCache"]["appendedFiles"], 0);
    assert_eq!(history["scanCache"]["rescannedFiles"], 1);
}

#[test]
fn codex_usage_detects_middle_rewrite_before_append_in_large_file() {
    let history_root = temp_dir("codex-usage-large-middle-rewrite-history");
    let state_root = temp_dir("codex-usage-large-middle-rewrite-state");
    let rollout = history_root.join("rollout.jsonl");
    let metadata = r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"large-rewrite-session"}}"#;
    let padding = json!({
        "timestamp": "2026-07-08T10:00:00Z",
        "type": "turn_context",
        "payload": {
            "model": "gpt-test-codex",
            "padding": "x".repeat(70 * 1024)
        }
    })
    .to_string();
    let original = [
        metadata.to_string(),
        padding.clone(),
        token_event("2026-07-08T10:00:01Z", (10, 4, 2), (10, 4, 2)),
        padding.clone(),
    ]
    .join("\n");
    fs::write(&rollout, original).unwrap();
    let params = scan_params(&history_root, &state_root);
    assert_eq!(
        agent_usage::scan(&params).unwrap()["summary"]["totalTokens"],
        12
    );

    let rewritten = [
        metadata.to_string(),
        padding.clone(),
        token_event("2026-07-08T10:00:01Z", (20, 4, 2), (20, 4, 2)),
        padding,
        r#"{"timestamp":"2026-07-08T10:00:02Z","type":"turn_context","payload":{"model":"gpt-test-codex"}}"#.to_string(),
    ]
    .join("\n");
    fs::write(&rollout, rewritten).unwrap();

    let report = agent_usage::scan(&params).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 22);
    assert_eq!(history["scanCache"]["appendedFiles"], 0);
    assert_eq!(history["scanCache"]["rescannedFiles"], 1);
}

#[test]
fn codex_usage_force_refresh_detects_equal_metadata_rewrite() {
    let history_root = temp_dir("codex-usage-equal-metadata-rewrite-history");
    let state_root = temp_dir("codex-usage-equal-metadata-rewrite-state");
    let rollout = history_root.join("rollout.jsonl");
    let metadata = r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"equal-metadata-session"}}"#;
    let original = [
        metadata.to_string(),
        token_event("2026-07-08T10:00:01Z", (10, 4, 2), (10, 4, 2)),
    ]
    .join("\n");
    fs::write(&rollout, &original).unwrap();
    let params = scan_params(&history_root, &state_root);
    assert_eq!(
        agent_usage::scan(&params).unwrap()["summary"]["totalTokens"],
        12
    );
    let original_metadata = fs::metadata(&rollout).unwrap();
    let original_modified = original_metadata.modified().unwrap();

    let replacement = [
        metadata.to_string(),
        token_event("2026-07-08T10:00:01Z", (20, 4, 2), (20, 4, 2)),
    ]
    .join("\n");
    assert_eq!(replacement.len(), original.len());
    fs::write(&rollout, replacement).unwrap();
    fs::File::options()
        .write(true)
        .open(&rollout)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(original_modified))
        .unwrap();
    assert_eq!(
        fs::metadata(&rollout).unwrap().len(),
        original_metadata.len()
    );

    let report = agent_usage::scan(&params).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 22);
    assert_eq!(history["scanCache"]["reusedFiles"], 0);
    assert_eq!(history["scanCache"]["rescannedFiles"], 1);
}

#[test]
fn codex_usage_applies_one_local_calendar_window_to_daily_and_total_values() {
    let history_root = temp_dir("codex-usage-window-history");
    let state_root = temp_dir("codex-usage-window-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            r#"{"timestamp":"2026-07-09T15:00:00Z","type":"session_meta","payload":{"id":"session-window"}}"#.to_string(),
            token_event("2026-07-09T15:00:01Z", (100, 20, 10), (100, 20, 10)),
            token_event("2026-07-10T16:30:00Z", (106, 20, 14), (6, 0, 4)),
        ]
        .join("\n"),
    )
    .unwrap();
    let mut params = scan_params(&history_root, &state_root);
    params["historyDays"] = json!(1);
    params["timezoneOffsetMinutes"] = json!(480);
    params["now"] = json!("2026-07-10T17:00:00Z");

    let report = agent_usage::scan(&params).unwrap();

    assert_eq!(report["summary"]["windowStart"], "2026-07-11");
    assert_eq!(report["summary"]["windowEnd"], "2026-07-11");
    assert_eq!(report["summary"]["totalTokens"], 10);
    assert_eq!(
        report["agents"][0]["history"]["dailyUsage"][0]["date"],
        "2026-07-11"
    );
}

#[test]
fn codex_usage_unions_active_and_archived_copies_by_event_identity() {
    let history_root = temp_dir("codex-usage-dedup-history");
    let state_root = temp_dir("codex-usage-dedup-state");
    let contents = [
        r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"session-copy"}}"#.to_string(),
        token_event("2026-07-08T10:00:01Z", (10, 4, 2), (10, 4, 2)),
    ]
    .join("\n");
    fs::write(history_root.join("active.jsonl"), &contents).unwrap();
    fs::write(history_root.join("archived.jsonl"), &contents).unwrap();

    let report = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &report["agents"][0]["history"];

    assert_eq!(history["sessionCount"], 1);
    assert_eq!(history["totalTokens"], 12);
    assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 1);
}

#[test]
fn codex_usage_explicit_copy_covers_estimate_from_incomplete_copy() {
    let history_root = temp_dir("codex-usage-cross-copy-coverage-history");
    let state_root = temp_dir("codex-usage-cross-copy-coverage-state");
    let metadata = r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"cross-copy-session"}}"#;
    let message = r#"{"timestamp":"2026-07-08T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"abcd"}]}}"#;
    fs::write(
        history_root.join("active.jsonl"),
        [
            metadata.to_string(),
            message.to_string(),
            token_event("2026-07-08T10:00:02Z", (6, 2, 4), (6, 2, 4)),
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        history_root.join("incomplete-archive.jsonl"),
        [metadata, message].join("\n"),
    )
    .unwrap();

    let report = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 10);
    assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 1);
    assert_eq!(history["tokenSourceBreakdown"]["estimatedRecords"], 0);
}

#[test]
fn codex_usage_noop_events_do_not_split_copy_identity() {
    let history_root = temp_dir("codex-usage-noop-copy-history");
    let state_root = temp_dir("codex-usage-noop-copy-state");
    let metadata = r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"noop-copy-session"}}"#;
    let first = token_event("2026-07-08T10:00:01Z", (10, 4, 2), (10, 4, 2));
    let second = token_event("2026-07-08T10:00:03Z", (20, 4, 4), (10, 0, 2));
    fs::write(
        history_root.join("canonical.jsonl"),
        [metadata.to_string(), first.clone(), second.clone()].join("\n"),
    )
    .unwrap();
    fs::write(
        history_root.join("copy-with-noops.jsonl"),
        [
            metadata.to_string(),
            first.clone(),
            first,
            r#"{"timestamp":"2026-07-08T10:00:02Z","type":"turn_context","payload":{"model":"gpt-test-codex"}}"#.to_string(),
            second,
        ]
        .join("\n"),
    )
    .unwrap();

    let report = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 24);
    assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 2);
}

#[test]
fn codex_usage_counts_identical_events_from_independent_sessions() {
    let history_root = temp_dir("codex-usage-independent-sessions-history");
    let state_root = temp_dir("codex-usage-independent-sessions-state");
    let event = token_event("2026-07-08T10:00:01Z", (10, 4, 2), (10, 4, 2));
    for (file_name, session_id) in [
        ("first.jsonl", "independent-first"),
        ("second.jsonl", "independent-second"),
    ] {
        fs::write(
            history_root.join(file_name),
            [
                format!(
                    r#"{{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{{"id":"{session_id}"}}}}"#
                ),
                event.clone(),
            ]
            .join("\n"),
        )
        .unwrap();
    }

    let report = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["sessionCount"], 2);
    assert_eq!(history["totalTokens"], 24);
    assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 2);
}

#[test]
fn codex_usage_does_not_advance_cache_past_an_incomplete_jsonl_line() {
    let history_root = temp_dir("codex-usage-partial-history");
    let state_root = temp_dir("codex-usage-partial-state");
    let rollout = history_root.join("rollout.jsonl");
    fs::write(
        &rollout,
        concat!(
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"session-partial"}}"#,
            "\n",
            r#"{"timestamp":"2026-07-08T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":6,"cached_input_tokens":2,"output_tokens":4},"last_token_usage":{"input_tokens":6"#
        ),
    )
    .unwrap();
    let params = scan_params(&history_root, &state_root);
    let first = agent_usage::scan(&params).unwrap();
    assert_eq!(first["summary"]["totalTokens"], 0);

    let mut file = fs::OpenOptions::new().append(true).open(&rollout).unwrap();
    writeln!(
        file,
        "{}",
        r#", "cached_input_tokens":2,"output_tokens":4}}}}"#
    )
    .unwrap();

    let completed = agent_usage::scan(&params).unwrap();
    assert_eq!(completed["agents"][0]["history"]["totalTokens"], 10);
    assert_eq!(
        completed["agents"][0]["history"]["scanCache"]["appendedFiles"],
        1
    );
}

#[test]
fn retained_reports_drop_legacy_schema_and_sort_by_timestamp() {
    let state_root = temp_dir("usage-report-migration-state");
    let store = ClientStateStore::new(state_root.clone()).unwrap();
    store
        .write_collection(
            "agent-usage-reports",
            json!({
                "items": [
                    {
                        "schemaVersion": 2,
                        "generatedAt": "2026-07-10T12:00:00Z",
                        "summary": {"totalTokens": 12},
                        "agents": []
                    },
                    {
                        "schemaVersion": 1,
                        "generatedAt": "2026-07-11T12:00:00Z",
                        "sources": {"historyRoots": ["legacy-sensitive-path"]},
                        "agents": []
                    },
                    {
                        "schemaVersion": 2,
                        "generatedAt": "2026-07-09T12:00:00Z",
                        "summary": {"totalTokens": 9},
                        "agents": []
                    }
                ]
            }),
        )
        .unwrap();

    let listed = agent_usage::report(&json!({
        "stateRoot": state_root.to_string_lossy(),
        "limit": 10
    }))
    .unwrap();
    let reports = listed["reports"].as_array().unwrap();
    assert_eq!(reports.len(), 2);
    assert_eq!(reports[0]["summary"]["totalTokens"], 12);
    assert_eq!(reports[1]["summary"]["totalTokens"], 9);

    let retained = store.read_collection("agent-usage-reports").unwrap();
    let items = retained["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert!(items.iter().all(|item| item["schemaVersion"] == 2));
    assert_eq!(items[0]["summary"]["totalTokens"], 9);
    assert_eq!(items[1]["summary"]["totalTokens"], 12);
    assert!(!retained.to_string().contains("legacy-sensitive-path"));
}

#[test]
fn codex_usage_deduplicates_forked_rollout_prefix_before_window_filtering() {
    let history_root = temp_dir("codex-usage-fork-history");
    let state_root = temp_dir("codex-usage-fork-state");
    let parent_meta = r#"{"timestamp":"2026-06-01T10:00:00Z","type":"session_meta","payload":{"id":"parent-session"}}"#;
    let parent_message = r#"{"timestamp":"2026-06-01T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"shared prefix"}]}}"#;
    let parent_context = r#"{"timestamp":"2026-06-01T10:00:02Z","type":"turn_context","payload":{"model":"gpt-test-codex"}}"#;
    fs::write(
        history_root.join("parent.jsonl"),
        [
            parent_meta.to_string(),
            parent_message.to_string(),
            parent_context.to_string(),
            token_event("2026-06-01T10:00:03Z", (100, 20, 10), (100, 20, 10)),
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        history_root.join("child.jsonl"),
        [
            r#"{"timestamp":"2026-07-10T10:00:00Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"parent-session"}}"#.to_string(),
            parent_meta.replace("2026-06-01T10:00:00Z", "2026-07-10T10:00:01Z"),
            r#"{"timestamp":"2026-07-10T10:00:02Z","type":"response_item","payload":{"type":"message","id":"fork-added-id","role":"user","content":[{"type":"input_text","text":"shared prefix"}]}}"#.to_string(),
            parent_context.replace("2026-06-01T10:00:02Z", "2026-07-10T10:00:03Z"),
            token_event("2026-07-10T10:00:04Z", (100, 20, 10), (100, 20, 10)),
            r#"{"timestamp":"2026-07-10T10:00:05Z","type":"response_item","payload":{"type":"message","id":"child-message","role":"user","content":[{"type":"input_text","text":"child branch"}]}}"#.to_string(),
            token_event("2026-07-10T10:00:06Z", (106, 20, 14), (6, 0, 4)),
        ]
        .join("\n"),
    )
    .unwrap();

    let mut params = scan_params(&history_root, &state_root);
    params["historyDays"] = json!(1);
    let recent = agent_usage::scan(&params).unwrap();
    assert_eq!(recent["summary"]["totalTokens"], 10);

    params["historyDays"] = json!(365);
    params["forceRefresh"] = json!(false);
    let all = agent_usage::scan(&params).unwrap();
    assert_eq!(all["summary"]["totalTokens"], 120);
}

#[test]
fn codex_usage_cache_keeps_independent_roots_warm() {
    let first_root = temp_dir("codex-usage-multi-root-first");
    let second_root = temp_dir("codex-usage-multi-root-second");
    let state_root = temp_dir("codex-usage-multi-root-state");
    fs::write(
        first_root.join("rollout.jsonl"),
        token_event("2026-07-08T10:00:01Z", (6, 2, 4), (6, 2, 4)),
    )
    .unwrap();
    fs::write(
        second_root.join("rollout.jsonl"),
        token_event("2026-07-08T10:00:01Z", (8, 2, 5), (8, 2, 5)),
    )
    .unwrap();
    agent_usage::scan(&scan_params(&first_root, &state_root)).unwrap();
    agent_usage::scan(&scan_params(&second_root, &state_root)).unwrap();

    let mut first_params = scan_params(&first_root, &state_root);
    first_params["forceRefresh"] = json!(false);
    let first_again = agent_usage::scan(&first_params).unwrap();
    assert_eq!(first_again["summary"]["totalTokens"], 10);
    assert_eq!(
        first_again["agents"][0]["history"]["scanCache"]["fresh"],
        true
    );
    let root_cache_count = fs::read_dir(&state_root)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("agent-usage-cache-v2-")
                && entry.path().extension().and_then(|value| value.to_str()) == Some("sqlite3")
        })
        .count();
    assert_eq!(root_cache_count, 2);
}

#[test]
fn codex_usage_returns_cached_snapshot_when_same_root_refresh_is_busy() {
    let history_root = temp_dir("codex-usage-busy-history");
    let state_root = temp_dir("codex-usage-busy-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"busy-session"}}"#.to_string(),
            token_event("2026-07-08T10:00:01Z", (6, 2, 4), (6, 2, 4)),
        ]
        .join("\n"),
    )
    .unwrap();
    let params = scan_params(&history_root, &state_root);
    assert_eq!(
        agent_usage::scan(&params).unwrap()["summary"]["totalTokens"],
        10
    );
    let database_path = fs::read_dir(&state_root)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.file_name()
                .and_then(|value| value.to_str())
                .is_some_and(|value| value.starts_with("agent-usage-cache-v2-"))
                && path.extension().and_then(|value| value.to_str()) == Some("sqlite3")
        })
        .unwrap();
    let lock = SqliteConnection::open(database_path).unwrap();
    lock.execute_batch("BEGIN IMMEDIATE").unwrap();

    let report = agent_usage::scan(&params).unwrap();
    lock.execute_batch("ROLLBACK").unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 10);
    assert_eq!(history["scanCache"]["fresh"], false);
    assert_eq!(history["scanCache"]["refreshDeferred"], true);
}

#[test]
fn codex_usage_merges_uncovered_session_estimates_with_explicit_events() {
    let history_root = temp_dir("codex-usage-mixed-coverage-history");
    let state_root = temp_dir("codex-usage-mixed-coverage-state");
    fs::write(
        history_root.join("explicit.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"explicit-session"}}"#,
            r#"{"timestamp":"2026-07-08T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ignored estimate"}]}}"#,
            &token_event("2026-07-08T10:00:02Z", (6, 2, 4), (6, 2, 4)),
        ]
        .join("\n"),
    )
    .unwrap();
    fs::write(
        history_root.join("estimated.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T11:00:00Z","type":"session_meta","payload":{"id":"estimated-session"}}"#,
            r#"{"timestamp":"2026-07-08T11:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"abcd"}]}}"#,
            r#"{"timestamp":"2026-07-08T11:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"wxyz"}]}}"#,
        ]
        .join("\n"),
    )
    .unwrap();

    let report = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 12);
    assert_eq!(history["tokenSourceBreakdown"]["explicitTotalTokens"], 10);
    assert_eq!(history["tokenSourceBreakdown"]["estimatedTotalTokens"], 2);
    assert_eq!(history["confidence"], "medium");
    assert_eq!(
        history["source"],
        "codex-local-token-events+history-estimate"
    );
}

#[test]
fn codex_usage_estimates_uncovered_tail_after_last_explicit_event() {
    let history_root = temp_dir("codex-usage-partial-session-history");
    let state_root = temp_dir("codex-usage-partial-session-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"partial-session"}}"#.to_string(),
            token_event("2026-07-08T10:00:01Z", (6, 2, 4), (6, 2, 4)),
            r#"{"timestamp":"2026-07-08T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"abcd"}]}}"#.to_string(),
            r#"{"timestamp":"2026-07-08T10:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"wxyz"}]}}"#.to_string(),
        ]
        .join("\n"),
    )
    .unwrap();

    let report = agent_usage::scan(&scan_params(&history_root, &state_root)).unwrap();
    let history = &report["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 12);
    assert_eq!(history["tokenSourceBreakdown"]["estimatedTotalTokens"], 2);
    assert_eq!(history["confidence"], "medium");
}

#[test]
fn retained_reports_persist_only_aggregate_process_metrics() {
    let history_root = temp_dir("usage-process-privacy-history");
    let state_root = temp_dir("usage-process-privacy-state");
    let mut params = scan_params(&history_root, &state_root);
    params["processSamples"] = json!([
        {
            "agentId": "codex",
            "pid": 42,
            "processName": "private-process-canary",
            "startedAt": "t0",
            "sampledAt": "t1",
            "rxBytes": 100,
            "txBytes": 200
        },
        {
            "agentId": "codex",
            "pid": 42,
            "processName": "private-process-canary",
            "startedAt": "t0",
            "sampledAt": "t2",
            "rxBytes": 150,
            "txBytes": 225
        }
    ]);

    let scanned = agent_usage::scan(&params).unwrap();
    assert_eq!(scanned["summary"]["meteredTotalBytes"], 75);
    assert!(!scanned.to_string().contains("private-process-canary"));
    assert!(scanned["agents"][0].get("processes").is_none());

    let listed = agent_usage::report(&json!({
        "stateRoot": state_root.to_string_lossy(),
        "limit": 10
    }))
    .unwrap();
    assert!(!listed.to_string().contains("private-process-canary"));
}

#[test]
fn generic_usage_extractor_keeps_cached_input_as_a_subset() {
    let history_root = temp_dir("generic-usage-cached-subset");
    fs::write(
        history_root.join("session.json"),
        json!({
            "id": "cached-session",
            "messages": [
                {
                    "role": "user",
                    "content": "question"
                },
                {
                    "role": "assistant",
                    "content": "done",
                    "usage": {
                        "input_tokens": 100,
                        "cached_input_tokens": 40,
                        "output_tokens": 10
                    }
                }
            ]
        })
        .to_string(),
    )
    .unwrap();

    let listed = conversations::conversation_list(&json!({
        "agent": "opencode",
        "root": history_root.to_string_lossy(),
        "limit": 10
    }))
    .unwrap();
    let usage = find_explicit_usage(&listed).expect("explicit usage projection");
    assert_eq!(usage["promptTokens"], 100);
    assert_eq!(usage["cachedInputTokens"], 40);
    assert_eq!(usage["completionTokens"], 10);
    assert_eq!(usage["totalTokens"], 110);
}

#[test]
fn generic_usage_extractor_projects_parent_usage_once_for_content_blocks() {
    let history_root = temp_dir("generic-usage-content-blocks");
    fs::write(
        history_root.join("session.json"),
        json!({
            "id": "content-block-session",
            "messages": [
                {"role": "user", "content": "question"},
                {
                    "role": "assistant",
                    "content": [
                        {"type": "output_text", "text": "first block"},
                        {"type": "output_text", "text": "second block"}
                    ],
                    "usage": {
                        "input_tokens": 100,
                        "cached_input_tokens": 40,
                        "output_tokens": 10
                    }
                }
            ]
        })
        .to_string(),
    )
    .unwrap();

    let listed = conversations::conversation_list(&json!({
        "agent": "opencode",
        "root": history_root.to_string_lossy(),
        "limit": 10
    }))
    .unwrap();
    let usages = explicit_usages(&listed);
    assert_eq!(usages.len(), 1, "parent usage must be projected once");
    assert_eq!(usages[0]["promptTokens"], 100);
    assert_eq!(usages[0]["cachedInputTokens"], 40);
    assert_eq!(usages[0]["completionTokens"], 10);
    assert_eq!(
        usages
            .iter()
            .filter_map(|usage| usage["totalTokens"].as_u64())
            .sum::<u64>(),
        110
    );
}

#[test]
fn generic_usage_extractor_handles_normalized_opencode_cache_and_reasoning() {
    let history_root = temp_dir("generic-usage-opencode-normalized");
    fs::write(
        history_root.join("session.json"),
        json!({
            "id": "normalized-session",
            "messages": [
                {"role": "user", "content": "question"},
                {
                    "role": "assistant",
                    "content": "done",
                    "usage": {
                        "tokens": {
                            "input": 60,
                            "output": 5,
                            "reasoning": 2,
                            "cache": {"read": 30, "write": 10}
                        }
                    }
                }
            ]
        })
        .to_string(),
    )
    .unwrap();

    let listed = conversations::conversation_list(&json!({
        "agent": "opencode",
        "root": history_root.to_string_lossy(),
        "limit": 10
    }))
    .unwrap();
    let usage = find_explicit_usage(&listed).expect("normalized usage projection");
    assert_eq!(usage["promptTokens"], 100);
    assert_eq!(usage["cachedInputTokens"], 30);
    assert_eq!(usage["completionTokens"], 7);
    assert_eq!(usage["totalTokens"], 107);
}

#[test]
fn codex_usage_applies_historical_timezone_transitions_per_event() {
    let history_root = temp_dir("codex-usage-dst-history");
    let state_root = temp_dir("codex-usage-dst-state");
    fs::write(
        history_root.join("rollout.jsonl"),
        [
            r#"{"timestamp":"2026-03-08T04:29:00Z","type":"session_meta","payload":{"id":"dst-session"}}"#.to_string(),
            token_event("2026-03-08T04:30:00Z", (6, 2, 4), (6, 2, 4)),
            token_event("2026-03-08T07:30:00Z", (8, 2, 5), (2, 0, 1)),
        ]
        .join("\n"),
    )
    .unwrap();
    let mut params = scan_params(&history_root, &state_root);
    params["historyDays"] = json!(1);
    params["now"] = json!("2026-03-08T12:00:00Z");
    params["timezoneOffsetMinutes"] = json!(-240);
    params["timezoneTransitions"] = json!([
        {"atEpochSeconds": 1772323200_i64, "offsetMinutes": -300},
        {"atEpochSeconds": 1772953200_i64, "offsetMinutes": -240}
    ]);

    let report = agent_usage::scan(&params).unwrap();
    assert_eq!(report["summary"]["totalTokens"], 3);
    assert_eq!(report["window"]["timezoneTransitionCount"], 2);
    assert_eq!(
        report["agents"][0]["history"]["dailyUsage"][0]["date"],
        "2026-03-08"
    );
}

fn find_explicit_usage(value: &Value) -> Option<&Value> {
    match value {
        Value::Object(object) => {
            if object.contains_key("promptTokens") && object.contains_key("totalTokens") {
                return Some(value);
            }
            object.values().find_map(find_explicit_usage)
        }
        Value::Array(values) => values.iter().find_map(find_explicit_usage),
        _ => None,
    }
}

fn explicit_usages(value: &Value) -> Vec<&Value> {
    let mut usages = Vec::new();
    collect_explicit_usages(value, &mut usages);
    usages
}

fn collect_explicit_usages<'a>(value: &'a Value, usages: &mut Vec<&'a Value>) {
    match value {
        Value::Object(object) => {
            if object.contains_key("promptTokens") && object.contains_key("totalTokens") {
                usages.push(value);
                return;
            }
            for child in object.values() {
                collect_explicit_usages(child, usages);
            }
        }
        Value::Array(values) => {
            for child in values {
                collect_explicit_usages(child, usages);
            }
        }
        _ => {}
    }
}

fn scan_params(history_root: &PathBuf, state_root: &PathBuf) -> Value {
    json!({
        "agent": "codex",
        "root": history_root.to_string_lossy(),
        "stateRoot": state_root.to_string_lossy(),
        "forceRefresh": true,
        "historyDays": 30,
        "now": "2026-07-10T12:00:00Z"
    })
}

fn token_event(timestamp: &str, total: (u64, u64, u64), last: (u64, u64, u64)) -> String {
    json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": total.0,
                    "cached_input_tokens": total.1,
                    "output_tokens": total.2,
                    "reasoning_output_tokens": total.2 / 2,
                    "total_tokens": total.0 + total.2
                },
                "last_token_usage": {
                    "input_tokens": last.0,
                    "cached_input_tokens": last.1,
                    "output_tokens": last.2,
                    "reasoning_output_tokens": last.2 / 2,
                    "total_tokens": last.0 + last.2
                }
            }
        }
    })
    .to_string()
}

fn temp_dir(prefix: &str) -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let path = std::env::temp_dir().join(format!("{prefix}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&path).unwrap();
    path
}
