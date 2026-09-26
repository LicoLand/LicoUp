//! The tables recovery owns, and the shared columns it reads.
//!
//! Same rules as the rest of this adapter: additive only, validated before use,
//! and never a rewrite of a table the production store owns. Three statements
//! of that rule are worth naming here because recovery touches rows other
//! writers depend on:
//!
//! * The rows recovery reads — the checkpoint, the command rows with their
//!   claims — are read through the production store's own column shape, and a
//!   file that does not have it is refused by name before anything is written.
//! * The two tables below are the only tables this module creates. One holds
//!   reconciliation facts (what an effect's owner confirmed about an in-doubt
//!   attempt); the other holds successor handoffs, one per run, which is what
//!   makes the handoff compare-and-set a constraint rather than a convention.
//! * Neither table carries a causal-state column with a default. A record that
//!   omits the facts it was built from is refused by `deny_unknown_fields` on
//!   the Rust side and by `NOT NULL` here, so an old record and an empty fact
//!   can never read the same.

use anyhow::{Result, ensure};
use rusqlite::{Connection, Transaction};

/// The tables this module owns, on top of the shared format.
pub(crate) const RECOVERY_SCHEMA: &str =
    "CREATE TABLE IF NOT EXISTS workflow_effect_reconciliations(
       run_id TEXT NOT NULL,
       command_id TEXT NOT NULL,
       attempt_token TEXT NOT NULL,
       node_id TEXT NOT NULL,
       node_visit INTEGER NOT NULL,
       outcome TEXT NOT NULL CHECK(outcome IN ('executed', 'not_executed', 'unknown')),
       evidence TEXT NOT NULL,
       result_digest TEXT,
       observed_at INTEGER NOT NULL,
       PRIMARY KEY(run_id, command_id, attempt_token)
     );
     CREATE INDEX IF NOT EXISTS workflow_effect_reconciliations_run_idx
       ON workflow_effect_reconciliations(run_id, observed_at, command_id);
     CREATE TABLE IF NOT EXISTS workflow_successor_handoffs(
       run_id TEXT PRIMARY KEY,
       handoff_id TEXT NOT NULL UNIQUE,
       boundary_revision INTEGER NOT NULL,
       old_owner TEXT NOT NULL,
       new_owner TEXT NOT NULL,
       old_binding_json TEXT NOT NULL,
       migrated_json TEXT NOT NULL,
       started_json TEXT NOT NULL,
       boundary_json TEXT NOT NULL,
       created_at INTEGER NOT NULL
     );";

/// The columns of one table this module reads.
pub(crate) struct RequiredColumns {
    pub(crate) table: &'static str,
    pub(crate) columns: &'static [&'static str],
}

/// What recovery reads, stated as data.
///
/// A production file that lacks one of these cannot be served honestly: the
/// claim boundary recovery rests on is `lease_owner`/`lease_until` beside the
/// command status, and the causal boundary is the checkpoint body. Saying so
/// before a write is better than discovering it halfway through one.
pub(crate) const REQUIRED_COLUMNS: [RequiredColumns; 3] = [
    RequiredColumns {
        table: "strategy_commands",
        columns: &[
            "command_id",
            "run_id",
            "state_id",
            "status",
            "attempt_token",
            "command_json",
            "lease_owner",
            "lease_until",
            "updated_at",
        ],
    },
    RequiredColumns {
        table: "strategy_runs",
        columns: &[
            "run_id",
            "revision_digest",
            "semantics_digest",
            "snapshot_json",
            "updated_at",
        ],
    },
    RequiredColumns {
        table: "strategy_definitions",
        columns: &["revision_digest", "semantics_digest", "workflow_json"],
    },
];

/// Validate the columns recovery reads and refuse a file that lacks one.
pub(crate) fn validate(connection: &Connection) -> Result<()> {
    for required in REQUIRED_COLUMNS {
        let present = columns(connection, required.table)?;
        ensure!(
            !present.is_empty(),
            "workflow_recovery_table_missing: {}",
            required.table
        );
        for column in required.columns {
            ensure!(
                present.iter().any(|name| name == column),
                "workflow_recovery_column_missing: {}.{column}",
                required.table
            );
        }
    }
    Ok(())
}

