//! The on-disk format the transaction adapter reads and writes.
//!
//! ## One database, two writers
//!
//! The production store — `licoup_native::domain::workflow_store::StrategyStore`
//! — owns this database today. This crate is the storage side of the *same*
//! facts, so it has to run on a file that store already wrote: that is what a
//! new transaction adapter on the same old database means. Three rules keep it
//! true.
//!
//! 1. [`initialize`] creates the same logical schema, complete enough that the
//!    production store can open what this crate creates.
//! 2. [`prepare`] on an existing file validates and then only *adds* the two
//!    tables this adapter owns ([`NOTICE_SCHEMA`]). It never alters, rewrites,
//!    or deletes a table the production store owns, and never touches a row the
//!    production store wrote.
//! 3. A file whose declared version this module does not implement is refused
//!    with `workflow_store_schema_version_unsupported`. It is not migrated
//!    here: migrating a user's real database is a different job with its own
//!    evidence, and guessing at it inside an open path is how a store silently
//!    rewrites history.
//!
//! ## What the format is
//!
//! An *active checkpoint* plus *incremental facts*:
//!
//! - `strategy_runs.snapshot_json` is the active checkpoint — one row per run,
//!   the state a drive reads and advances.
//! - `strategy_run_events` is the incremental history, one row per applied
//!   reducer event, keyed `(run_id, sequence)`.
//! - `strategy_commands` is the per-command projection a claim and a result
//!   lookup read without decoding the whole checkpoint.
//! - `workflow_notice_intents` refers to a committed fact by
//!   `(run_id, sequence)` instead of copying its body. The body stays where it
//!   was committed, so recording delivery intent costs one small row rather
//!   than a second copy of the payload.

use anyhow::{Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};

/// The `strategy_meta.version` this adapter implements.
///
/// It is the production store's current version, not a new one: the adapter
/// reads the same rows, so declaring a different version would be a claim that
/// the format changed when only the writer did.
pub const STRATEGY_SCHEMA_VERSION: &str = "3";

/// Connection settings every connection in this crate applies.
///
/// `foreign_keys=ON` makes the schema's references real, `journal_mode=WAL`
/// keeps readers off the writer's back, `synchronous=FULL` keeps a committed
/// fact committed across power loss, and `busy_timeout` covers the window where
/// another *process* holds the single SQLite write lock.
pub const CONNECTION_PRAGMAS: &str = "PRAGMA foreign_keys=ON;
     PRAGMA journal_mode=WAL;
     PRAGMA synchronous=FULL;
     PRAGMA busy_timeout=5000;";

/// The tables this adapter owns, on top of the format the production store
/// defines. They are created with `IF NOT EXISTS`, so opening an existing
/// database adds exactly these and changes nothing else.
const NOTICE_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS workflow_notice_intents(
       notice_id TEXT PRIMARY KEY,
       run_id TEXT NOT NULL,
       sequence INTEGER NOT NULL,
       recipient TEXT NOT NULL,
       kind TEXT NOT NULL,
       status TEXT NOT NULL CHECK(status IN ('pending', 'accepted')),
       created_at INTEGER NOT NULL,
       accepted_at INTEGER
     );
     CREATE INDEX IF NOT EXISTS workflow_notice_intents_pending_idx
       ON workflow_notice_intents(status, created_at, run_id, sequence, notice_id);
     CREATE TABLE IF NOT EXISTS workflow_notice_acceptances(
       notice_id TEXT PRIMARY KEY,
       run_id TEXT NOT NULL,
       sequence INTEGER NOT NULL,
       recipient TEXT NOT NULL,
       kind TEXT NOT NULL,
       accept_count INTEGER NOT NULL,
       first_accepted_at INTEGER NOT NULL,
       last_accepted_at INTEGER NOT NULL
     );";

/// The checkpoint and history tables, in the shape the production store leaves
/// them after its own open path (`initialize_schema_through` plus the column
/// backfills it applies to a fresh file).
///
/// The column list here is the *end state* of that path, not its statement
/// order: a fresh file gets `conversation_id`, `terminal`, `model`, and
/// `reasoning_effort` from `ALTER TABLE` there and from these `CREATE`s here.
/// The tables the production store owns but this adapter never reads or writes
/// — bindings, authorizations, and the queue, subscription, control, and
/// transition-intent tables — are deliberately absent: the production store
/// creates them itself when it opens, and a schema this crate does not use is
/// not a schema it should be writing.
const CORE_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS strategy_meta(
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
       ON strategy_commands(lease_until) WHERE status IN ('claimed', 'running');";

/// Columns the adapter reads or writes, per table.
///
/// This is the compatibility contract with the production writer stated as
/// data: a file that lacks one of these is a file this adapter cannot honestly
/// serve, and saying so up front is better than failing halfway through a
/// transaction that already took the write lock.
const REQUIRED_COLUMNS: [(&str, &[&str]); 5] = [
    ("strategy_meta", &["key", "value"]),
    (
        "strategy_definitions",
        &["revision_digest", "semantics_digest", "workflow_json"],
    ),
    (
        "strategy_runs",
        &[
            "run_id",
            "revision_digest",
            "semantics_digest",
            "snapshot_json",
            "conversation_id",
            "terminal",
            "updated_at",
        ],
    ),
    (
        "strategy_run_events",
        &[
            "run_id",
            "sequence",
            "event_type",
            "event_json",
            "created_at",
        ],
    ),
    (
        "strategy_commands",
        &[
            "command_id",
            "run_id",
            "status",
            "attempt_token",
            "command_json",
            "lease_owner",
            "lease_until",
        ],
    ),
];

/// What [`prepare`] found.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SchemaState {
    /// The file already held this format; the adapter validated it and added
    /// only its own tables.
    Existing,
    /// The file was new and the adapter created the whole format.
    Initialized,
}

