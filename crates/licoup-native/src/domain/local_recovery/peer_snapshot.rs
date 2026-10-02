//! Preserve and prepare a recovered Conversation database, with explicit activation.

use anyhow::{Result, ensure};
use licoup_foundation::platform::file_security::{
    AtomicPrivateFile, AtomicWriteFailure, CleanupOutcome, CommitDurability, harden_private_path,
    sync_directory, validate_private_path_ancestors,
};
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use std::{fs, path::Path};

/// Fixed output names; the complete input snapshot always accompanies the candidate.
pub const PRESERVED_DATABASE: &str = "preserved-conversations.sqlite3";
pub const RECOVERED_DATABASE: &str = "recovered-conversations.sqlite3";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerSnapshotRecovery {
    pub status: &'static str,
    pub source_data_unchanged: bool,
    pub preserved_database: &'static str,
    pub recovered_database: &'static str,
    pub activated: bool,
    pub activation_durable: Option<bool>,
    pub backup_archive: Option<&'static str>,
}

/// Read the explicit root with all writers stopped and retain a complete SQLite
/// snapshot, including committed WAL data, in a new private output directory.
/// Only its second copy is normalized through the Conversation owner. No root
/// references, other stores, custody metadata or protected keys are touched.
pub fn recover_peer_snapshot(
    data_root: &Path,
    output: &Path,
    writers_stopped: bool,
) -> Result<PeerSnapshotRecovery> {
    recover(data_root, output, writers_stopped, false, publish_candidate)
}

/// Explicit activation under the caller's exclusive recovery lease. The full
/// original root is archived before preparing a candidate, and only the current
/// Conversation database is replaced. This never changes key custody or the locator.
pub fn activate_peer_snapshot(
    data_root: &Path,
    output: &Path,
    writers_stopped: bool,
) -> Result<PeerSnapshotRecovery> {
    recover(data_root, output, writers_stopped, true, publish_candidate)
}

