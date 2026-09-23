//! The new transaction adapter on the same old database.
//!
//! The file these tests open is written by the test, not by the crate under
//! test: the fixture schema below is a transcription of what the production
//! store's own open path leaves behind, and the rows in it are the rows that
//! store writes. That is deliberate. A fixture built by calling the new crate's
//! `initialize` would prove only that the crate agrees with itself, and the
//! question here is whether it agrees with the writer that already owns the
//! user's data.
//!
//! The transcription is taken from `licoup_native::domain::workflow_store` at
//! this task's base revision: `store.rs::initialize_schema_through` (the
//! `strategy_*` tables plus the columns its `ensure_column` backfills add to a
//! fresh file), `commit.rs::initialize_schema` (the old transition-intent
//! outbox), `subscriptions.rs::initialize_schema` (the subscription table in
//! its full nine-column shape, so a consumer that validates that table sees the
//! real one), and `queue.rs::initialize_schema`'s meta table. Those last groups
//! matter here for a negative reason: the adapter must leave them, and their
//! rows, exactly alone.

use anyhow::Result;
use licoup_workflow::{
    CommandKind, CommandStatus, RunCommand, RunSnapshot, SessionPolicy, StrategyRunStatus,
};
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_store::transactions::{StoreStatePort, WorkflowDatabase};
use rusqlite::Connection;
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;

use crate::support;

/// What the production store's open path leaves on disk.
const PRODUCTION_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS strategy_meta(
  key TEXT PRIMARY KEY, value TEXT NOT NULL
);
INSERT INTO strategy_meta(key, value) VALUES ('version', '3')
  ON CONFLICT(key) DO NOTHING;
CREATE TABLE IF NOT EXISTS strategy_definitions(
  definition_id TEXT NOT NULL,
  revision_digest TEXT PRIMARY KEY,
  semantics_digest TEXT NOT NULL,
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  workflow_json TEXT NOT NULL,
  asset_count INTEGER NOT NULL,
  imported_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS strategy_definitions_id_idx
  ON strategy_definitions(definition_id, imported_at DESC);
CREATE TABLE IF NOT EXISTS strategy_bindings(
  revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest) ON DELETE CASCADE,
  slot_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL DEFAULT 0,
  value_id TEXT NOT NULL,
  model TEXT NOT NULL DEFAULT '',
  reasoning_effort TEXT NOT NULL DEFAULT '',
  revision INTEGER NOT NULL,
  PRIMARY KEY(revision_digest, slot_id, ordinal)
);
CREATE TABLE IF NOT EXISTS strategy_authorizations(
  revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest) ON DELETE CASCADE,
  revision INTEGER NOT NULL,
  semantics_digest TEXT NOT NULL,
  binding_digest TEXT NOT NULL,
  authorization_digest TEXT NOT NULL,
  active INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(revision_digest, revision)
);
CREATE UNIQUE INDEX IF NOT EXISTS strategy_authorization_active_idx
  ON strategy_authorizations(revision_digest) WHERE active=1;
CREATE TABLE IF NOT EXISTS strategy_runs(
  run_id TEXT PRIMARY KEY,
  revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest),
  semantics_digest TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  request_digest TEXT NOT NULL,
  snapshot_json TEXT NOT NULL,
  conversation_id TEXT,
  terminal INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS strategy_runs_revision_idx
  ON strategy_runs(revision_digest, updated_at DESC);
CREATE INDEX IF NOT EXISTS strategy_runs_active_conversation_idx
  ON strategy_runs(revision_digest, conversation_id, terminal, updated_at DESC);
