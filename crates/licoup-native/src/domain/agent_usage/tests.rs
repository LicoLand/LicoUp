use super::{report, scan};
use rusqlite::Connection;
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

fn temp_root(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!("lico-agent-usage-{label}-{nonce}"))
}

fn epoch(value: &str) -> f64 {
    OffsetDateTime::parse(value, &Rfc3339)
        .unwrap()
        .unix_timestamp() as f64
}

fn write_usage_history(root: &PathBuf) {
    fs::create_dir_all(root).unwrap();
    fs::write(
        root.join("session.json"),
        json!({
            "id": "local-session",
            "model": "local-model-a",
            "messages": [
                {
                    "role": "user",
                    "text": "private-local-prompt-canary",
                    "createdAt": "2026-07-01T10:00:00Z"
                },
                {
                    "role": "assistant",
                    "text": "private-local-response-canary",
                    "createdAt": "2026-07-01T10:00:01Z",
                    "model": "local-model-a",
                    "usage": {
                        "prompt_tokens": 11,
                        "cached_input_tokens": 4,
                        "completion_tokens": 7,
                        "total_tokens": 18
                    }
                }
            ]
        })
        .to_string(),
    )
    .unwrap();
}

#[test]
fn command_scan_keeps_schema_modes_dimensions_and_privacy_boundary() {
    let history_root = temp_root("command-history");
    let state_root = temp_root("command-state");
    write_usage_history(&history_root);
    let result = scan(&json!({
        "agent": "opencode",
        "root": history_root.to_string_lossy(),
        "stateRoot": state_root.to_string_lossy(),
        "now": "2026-07-15T12:00:00Z"
    }))
    .unwrap();

    assert_eq!(result["schemaVersion"], 6);
    assert_eq!(result["mode"], "local-token-usage");
    assert_eq!(
        result["tokenSourceMode"],
        "native-metadata-first-incremental"
    );
    assert_eq!(result["window"]["days"], 30);
    assert_eq!(result["agents"][0]["agentId"], "opencode");
    assert_eq!(result["agents"][0]["history"]["totalTokens"], 18);
    let model_total = result["agents"][0]["history"]["dailyUsage"][0]["modelUsage"]
        .as_object()
        .map(|usage| usage.values().filter_map(Value::as_u64).sum::<u64>())
        .unwrap_or(0);
    assert_eq!(model_total, 18);
    let serialized = serde_json::to_string(&result).unwrap();
    assert!(!serialized.contains("private-local-prompt-canary"));
    assert!(!serialized.contains("private-local-response-canary"));
    assert!(!serialized.contains(&history_root.to_string_lossy().to_string()));

    fs::remove_dir_all(history_root).unwrap();
    fs::remove_dir_all(state_root).unwrap();
}

#[test]
fn command_custom_window_and_retained_report_close_independently() {
    let history_root = temp_root("window-history");
    let state_root = temp_root("window-state");
    write_usage_history(&history_root);
    let params = json!({
        "agent": "opencode",
        "root": history_root.to_string_lossy(),
        "stateRoot": state_root.to_string_lossy(),
        "historyDays": 7,
        "now": "2026-07-15T12:00:00Z"
    });
    let result = scan(&params).unwrap();
    assert_eq!(result["summary"]["windowDays"], 7);
    assert_eq!(result["summary"]["windowStart"], "2026-07-09");
    assert_eq!(result["summary"]["totalTokens"], 0);

    let listed = report(&json!({
        "agent": "opencode",
        "stateRoot": state_root.to_string_lossy(),
        "limit": 1
    }))
    .unwrap();
    assert_eq!(listed["schemaVersion"], 6);
    assert_eq!(listed["mode"], "local-token-usage");
    assert_eq!(
        listed["tokenSourceMode"],
        "native-metadata-first-incremental"
    );
    let reports = listed["reports"].as_array().map(Vec::len).unwrap_or(0);
    assert_eq!(reports, 1);

    fs::remove_dir_all(history_root).unwrap();
    fs::remove_dir_all(state_root).unwrap();
}

