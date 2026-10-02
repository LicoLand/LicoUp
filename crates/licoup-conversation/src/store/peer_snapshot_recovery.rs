//! Explicit offline recovery of an unpublished collaboration snapshot.
//!
//! This is not a runtime schema or release migration. The caller must retain the
//! complete input database and invoke this operation only on a disposable copy.

use super::{CURRENT_SCHEMA_VERSION, StoreResult, schema};
use anyhow::ensure;
use licoup_foundation::core::sqlite_contract::validate_table;
use rusqlite::Connection;

// The one abandoned producer shape accepted by this bounded recovery operation.
const PEER_TABLES: &str = "
CREATE TABLE peer_bindings(
  author BLOB NOT NULL, device BLOB NOT NULL,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  membership_id TEXT NOT NULL, provider_id TEXT NOT NULL,
  active INTEGER NOT NULL CHECK(active IN (0,1)), PRIMARY KEY(author,device));
CREATE TABLE peer_inbox(
  author BLOB NOT NULL, device BLOB NOT NULL,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  logical_id BLOB NOT NULL, event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  PRIMARY KEY(author,device,conversation_id,logical_id));
CREATE TABLE peer_effect_intents(
  id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  membership_id TEXT NOT NULL, provider_id TEXT NOT NULL, request_json TEXT NOT NULL,
  accepted INTEGER NOT NULL DEFAULT 0 CHECK(accepted IN (0,1)), UNIQUE(event_id,ordinal));
CREATE INDEX peer_effect_intents_pending_idx ON peer_effect_intents(accepted,event_id,ordinal);";

/// Remove the three unsupported peer tables from a preserved snapshot's working
/// copy. All parent rows remain intact; no peer effect is replayed. Unknown shapes,
/// incoming references and a target the current owner cannot admit are refused.
/// The transaction rolls back every change on refusal.
pub fn recover_peer_snapshot_copy(connection: &mut Connection) -> StoreResult<()> {
    let reference = Connection::open_in_memory()?;
    reference.execute_batch(PEER_TABLES)?;
    connection.pragma_update(None, "foreign_keys", true)?;
    let transaction = connection.transaction()?;
    for table in ["peer_bindings", "peer_inbox", "peer_effect_intents"] {
        validate_table(&transaction, &reference, table, None)?;
    }
    transaction.execute_batch(
        "DROP TABLE peer_effect_intents; DROP TABLE peer_inbox; DROP TABLE peer_bindings;",
    )?;
    ensure!(
        schema::validate_migration_source(&transaction)?.as_deref() == Some(CURRENT_SCHEMA_VERSION),
        "peer_snapshot_target_unsupported"
    );
    let violations: i64 =
        transaction.query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |row| {
            row.get(0)
        })?;
    ensure!(violations == 0, "peer_snapshot_foreign_key_violation");
    transaction.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot() -> Connection {
        let mut connection = Connection::open_in_memory().unwrap();
        schema::initialize_schema(&mut connection).unwrap();
        connection.execute_batch(PEER_TABLES).unwrap();
        connection.execute_batch("INSERT INTO conversations(id,title,created_at,updated_at)
          VALUES ('conversation','Retained synthetic conversation',1,1);
          INSERT INTO events(id,conversation_id,sequence,kind,created_at)
          VALUES ('event','conversation',1,'message',1);
          INSERT INTO peer_bindings VALUES (x'01',x'02','conversation','member','provider',1);
          INSERT INTO peer_inbox VALUES (x'01',x'02','conversation',x'03','event');
          INSERT INTO peer_effect_intents VALUES ('intent','event',0,'conversation','member','provider','{}',0);").unwrap();
        connection
    }

    #[test]
    fn preserves_parent_data_and_admits_only_the_current_target() {
        let mut connection = snapshot();
        assert!(schema::validate_migration_source(&connection).is_err());
        recover_peer_snapshot_copy(&mut connection).unwrap();
        assert_eq!(
            schema::validate_migration_source(&connection)
                .unwrap()
                .as_deref(),
            Some(CURRENT_SCHEMA_VERSION)
        );
        let title: String = connection
            .query_row(
                "SELECT title FROM conversations WHERE id='conversation'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(title, "Retained synthetic conversation");
        assert_eq!(
            connection
                .query_row("SELECT count(*) FROM events", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }

    #[test]
    fn rejects_unknown_peer_shapes_incoming_references_and_bad_targets_without_changes() {
        for mutation in [
            "ALTER TABLE peer_bindings ADD COLUMN epoch INTEGER NOT NULL DEFAULT 1",
            "CREATE TABLE extra(id TEXT REFERENCES peer_effect_intents(id) ON DELETE CASCADE)",
            "CREATE TRIGGER peer_effect AFTER DELETE ON peer_effect_intents BEGIN DELETE FROM events; END",
            "ALTER TABLE conversations ADD COLUMN required_extra TEXT NOT NULL DEFAULT ''",
            "UPDATE schema_meta SET value='19' WHERE key='version'",
        ] {
            let mut connection = snapshot();
            connection.execute_batch(mutation).unwrap();
            assert!(
                recover_peer_snapshot_copy(&mut connection).is_err(),
                "{mutation}"
            );
            for table in [
                "peer_bindings",
                "peer_inbox",
                "peer_effect_intents",
                "events",
            ] {
                assert_eq!(
                    connection
                        .query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row
                            .get::<_, i64>(0))
                        .unwrap(),
                    1
                );
            }
        }
    }
}