CREATE TABLE IF NOT EXISTS strategy_run_events(
  run_id TEXT NOT NULL REFERENCES strategy_runs(run_id) ON DELETE CASCADE,
  sequence INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  event_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(run_id, sequence)
);
CREATE TABLE IF NOT EXISTS strategy_commands(
  command_id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES strategy_runs(run_id) ON DELETE CASCADE,
  state_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  attempt_token TEXT NOT NULL,
  command_json TEXT NOT NULL,
  lease_owner TEXT,
  lease_until INTEGER,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS strategy_commands_ready_idx
  ON strategy_commands(status, command_id);
CREATE INDEX IF NOT EXISTS strategy_commands_lease_idx
  ON strategy_commands(lease_until) WHERE status IN ('claimed', 'running');
CREATE TABLE IF NOT EXISTS workflow_transition_intents(
  run_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  event_json TEXT NOT NULL,
  before_json TEXT NOT NULL,
  after_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending', 'dispatched')),
  created_at INTEGER NOT NULL,
  dispatched_at INTEGER,
  PRIMARY KEY(run_id, sequence)
);
CREATE INDEX IF NOT EXISTS workflow_transition_intents_pending_idx
  ON workflow_transition_intents(status, created_at);
CREATE TABLE IF NOT EXISTS workflow_queue_meta(
  key TEXT PRIMARY KEY, value INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS workflow_subscriptions(
  subscription_id TEXT PRIMARY KEY,
  subscriber_id TEXT NOT NULL,
  scope_json TEXT NOT NULL,
  predicate_json TEXT NOT NULL,
  activation_json TEXT NOT NULL,
  durable_cursor INTEGER NOT NULL,
  is_control INTEGER NOT NULL,
  active INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS workflow_subscriptions_cursor_idx
  ON workflow_subscriptions(active, durable_cursor);
";

/// The revision the old writer registered, and the run it admitted.
pub const REVISION: &str = "revision-old-writer";
pub const SEMANTICS: &str = "semantics-old-writer";
/// The timestamp the old writer recorded, so a rewritten row would be visible.
const OLD_TIMESTAMP: i64 = 1_700_000_000_000;

pub fn old_command() -> RunCommand {
    RunCommand {
        id: "command-old-1".into(),
        state_id: "work".into(),
        state_visit: 1,
        kind: CommandKind::Actor,
        status: CommandStatus::Pending,
        attempt: 1,
        attempt_token: "attempt-old-1".into(),
        binding_id: Some("worker".into()),
        runtime_id: None,
        entry: None,
        item_id: None,
        session_policy: SessionPolicy::default(),
        binding_ordinal: 0,
        resume_session_id: None,
        input_digest: "digest-old-1".into(),
        input: json!({"input": "synthetic"}),
        output_digest: None,
        failure_class: None,
        failure_code: None,
    }
}

/// The checkpoint the production store holds one event into a run: running,
/// sequence 1, one pending actor command.
pub fn old_snapshot() -> RunSnapshot {
    let mut snapshot = RunSnapshot::empty("run-old", REVISION, SEMANTICS);
    snapshot.status = StrategyRunStatus::Running;
    snapshot.sequence = 1;
    snapshot.active_states.insert("work".into());
    snapshot.state_visits.insert("work".into(), 1);
    snapshot.conversation_id = Some("conversation-old".into());
    snapshot
        .commands
        .insert("command-old-1".into(), old_command());
    snapshot
}

/// Write a database the production store could have written.
fn write_old_database(label: &str) -> Result<PathBuf> {
    let path = support::scratch_path(label);
    support::remove_database(&path);
    let connection = Connection::open(&path)?;
    connection.execute_batch(PRODUCTION_SCHEMA)?;

    let workflow = support::actor_workflow(2);
    let snapshot = old_snapshot();
    let admitted = RunSnapshot::empty("run-old", REVISION, SEMANTICS);
    let event = serde_json::to_string(&support::start_event())?;
    let event_type = event.split('"').nth(3).unwrap_or("event").to_owned();
    connection.execute(
        "INSERT INTO strategy_definitions(
           definition_id, revision_digest, semantics_digest, name, version,
           workflow_json, asset_count, imported_at
         ) VALUES ('old-writer-fixture', ?1, ?2, 'Old writer fixture', '1', ?3, 7, ?4)",
        rusqlite::params![
            REVISION,
            SEMANTICS,
            serde_json::to_string(&workflow)?,
            OLD_TIMESTAMP
        ],
    )?;
    connection.execute(
        "INSERT INTO strategy_runs(
           run_id, revision_digest, semantics_digest, idempotency_key, request_digest,
           snapshot_json, conversation_id, terminal, created_at, updated_at
         ) VALUES ('run-old', ?1, ?2, 'old-idempotency', 'old-request', ?3,
                   'conversation-old', 0, ?4, ?4)",
        rusqlite::params![
            REVISION,
            SEMANTICS,
            serde_json::to_string(&snapshot)?,
            OLD_TIMESTAMP
        ],
    )?;
    connection.execute(
        "INSERT INTO strategy_run_events(run_id, sequence, event_type, event_json, created_at)
         VALUES ('run-old', 1, ?1, ?2, ?3)",
        rusqlite::params![event_type, event, OLD_TIMESTAMP],
    )?;
    connection.execute(
        "INSERT INTO strategy_commands(
           command_id, run_id, state_id, kind, status, attempt, attempt_token,
           command_json, lease_owner, lease_until, updated_at
         ) VALUES ('command-old-1', 'run-old', 'work', 'actor', 'pending', 1,
                   'attempt-old-1', ?1, NULL, NULL, ?2)",
        rusqlite::params![serde_json::to_string(&old_command())?, OLD_TIMESTAMP],
    )?;
    connection.execute(
        "INSERT INTO workflow_transition_intents(
           run_id, sequence, event_json, before_json, after_json, status, created_at, dispatched_at
         ) VALUES ('run-old', 1, ?1, ?2, ?3, 'pending', ?4, NULL)",
        rusqlite::params![
            event,
            serde_json::to_string(&admitted)?,
            serde_json::to_string(&snapshot)?,
            OLD_TIMESTAMP
        ],
    )?;
    connection.execute(
        "INSERT INTO workflow_subscriptions(
           subscription_id, subscriber_id, scope_json, predicate_json, activation_json,
           durable_cursor, is_control, active, created_at
         ) VALUES ('subscription-old', 'subscriber-old', '{}', '{}', '{}', 3, 0, 1, ?1)",
        rusqlite::params![OLD_TIMESTAMP],
    )?;
    drop(connection);
    Ok(path)
}

