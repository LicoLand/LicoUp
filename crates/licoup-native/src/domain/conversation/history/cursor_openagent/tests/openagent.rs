use rusqlite::Connection;
use serde_json::json;

use super::super::openagent::{
    openagent_json_time, openagent_session_rows, openagent_usage_from_columns,
};

#[test]
fn openagent_session_rows_and_usage_projection_remain_additive() {
    let connection = Connection::open_in_memory().expect("database");
    connection
        .execute_batch(
            "CREATE TABLE session (
                id TEXT, title TEXT, directory TEXT, path TEXT, agent TEXT, model TEXT,
                time_created INTEGER, time_updated INTEGER, tokens_input INTEGER,
                tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER,
                tokens_cache_write INTEGER
             );
             INSERT INTO session VALUES (
                'session-1', 'Title', 'work', 'project', 'build', 'model-a',
                1773798000000, 1773798100000, 60, 5, 2, 30, 10
             );",
        )
        .expect("fixture");
    assert_eq!(openagent_session_rows(&connection).len(), 1);

    let usage = openagent_usage_from_columns(Some(60), Some(5), Some(2), Some(30), Some(10))
        .expect("usage");
    assert_eq!(usage["promptTokens"], 100);
    assert_eq!(usage["completionTokens"], 7);
    assert_eq!(usage["totalTokens"], 107);
}

#[test]
fn openagent_nested_time_projection_accepts_epoch_values() {
    assert!(
        openagent_json_time(
            &json!({"time": {"created": 1_773_798_000_000i64}}),
            "created"
        )
        .is_some()
    );
    assert!(openagent_json_time(&json!({}), "created").is_none());
}