#[test]
fn command_kimi_code_keeps_exact_turn_and_session_usage_with_model_dimension() {
    let history_root = temp_root("kimi-code-history");
    let wire = history_root.join("work/session/agents/main/wire.jsonl");
    fs::create_dir_all(wire.parent().unwrap()).unwrap();
    fs::write(
        wire,
        [
            r#"{"type":"context.append_message","time":"2026-07-10T10:00:00Z","message":{"role":"user","content":"local prompt covered by explicit turn usage"}}"#,
            r#"{"type":"usage.record","time":"2026-07-10T10:00:01Z","model":"kimi-code/kimi-for-coding","usageScope":"turn","usage":{"inputOther":100,"inputCacheRead":20,"inputCacheCreation":5,"output":30}}"#,
            r#"{"type":"usage.record","time":"2026-07-10T10:00:02Z","model":"kimi-code/kimi-for-coding","usageScope":"session","usage":{"inputOther":40,"inputCacheRead":10,"inputCacheCreation":3,"output":12}}"#,
        ]
        .join("\n"),
    )
    .unwrap();
    let state_root = temp_root("kimi-code-state");
    let result = scan(&json!({
        "agent": "kimi-code",
        "root": history_root.to_string_lossy(),
        "stateRoot": state_root.to_string_lossy(),
        "now": "2026-07-10T12:00:00Z"
    }))
    .unwrap();
    let history = &result["agents"][0]["history"];
    assert_eq!(history["promptTokens"], 178);
    assert_eq!(history["cachedInputTokens"], 30);
    assert_eq!(history["completionTokens"], 42);
    assert_eq!(history["totalTokens"], 220);
    assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 2);
    assert_eq!(
        history["dailyUsage"][0]["modelUsage"]["kimi-code/kimi-for-coding"],
        220
    );
    assert_eq!(
        history["dailyUsage"][0]["modelTokenUsage"]["kimi-code/kimi-for-coding"]["cachedInputTokens"],
        30
    );
    fs::remove_dir_all(history_root).unwrap();
    fs::remove_dir_all(state_root).unwrap();
}

#[test]
fn command_kimi_desktop_does_not_present_history_text_as_consumption() {
    let history_root = temp_root("kimi-desktop-history");
    let state_root = temp_root("kimi-desktop-state");
    fs::create_dir_all(&history_root).unwrap();
    fs::write(
        history_root.join("session.json"),
        json!({
            "id": "synthetic-kimi-session",
            "model": "kimi-test",
            "messages": [
                {
                    "role": "user",
                    "text": "history text is not a provider token counter",
                    "createdAt": "2026-07-10T10:00:00Z"
                },
                {
                    "role": "assistant",
                    "text": "response text must not be presented as consumption",
                    "createdAt": "2026-07-10T10:00:01Z"
                }
            ]
        })
        .to_string(),
    )
    .unwrap();

    let result = scan(&json!({
        "agent": "kimi",
        "root": history_root.to_string_lossy(),
        "stateRoot": state_root.to_string_lossy(),
        "now": "2026-07-10T12:00:00Z"
    }))
    .unwrap();
    let history = &result["agents"][0]["history"];
    assert_eq!(history["totalTokens"], 0);
    assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 0);
    assert_eq!(history["tokenSourceBreakdown"]["estimatedRecords"], 0);
    assert_eq!(result["agents"][0]["confidence"], "unavailable");

    fs::write(
        history_root.join("exact-session.json"),
        json!({
            "id": "synthetic-kimi-exact-session",
            "model": "kimi-test",
            "messages": [
                {
                    "role": "assistant",
                    "text": "native counters remain visible",
                    "createdAt": "2026-07-10T10:01:00Z",
                    "usage": {
                        "prompt_tokens": 11,
                        "cached_input_tokens": 4,
                        "completion_tokens": 7,
                        "total_tokens": 18
                    }
                }
            ]
        })
        .to_string(),
    )
    .unwrap();
    let refreshed = scan(&json!({
        "agent": "kimi",
        "root": history_root.to_string_lossy(),
        "stateRoot": state_root.to_string_lossy(),
        "forceRefresh": true,
        "now": "2026-07-10T12:00:00Z"
    }))
    .unwrap();
    let refreshed_history = &refreshed["agents"][0]["history"];
    assert_eq!(refreshed_history["totalTokens"], 18);
    assert_eq!(
        refreshed_history["tokenSourceBreakdown"]["explicitRecords"],
        1
    );
    assert_eq!(
        refreshed_history["tokenSourceBreakdown"]["estimatedRecords"],
        0
    );
    assert_eq!(refreshed["agents"][0]["confidence"], "high");

    fs::remove_dir_all(history_root).unwrap();
    fs::remove_dir_all(state_root).unwrap();
}