fn column(database: &WorkflowDatabase, sql: &str) -> Vec<String> {
    database
        .read(|connection| {
            let mut statement = connection.prepare(sql)?;
            let values = statement
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(values)
        })
        .expect("fixture query runs")
}

/// Read one column with a plain connection, before the adapter has ever seen
/// the file.
fn raw_column(connection: &Connection, sql: &str) -> Vec<String> {
    let mut statement = connection.prepare(sql).expect("fixture query prepares");
    statement
        .query_map([], |row| row.get::<_, String>(0))
        .expect("fixture query runs")
        .collect::<rusqlite::Result<Vec<_>>>()
        .expect("fixture rows read")
}

#[test]
fn the_adapter_reads_and_advances_a_run_the_production_store_wrote() {
    let path = write_old_database("old-run").expect("fixture database");
    // Everything the old writer left, read before the adapter opens the file:
    // these are the rows and tables that must come out unchanged.
    let before = {
        let connection = Connection::open(&path).expect("fixture opens");
        (
            raw_column(
                &connection,
                "SELECT run_id || ':' || sequence || ':' || status FROM workflow_transition_intents",
            ),
            raw_column(
                &connection,
                "SELECT subscription_id || ':' || subscriber_id || ':' || durable_cursor || ':' || active FROM workflow_subscriptions",
            ),
            raw_column(
                &connection,
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
            ),
            raw_column(
                &connection,
                "SELECT CAST(COUNT(*) AS TEXT) FROM strategy_run_events WHERE run_id='run-old'",
            ),
            raw_column(
                &connection,
                "SELECT CAST(COUNT(*) AS TEXT) FROM strategy_definitions",
            ),
        )
    };

    let database = Arc::new(WorkflowDatabase::open(&path).expect("an old database opens"));
    let port = StoreStatePort::new(database.clone());

    // Reading: the old writer's checkpoint, history, and command are visible.
    let checkpoint = port
        .checkpoint("run-old")
        .expect("the old checkpoint reads");
    assert_eq!(checkpoint.run_id, "run-old");
    assert_eq!(checkpoint.sequence, 1);
    assert_eq!(
        checkpoint.conversation_id.as_deref(),
        Some("conversation-old")
    );
    assert_eq!(checkpoint.status, StrategyRunStatus::Running);
    assert!(support::event_body(&database, "run-old", 1).is_some());
    assert_eq!(
        port.result_ref("run-old", "command-old-1")
            .expect("the old command reads"),
        None,
        "a command with no recorded outcome answers None, not an error"
    );

    // Writing: the old writer's pending command is claimable by the new
    // adapter, and the claim advances the old run's checkpoint.
    let claimed = port
        .claim_next("run-old", "host-1", support::future_ms())
        .expect("the old pending command is claimable")
        .expect("the old pending command is found");
    assert_eq!(claimed.id, "command-old-1");
    assert_eq!(claimed.attempt_token, "attempt-old-1");
    assert_eq!(claimed.status, CommandStatus::Claimed);
    let after = port
        .checkpoint("run-old")
        .expect("the advanced checkpoint reads");
    assert_eq!(after.sequence, 2);

    // Nothing the production store owns was rewritten: its transition intent,
    // subscription cursor, definition row, and history rows are as they were.
    assert_eq!(
        column(
            &database,
            "SELECT run_id || ':' || sequence || ':' || status FROM workflow_transition_intents"
        ),
        before.0
    );
    assert_eq!(
        column(
            &database,
            "SELECT subscription_id || ':' || subscriber_id || ':' || durable_cursor || ':' || active FROM workflow_subscriptions"
        ),
        before.1
    );
    assert_eq!(
        support::count(&database, "strategy_definitions", "1=1").to_string(),
        before.4[0]
    );
    assert_eq!(
        support::count(&database, "strategy_run_events", "run_id='run-old'"),
        before.3[0].parse::<i64>().expect("a count") + 1,
        "the claim appended one history row and left the old one in place"
    );
    assert_eq!(
        column(
            &database,
            "SELECT status || ':' || COALESCE(lease_owner, '') FROM strategy_commands
             WHERE command_id='command-old-1'"
        ),
        vec!["claimed:host-1".to_owned()]
    );

    // Opening an existing database adds the adapter's own tables and nothing
    // else.
    let added: Vec<String> = column(
        &database,
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    )
    .into_iter()
    .filter(|table| !before.2.contains(table))
    .collect();
    assert_eq!(
        added,
        vec![
            "workflow_notice_acceptances".to_owned(),
            "workflow_notice_intents".to_owned(),
        ]
    );

    drop(database);
    support::remove_database(&path);
}

