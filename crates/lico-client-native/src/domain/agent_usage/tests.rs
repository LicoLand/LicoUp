use super::{report, scan};
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_root(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!("lico-agent-usage-{label}-{nonce}"))
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

    assert_eq!(result["schemaVersion"], 4);
    assert_eq!(result["mode"], "local-token-usage");
    assert_eq!(result["tokenSourceMode"], "local-history");
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
    assert_eq!(listed["schemaVersion"], 4);
    assert_eq!(listed["mode"], "local-token-usage");
    assert_eq!(listed["tokenSourceMode"], "local-history");
    let reports = listed["reports"].as_array().map(Vec::len).unwrap_or(0);
    assert_eq!(reports, 1);

    fs::remove_dir_all(history_root).unwrap();
    fs::remove_dir_all(state_root).unwrap();
}

#[test]
fn command_kimi_code_keeps_exact_turn_usage_and_model_dimension() {
    let history_root = temp_root("kimi-code-history");
    let wire = history_root.join("work/session/agents/main/wire.jsonl");
    fs::create_dir_all(wire.parent().unwrap()).unwrap();
    fs::write(
        wire,
        [
            r#"{"type":"context.append_message","time":"2026-07-10T10:00:00Z","message":{"role":"user","content":"local prompt covered by explicit turn usage"}}"#,
            r#"{"type":"usage.record","time":"2026-07-10T10:00:01Z","model":"kimi-code/kimi-for-coding","usageScope":"turn","usage":{"inputOther":100,"inputCacheRead":20,"inputCacheCreation":5,"output":30}}"#,
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
    assert_eq!(history["promptTokens"], 125);
    assert_eq!(history["cachedInputTokens"], 20);
    assert_eq!(history["completionTokens"], 30);
    assert_eq!(history["totalTokens"], 155);
    assert_eq!(
        history["dailyUsage"][0]["modelUsage"]["kimi-code/kimi-for-coding"],
        155
    );
    assert_eq!(
        history["dailyUsage"][0]["modelTokenUsage"]["kimi-code/kimi-for-coding"]["cachedInputTokens"],
        20
    );
    fs::remove_dir_all(history_root).unwrap();
    fs::remove_dir_all(state_root).unwrap();
}