#[test]
fn command_hermes_uses_reconciled_gateway_counters_without_text_estimates() {
    let history_root = temp_root("hermes-gateway-history");
    let state_root = temp_root("hermes-gateway-state");
    fs::create_dir_all(&history_root).unwrap();
    let database = history_root.join("state.db");
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                model TEXT,
                started_at REAL NOT NULL,
                ended_at REAL,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                cache_write_tokens INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE messages (
                session_id TEXT NOT NULL,
                timestamp REAL NOT NULL
            );
            CREATE INDEX messages_session_timestamp
                ON messages(session_id, timestamp);
            CREATE TABLE session_model_usage (
                session_id TEXT NOT NULL,
                model TEXT NOT NULL,
                billing_provider TEXT NOT NULL DEFAULT '',
                billing_base_url TEXT NOT NULL DEFAULT '',
                billing_mode TEXT NOT NULL DEFAULT '',
                task TEXT NOT NULL DEFAULT '',
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                cache_write_tokens INTEGER NOT NULL DEFAULT 0,
                reasoning_tokens INTEGER NOT NULL DEFAULT 0,
                first_seen REAL,
                last_seen REAL,
                PRIMARY KEY (
                    session_id, model, billing_provider,
                    billing_base_url, billing_mode, task
                )
            );",
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO sessions VALUES (?1, 'gateway', ?2, ?3, NULL, 25, 12, 4, 1)",
            rusqlite::params![
                "synthetic-session",
                "hermes-test",
                epoch("2026-07-15T09:59:00Z")
            ],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO messages VALUES (?1, ?2)",
            rusqlite::params!["synthetic-session", epoch("2026-07-15T10:00:04Z")],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO session_model_usage VALUES
                (?1, ?2, '', '', '', '', 10, 5, 2, 0, 1, ?3, ?4),
                (?1, ?2, '', '', '', 'compression', 7, 3, 1, 0, 2, ?5, ?6)",
            rusqlite::params![
                "synthetic-session",
                "hermes-test",
                epoch("2026-07-15T10:00:00Z"),
                epoch("2026-07-15T10:00:01Z"),
                epoch("2026-07-15T10:00:02Z"),
                epoch("2026-07-15T10:00:03Z")
            ],
        )
        .unwrap();
    drop(connection);

    let result = scan(&json!({
        "agent": "hermes",
        "root": history_root.to_string_lossy(),
        "stateRoot": state_root.to_string_lossy(),
        "now": "2026-07-15T12:00:00Z"
    }))
    .unwrap();
    let history = &result["agents"][0]["history"];
    assert_eq!(history["promptTokens"], 30);
    assert_eq!(history["cachedInputTokens"], 4);
    assert_eq!(history["completionTokens"], 12);
    assert_eq!(history["totalTokens"], 42);
    assert_eq!(history["sessionCount"], 1);
    assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 2);
    assert_eq!(history["tokenSourceBreakdown"]["estimatedRecords"], 0);
    assert_eq!(history["source"], "hermes-gateway-usage-database");
    assert_eq!(history["dailyUsage"][0]["modelUsage"]["hermes-test"], 42);
    assert_eq!(result["agents"][0]["confidence"], "high");

    fs::remove_dir_all(history_root).unwrap();
    fs::remove_dir_all(state_root).unwrap();
}