#[test]
fn a_database_from_a_different_version_is_refused_rather_than_migrated() {
    let path = write_old_database("old-version").expect("fixture database");
    {
        let connection = Connection::open(&path).expect("fixture opens");
        connection
            .execute("UPDATE strategy_meta SET value='2' WHERE key='version'", [])
            .expect("the version is moved to an older one");
    }
    let error = WorkflowDatabase::open(&path)
        .expect_err("an unimplemented version is refused")
        .to_string();
    assert!(
        error.starts_with("workflow_store_schema_version_unsupported"),
        "unexpected error: {error}"
    );
    // Refusing must not have moved the file's version as a side effect.
    let connection = Connection::open(&path).expect("fixture still opens");
    let version: String = connection
        .query_row(
            "SELECT value FROM strategy_meta WHERE key='version'",
            [],
            |row| row.get(0),
        )
        .expect("version row");
    assert_eq!(version, "2");
    drop(connection);
    support::remove_database(&path);
}

#[test]
fn a_database_missing_a_column_the_adapter_needs_is_refused_by_name() {
    let path = write_old_database("old-column").expect("fixture database");
    {
        let connection = Connection::open(&path).expect("fixture opens");
        connection
            .execute("ALTER TABLE strategy_run_events DROP COLUMN event_type", [])
            .expect("the column is dropped");
    }
    let error = WorkflowDatabase::open(&path)
        .expect_err("a missing column is refused")
        .to_string();
    assert!(
        error.contains("strategy_run_events.event_type"),
        "unexpected: {error}"
    );
    support::remove_database(&path);
}
