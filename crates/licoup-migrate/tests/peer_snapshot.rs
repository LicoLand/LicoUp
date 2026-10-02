//! Real CLI preparation and explicit activation of a synthetic unpublished snapshot.

mod support;

use rusqlite::Connection;
use support::{TestRoot, root_files, run_tool, seed_released_root};

const PEER_SCHEMA: &str =
    include_str!("../../../tests/fixtures/client_state_migration/unpublished_peer_snapshot.sql");

#[test]
fn cli_preserves_the_complete_snapshot_and_prepares_a_current_owner_readable_copy() {
    support::assert_candidate_identity();
    let fixture = TestRoot::new("peer-snapshot");
    let source = fixture.join("source");
    seed_released_root(&source);
    let (code, report) = run_tool(&[
        "convert",
        "--data-root",
        source.to_str().unwrap(),
        "--writers-stopped",
    ]);
    assert_eq!(code, 1, "custody is intentionally disabled: {report}");
    assert_eq!(
        report["stillOwed"],
        serde_json::json!(["gateway-credential-custody"])
    );
    assert_eq!(report["refused"], serde_json::json!([]));
    let database = source.join("client-state/conversations/conversations.sqlite3");
    let connection = Connection::open(&database).unwrap();
    connection.execute_batch(PEER_SCHEMA).unwrap();
    // Keep this writer connection open with committed WAL pages: the tool must
    // capture SQLite's logical snapshot, not copy a potentially stale main file.
    connection
        .pragma_update(None, "journal_mode", "WAL")
        .unwrap();
    connection
        .pragma_update(None, "wal_autocheckpoint", 0)
        .unwrap();
    connection.execute_batch("INSERT INTO conversations(id,title,created_at,updated_at)
      VALUES ('peer-conversation','Synthetic preserved title',1,1);
      INSERT INTO events(id,conversation_id,sequence,kind,created_at)
      VALUES ('peer-event','peer-conversation',1,'message',1);
      INSERT INTO peer_bindings VALUES (x'01',x'02','peer-conversation','member','provider',1);
      INSERT INTO peer_inbox VALUES (x'01',x'02','peer-conversation',x'03','peer-event');
      INSERT INTO peer_effect_intents VALUES ('intent','peer-event',0,'peer-conversation','member','provider','{}',0);").unwrap();
    // The synthetic connection is quiescent for the remainder of the capture.
    let before = root_files(&source);
    let output = fixture.join("output");
    let (code, report) = run_tool(&[
        "recover-peer-snapshot",
        "--data-root",
        source.to_str().unwrap(),
        "--target-root",
        output.to_str().unwrap(),
        "--writers-stopped",
    ]);
    assert_eq!(code, 0, "{report}");
    assert_eq!(report["status"], "prepared");
    assert_eq!(report["activated"], false);
    let after = root_files(&source);
    assert_eq!(
        after.keys().collect::<Vec<_>>(),
        before.keys().collect::<Vec<_>>()
    );
    for (name, expected) in &before {
        // SQLite read locks update only the transient shared-memory read mark.
        // The database, committed WAL and every other source file stay byte-identical.
        if name != "client-state/conversations/conversations.sqlite3-shm" {
            assert!(
                after.get(name) == Some(expected),
                "source file changed: {name}"
            );
        }
    }
    let retained = Connection::open(output.join("preserved-conversations.sqlite3")).unwrap();
    for table in ["peer_bindings", "peer_inbox", "peer_effect_intents"] {
        assert_eq!(
            retained
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    let recovered_path = output.join("recovered-conversations.sqlite3");
    let recovered = Connection::open(&recovered_path).unwrap();
    assert_eq!(
        recovered
            .query_row(
                "SELECT title FROM conversations WHERE id='peer-conversation'",
                [],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
        "Synthetic preserved title"
    );
    assert_eq!(
        recovered
            .query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        0
    );
    drop(recovered);
    // Explicit activation is exercised only against the isolated synthetic root.
    drop(connection);
    let before_activation = root_files(&source);
    let activation = fixture.join("activation");
    let (code, report) = run_tool(&[
        "recover-peer-snapshot",
        "--data-root",
        source.to_str().unwrap(),
        "--target-root",
        activation.to_str().unwrap(),
        "--writers-stopped",
        "--activate",
    ]);
    assert_eq!(code, 0, "{report}");
    assert_eq!(report["status"], "activated");
    assert_eq!(report["activated"], true);
    assert_eq!(report["activationDurable"], true);
    let restored = fixture.join("restored-original");
    licoup_foundation::core::full_data_root_archive::restore_data_root(
        &licoup_foundation::core::full_data_root_archive::RestoreRequest {
            archive_path: activation.join("original-data-root.zip"),
            target_root: restored.clone(),
        },
    )
    .unwrap();
    assert!(
        root_files(&restored) == before_activation,
        "the full original root is recoverable byte-for-byte"
    );
    for (name, bytes) in &before_activation {
        if !name.starts_with("client-state/conversations/conversations.sqlite3") {
            assert!(
                std::fs::read(source.join(name)).unwrap() == *bytes,
                "unrelated store changed: {name}"
            );
        }
    }
    let (code, report) = run_tool(&[
        "convert",
        "--data-root",
        source.to_str().unwrap(),
        "--writers-stopped",
    ]);
    assert_eq!(code, 1, "custody remains intentionally disabled: {report}");
    assert_eq!(
        report["stillOwed"],
        serde_json::json!(["gateway-credential-custody"])
    );
    assert_eq!(report["refused"], serde_json::json!([]));
    let (code, report) = run_tool(&[
        "recover-peer-snapshot",
        "--data-root",
        source.to_str().unwrap(),
        "--target-root",
        output.to_str().unwrap(),
        "--writers-stopped",
    ]);
    assert_ne!(
        code, 0,
        "an existing recovery output must never be overwritten: {report}"
    );
}

#[test]
fn cli_requires_stopped_writers_and_refuses_unknown_snapshots_without_activation() {
    let fixture = TestRoot::new("peer-refusal");
    let source = fixture.join("source");
    seed_released_root(&source);
    let output = fixture.join("output");
    let (code, _) = run_tool(&[
        "recover-peer-snapshot",
        "--data-root",
        source.to_str().unwrap(),
        "--target-root",
        output.to_str().unwrap(),
    ]);
    assert_ne!(code, 0);
    assert!(!output.exists());
    let before = root_files(&source);
    let (code, report) = run_tool(&[
        "recover-peer-snapshot",
        "--data-root",
        source.to_str().unwrap(),
        "--target-root",
        output.to_str().unwrap(),
        "--writers-stopped",
    ]);
    assert_ne!(code, 0);
    assert_eq!(report["error"], "peer_snapshot_recovery_refused");
    assert!(!output.join("recovered-conversations.sqlite3").exists());
    assert!(output.join("preserved-conversations.sqlite3").is_file());
    assert!(
        root_files(&source) == before,
        "source data changed on refusal"
    );
    assert!(!report.to_string().contains(source.to_str().unwrap()));
}
