use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use super::super::constants::CACHE_DATABASE_PREFIX;

pub(super) fn temp_dir(name: &str) -> PathBuf {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let dir = std::env::temp_dir().join(format!(
        "lico-codex-usage-{name}-{}-{}-{}",
        std::process::id(),
        now.as_secs(),
        now.subsec_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

pub(super) fn scan_params(history_root: &Path, state_root: &Path) -> Value {
    json!({
        "agent": "codex",
        "root": history_root.to_string_lossy(),
        "stateRoot": state_root.to_string_lossy(),
        "forceRefresh": true,
        "historyDays": 30,
        "now": "2026-07-10T12:00:00Z"
    })
}

pub(super) fn codex_database_path(state_root: &Path) -> PathBuf {
    let database_prefix = format!("{CACHE_DATABASE_PREFIX}-");
    fs::read_dir(state_root)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.extension().and_then(|value| value.to_str()) == Some("sqlite3")
                && path
                    .file_name()
                    .and_then(|value| value.to_str())
                    .is_some_and(|value| value.starts_with(&database_prefix))
        })
        .unwrap()
}

pub(super) fn token_event(
    timestamp: &str,
    total: (u64, u64, u64),
    last: (u64, u64, u64),
) -> String {
    json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": total.0,
                    "cached_input_tokens": total.1,
                    "output_tokens": total.2
                },
                "last_token_usage": {
                    "input_tokens": last.0,
                    "cached_input_tokens": last.1,
                    "output_tokens": last.2
                }
            }
        }
    })
    .to_string()
}