/// Add the tables this module owns. Idempotent and additive.
pub(crate) fn install(transaction: &Transaction<'_>) -> Result<()> {
    transaction.execute_batch(RECOVERY_SCHEMA)?;
    Ok(())
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
    use rusqlite::params;

    fn memory() -> Connection {
        Connection::open_in_memory().expect("in-memory database")
    }

    #[test]
    fn a_file_missing_a_claim_column_is_refused_by_name() {
        let connection = memory();
        connection
            .execute_batch(
                "CREATE TABLE strategy_commands(command_id TEXT);
                 CREATE TABLE strategy_runs(run_id TEXT);
                 CREATE TABLE strategy_definitions(revision_digest TEXT);",
            )
            .unwrap();
        let error = validate(&connection).unwrap_err().to_string();
        assert!(
            error.starts_with("workflow_recovery_column_missing: strategy_commands."),
            "unexpected: {error}"
        );
    }

    #[test]
    fn installing_twice_is_the_same_as_once() {
        let mut connection = memory();
        validate_and_install(&mut connection).expect("first install");
        validate_and_install(&mut connection).expect("second install");
    }

    /// The test's own helper: the module installs through a transaction, which
    /// only exists on a connection that is already open for writing.
    fn validate_and_install(connection: &mut Connection) -> Result<()> {
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS strategy_commands(
               command_id TEXT PRIMARY KEY, run_id TEXT, state_id TEXT, status TEXT,
               attempt_token TEXT, command_json TEXT, lease_owner TEXT, lease_until INTEGER,
               updated_at INTEGER);
             CREATE TABLE IF NOT EXISTS strategy_runs(
               run_id TEXT PRIMARY KEY, revision_digest TEXT, semantics_digest TEXT,
               snapshot_json TEXT, updated_at INTEGER);
             CREATE TABLE IF NOT EXISTS strategy_definitions(
               revision_digest TEXT PRIMARY KEY, semantics_digest TEXT, workflow_json TEXT);",
        )?;
        validate(connection)?;
        let transaction = connection.transaction()?;
        install(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    #[test]
    fn a_reconciliation_row_cannot_be_written_without_its_attempt_identity() {
        let mut connection = memory();
        validate_and_install(&mut connection).unwrap();
        let inserted = connection.execute(
            "INSERT INTO workflow_effect_reconciliations(
               run_id, command_id, attempt_token, node_id, node_visit, outcome, evidence,
               result_digest, observed_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, ?8)",
            params![
                "run", "command", "attempt", "node", 1_i64, "executed", "test", 1_i64
            ],
        );
        assert!(inserted.is_ok());
        // A second row for the same attempt is a conflict, not a second fact.
        let duplicate = connection.execute(
            "INSERT INTO workflow_effect_reconciliations(
               run_id, command_id, attempt_token, node_id, node_visit, outcome, evidence,
               result_digest, observed_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, ?8)",
            params![
                "run", "command", "attempt", "node", 1_i64, "unknown", "test", 2_i64
            ],
        );
        assert!(duplicate.is_err(), "the attempt identity is the key");
    }

    #[test]
    fn one_handoff_per_run_is_a_constraint_not_a_convention() {
        let mut connection = memory();
        validate_and_install(&mut connection).unwrap();
        for handoff in ["first", "second"] {
            let inserted = connection.execute(
                "INSERT INTO workflow_successor_handoffs(
                   run_id, handoff_id, boundary_revision, old_owner, new_owner,
                   old_binding_json, migrated_json, started_json, boundary_json, created_at
                 ) VALUES ('run', ?1, 7, 'old#1', 'new#1', '{}', '[]', '[]', '{}', 1)",
                params![handoff],
            );
            if handoff == "second" {
                assert!(inserted.is_err(), "one handoff per run");
            } else {
                assert!(inserted.is_ok());
            }
        }
    }
}