/// Open-path schema work for one connection.
///
/// A file is judged by whether it already holds `strategy_meta`, not by whether
/// a path exists: an interrupted first write can leave a zero-length file
/// behind, and treating that as "an existing database" would turn a fresh
/// install into a validation failure.
pub fn prepare(connection: &mut Connection) -> Result<SchemaState> {
    connection.execute_batch(CONNECTION_PRAGMAS)?;
    if table_exists(connection, "strategy_meta")? {
        validate(connection)?;
        return Ok(SchemaState::Existing);
    }
    initialize(connection)?;
    Ok(SchemaState::Initialized)
}

/// Create the format on a file that does not hold it yet.
pub fn initialize(connection: &mut Connection) -> Result<()> {
    connection.execute_batch(CONNECTION_PRAGMAS)?;
    connection.execute_batch(CORE_SCHEMA)?;
    connection.execute_batch(NOTICE_SCHEMA)?;
    connection.execute(
        "UPDATE strategy_meta SET value=?1 WHERE key='version'",
        params![STRATEGY_SCHEMA_VERSION],
    )?;
    Ok(())
}

/// Validate an existing file and add the adapter's own tables.
///
/// Additive only. The production store's rows and tables are read and left
/// exactly as they were.
pub fn validate(connection: &mut Connection) -> Result<()> {
    let version: Option<String> = connection
        .query_row(
            "SELECT value FROM strategy_meta WHERE key='version'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let version = version.ok_or_else(|| {
        anyhow::anyhow!(
            "workflow_store_schema_version_unsupported: strategy_meta has no version row"
        )
    })?;
    ensure!(
        version == STRATEGY_SCHEMA_VERSION,
        "workflow_store_schema_version_unsupported: declared {version}, adapter implements {STRATEGY_SCHEMA_VERSION}"
    );
    for (table, required) in REQUIRED_COLUMNS {
        ensure!(
            table_exists(connection, table)?,
            "workflow_store_schema_table_missing: {table}"
        );
        let present = columns(connection, table)?;
        for column in required {
            ensure!(
                present.iter().any(|name| name == column),
                "workflow_store_schema_column_missing: {table}.{column}"
            );
        }
    }
    connection.execute_batch(NOTICE_SCHEMA)?;
    Ok(())
}

fn table_exists(connection: &Connection, table: &str) -> Result<bool> {
    let found: Option<String> = connection
        .query_row(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?1",
            params![table],
            |row| row.get(0),
        )
        .optional()?;
    Ok(found.is_some())
}

fn columns(connection: &Connection, table: &str) -> Result<Vec<String>> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(names)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn memory() -> Connection {
        Connection::open_in_memory().expect("in-memory database")
    }

    #[test]
    fn an_empty_file_is_initialized_and_then_validates_as_existing() {
        let mut connection = memory();
        assert_eq!(prepare(&mut connection).unwrap(), SchemaState::Initialized);
        assert_eq!(prepare(&mut connection).unwrap(), SchemaState::Existing);
    }

    #[test]
    fn a_file_without_the_implemented_version_is_refused_rather_than_migrated() {
        let mut connection = memory();
        initialize(&mut connection).unwrap();
        connection
            .execute("UPDATE strategy_meta SET value='2' WHERE key='version'", [])
            .unwrap();
        let error = prepare(&mut connection).unwrap_err().to_string();
        assert!(
            error.starts_with("workflow_store_schema_version_unsupported"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn a_file_missing_a_required_column_is_refused_with_its_name() {
        let mut connection = memory();
        initialize(&mut connection).unwrap();
        // A column no index depends on, so the alteration itself succeeds and
        // the failure under test is the adapter's own validation.
        connection
            .execute("ALTER TABLE strategy_run_events DROP COLUMN event_type", [])
            .unwrap();
        let error = prepare(&mut connection).unwrap_err().to_string();
        assert!(
            error.contains("strategy_run_events.event_type"),
            "unexpected: {error}"
        );
    }

    #[test]
    fn the_notice_tables_refer_to_a_committed_body_instead_of_copying_it() {
        let mut connection = memory();
        initialize(&mut connection).unwrap();
        let notice = columns(&connection, "workflow_notice_intents").unwrap();
        assert!(
            !notice.iter().any(|name| name.contains("json")),
            "the intent table must refer to the committed body, not carry a copy: {notice:?}"
        );
        let events = columns(&connection, "strategy_run_events").unwrap();
        assert!(events.contains(&"event_json".to_owned()));
    }
}
