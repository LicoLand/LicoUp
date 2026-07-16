pub(super) use super::super::*;
pub(super) use crate::domain::conversation::paths::{expand_home_from, home_dir_from_env};
pub(super) use std::env;
pub(super) use std::ffi::OsString;
pub(super) use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn create_openagent_fixture_database(path: &Path, prompt: &str) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute(
            "CREATE TABLE session (
                id TEXT PRIMARY KEY,
                title TEXT,
                directory TEXT,
                path TEXT,
                agent TEXT,
                model TEXT,
                time_created INTEGER,
                time_updated INTEGER,
                tokens_input INTEGER,
                tokens_output INTEGER,
                tokens_reasoning INTEGER,
                tokens_cache_read INTEGER,
                tokens_cache_write INTEGER
            )",
            [],
        )
        .unwrap();
    connection
        .execute(
            "CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER,
                time_updated INTEGER,
                data TEXT NOT NULL
            )",
            [],
        )
        .unwrap();
    connection
        .execute(
            "CREATE TABLE part (
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                time_created INTEGER,
                time_updated INTEGER,
                data TEXT NOT NULL
            )",
            [],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO session VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            (
                "ses_fixture",
                prompt,
                "/workspace/opencode",
                "/workspace/opencode",
                "build",
                "gpt-test",
                1_787_616_000_000i64,
                1_787_616_060_000i64,
                10i64,
                20i64,
                0i64,
                1i64,
                2i64,
            ),
        )
        .unwrap();
    for (id, role, text, offset) in [
        ("msg_user", "user", prompt, 1_000i64),
        ("msg_agent", "assistant", "OpenCode answer", 2_000i64),
    ] {
        connection
            .execute(
                "INSERT INTO message VALUES (?1, ?2, ?3, ?4, ?5)",
                (
                    id,
                    "ses_fixture",
                    1_787_616_000_000i64 + offset,
                    1_787_616_000_000i64 + offset,
                    serde_json::to_string(&json!({
                        "role": role,
                        "time": {"created": 1_787_616_000_000i64 + offset},
                        "tokens": {"total": 3, "input": 1, "output": 2}
                    }))
                    .unwrap(),
                ),
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO part VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                (
                    format!("part_{id}"),
                    id,
                    "ses_fixture",
                    1_787_616_000_000i64 + offset,
                    1_787_616_000_000i64 + offset,
                    serde_json::to_string(&json!({"type": "text", "text": text})).unwrap(),
                ),
            )
            .unwrap();
    }
}

pub(super) fn temp_dir(name: &str) -> PathBuf {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = env::temp_dir().join(format!("licoarc-client-{}-{}", name, now));
    fs::create_dir_all(&dir).unwrap();
    dir
}