fn recover(
    data_root: &Path,
    output: &Path,
    writers_stopped: bool,
    activate: bool,
    publish: impl FnOnce(AtomicPrivateFile) -> Result<CommitDurability>,
) -> Result<PeerSnapshotRecovery> {
    ensure!(writers_stopped, "maintenance_confirmation_required");
    let root = super::resolve_data_home(Some(data_root))?;
    let output = std::path::absolute(output)?;
    validate_private_path_ancestors(&root)?;
    validate_private_path_ancestors(&output)?;
    ensure!(
        !output.starts_with(&root) && !root.starts_with(&output),
        "peer_snapshot_output_overlaps_source"
    );
    let source_path = root.join("client-state/conversations/conversations.sqlite3");
    for suffix in ["", "-wal", "-shm"] {
        let path = source_path.with_file_name(format!("conversations.sqlite3{suffix}"));
        validate_private_path_ancestors(&path)?;
        match fs::symlink_metadata(&path) {
            Ok(metadata) => ensure!(
                metadata.file_type().is_file(),
                "peer_snapshot_source_invalid"
            ),
            Err(error) if suffix != "" && error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    // create_dir refuses an existing destination; no previous recovery is overwritten.
    let mut directory = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directory.mode(0o700);
    }
    directory.create(&output)?;
    harden_private_path(&output)?;
    let backup_archive = activate.then_some("original-data-root.zip");
    if let Some(archive) = backup_archive {
        super::export_data_home(Some(&root), &output.join(archive), writers_stopped)?;
    }
    let preserved = output.join(PRESERVED_DATABASE);
    let pending = output.join("recovered-conversations.partial.sqlite3");
    let source = Connection::open_with_flags(&source_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    // SQLite's VACUUM INTO creates a consistent standalone snapshot without
    // checkpointing or writing the original database. The retained original root
    // remains the byte-preserving recovery asset; this snapshot preserves all rows.
    let preserved_name = preserved
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("peer_snapshot_output_invalid"))?;
    source.execute("VACUUM INTO ?1", [preserved_name])?;
    drop(source);
    harden_private_path(&preserved)?;
    fs::File::open(&preserved)?.sync_all()?;
    fs::copy(&preserved, &pending)?;
    harden_private_path(&pending)?;
    let mut candidate = Connection::open(&pending)?;
    candidate.pragma_update(None, "journal_mode", "DELETE")?;
    licoup_conversation::store::recover_peer_snapshot_copy(&mut candidate)?;
    let integrity: String = candidate.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
    ensure!(integrity == "ok", "peer_snapshot_integrity_failed");
    drop(candidate);
    fs::File::open(&pending)?.sync_all()?;
    fs::rename(&pending, output.join(RECOVERED_DATABASE))?;
    sync_directory(&output)?;
    let activation_durable = if activate {
        // Stage the verified candidate through the existing private atomic-file
        // owner before touching source journal state. Refusal leaves the source intact.
        let mut replacement =
            AtomicPrivateFile::create(&source_path).map_err(publication_failure)?;
        // Fold committed WAL into the old main file and let SQLite remove its own
        // sidecars. A failed replacement then leaves the original logical database
        // usable, without orphaning a WAL or manually unlinking SQLite state.
        let stage = (|| -> Result<()> {
            std::io::copy(
                &mut fs::File::open(output.join(RECOVERED_DATABASE))?,
                replacement.file_mut(),
            )?;
            let original =
                Connection::open_with_flags(&source_path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
            let journal: String =
                original.query_row("PRAGMA journal_mode=DELETE", [], |row| row.get(0))?;
            ensure!(journal == "delete", "peer_snapshot_writers_running");
            Ok(())
        })();
        if stage.is_err() {
            return Err(cleanup_failure(replacement.discard()));
        }
        Some(publish(replacement)? == CommitDurability::Confirmed)
    } else {
        None
    };
    Ok(PeerSnapshotRecovery {
        status: match activation_durable {
            None => "prepared",
            Some(true) => "activated",
            Some(false) => "activation-durability-unconfirmed",
        },
        source_data_unchanged: !activate,
        preserved_database: PRESERVED_DATABASE,
        recovered_database: RECOVERED_DATABASE,
        activated: activate,
        activation_durable,
        backup_archive,
    })
}

fn publish_candidate(replacement: AtomicPrivateFile) -> Result<CommitDurability> {
    replacement.commit().map_err(publication_failure)
}

fn publication_failure(failure: AtomicWriteFailure) -> anyhow::Error {
    cleanup_failure(failure.into_parts().1)
}

fn cleanup_failure(cleanup: CleanupOutcome) -> anyhow::Error {
    anyhow::anyhow!(match cleanup {
        CleanupOutcome::Removed => "peer_snapshot_publication_failed",
        CleanupOutcome::DurabilityUnconfirmed(_) => "peer_snapshot_cleanup_durability_unconfirmed",
        CleanupOutcome::Retained(_) => "peer_snapshot_cleanup_incomplete",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_activation_preserves_original_rows_and_a_complete_backup() {
        let fixture = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("licoup-peer-activation-{}", uuid::Uuid::new_v4()));
        let root = fixture.join("source");
        licoup_foundation::platform::file_security::ensure_private_dir(&root).unwrap();
        drop(licoup_conversation::ConversationStore::open(&root).unwrap());
        let database = root.join("client-state/conversations/conversations.sqlite3");
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(include_str!(
                "../../../../../tests/fixtures/client_state_migration/unpublished_peer_snapshot.sql"
            ))
            .unwrap();
        connection.execute_batch("INSERT INTO conversations(id,title,created_at,updated_at) VALUES ('conversation','Synthetic preserved title',1,1);
          INSERT INTO peer_bindings VALUES (x'01',x'02','conversation','member','provider',1);").unwrap();
        drop(connection);
        let output = fixture.join("output");
        let result = recover(&root, &output, true, true, |replacement| {
            Err(cleanup_failure(replacement.discard()))
        });
        assert!(result.is_err());
        let original = Connection::open(&database).unwrap();
        assert_eq!(
            original
                .query_row("SELECT count(*) FROM peer_bindings", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            original
                .query_row(
                    "SELECT title FROM conversations WHERE id='conversation'",
                    [],
                    |row| row.get::<_, String>(0)
                )
                .unwrap(),
            "Synthetic preserved title"
        );
        assert!(output.join("original-data-root.zip").is_file());
        assert!(output.join(PRESERVED_DATABASE).is_file());
        assert!(output.join(RECOVERED_DATABASE).is_file());
        drop(original);
        fs::remove_dir_all(fixture).unwrap();
    }
}
