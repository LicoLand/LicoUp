//! Native composition for complete local recovery through the archive owner.
//!
//! [`export_data_home`] and [`import_archive`] are the reusable native composition a
//! caller uses instead of marshalling a second restore policy: the client CLI today,
//! the standalone migration tool later. The archive owner in `licoup-foundation` owns
//! the container, manifest, extraction and publication; this module owns only the two
//! steps that need the application's own owners:
//!
//! * a restore into another home applies the existing data-home reference rewrite,
//!   which rewrites owner-managed references and never touches user message content
//!   or unrelated project paths; and
//! * restored workflow revisions are re-frozen and read back through the workflow
//!   package owner.
//!
//! Writer coordination is [`acquire_exclusive_selected_home`], which wraps the existing
//! data-home access owner. The caller holds the returned lease for the capture or
//! import and refuses, rather than reading a live root, when a writer is already
//! active.

use anyhow::{Result, anyhow};
use licoup_foundation::core::full_data_root_archive::{
    ExportOutcome, ExportRequest, RestoreOutcome, RestoreRequest, export_data_root,
    restore_data_root,
};
use licoup_foundation::platform::data_home_access::{
    DataHomeRelocationLease, try_acquire_data_home_relocation_lease,
};
use licoup_foundation::platform::paths;
use std::path::{Path, PathBuf};

/// The stable refusal when another process still uses the selected data home.
pub const WRITERS_RUNNING: &str = "backup_writers_running";

/// The stable refusal when an import's failed owner verification could not be rolled
/// back, so a fully published but unverified root remains at the caller's destination.
///
/// The source archive is untouched; the reference rewrite and the revision refreeze and
/// readback are idempotent owner operations, so the retained root can be repaired forward
/// instead of being treated as a completed recovery.
pub const RECOVERY_CLEANUP_FAILED: &str = "recovery_target_cleanup_failed";

/// One completed import, including the owner checks performed after publication.
#[derive(Clone, Debug)]
pub struct RecoveryImport {
    pub outcome: RestoreOutcome,
    /// The restored home differed from the captured logical source home, so the
    /// data-home reference rewrite was applied.
    pub relocated: bool,
    /// Revision digests re-frozen and read back through the workflow package owner.
    pub verified_workflow_revisions: Vec<String>,
}

/// Resolve the logical data home for a recovery command.
///
/// An explicit root is normalized lexically against the process working directory; the
/// operator names it, so it is not resolved through links. Without one, the existing
/// authoritative resolver selects `LICOUP_HOME`, the published alias, the saved
/// selection and the platform default in that order.
pub fn resolve_data_home(explicit: Option<&Path>) -> Result<PathBuf> {
    match explicit {
        Some(path) => std::path::absolute(path).map_err(|_| anyhow!("data_root_unresolved")),
        None => Ok(paths::selected_data_home()?.path),
    }
}

/// Acquire the selected data home's exclusive relocation lease without waiting.
///
/// The command must run in a process that holds no shared lease. `Ok(None)` means
/// another process is using the data home; the operation must then be refused with
/// [`WRITERS_RUNNING`] instead of reading a live root, and no writer is stopped.
pub fn acquire_exclusive_selected_home() -> Result<Option<DataHomeRelocationLease>> {
    try_acquire_data_home_relocation_lease()
}

/// Export the complete data home into one plaintext archive.
pub fn export_data_home(
    data_root: Option<&Path>,
    archive_path: &Path,
    writers_stopped: bool,
) -> Result<ExportOutcome> {
    let data_root = resolve_data_home(data_root)?;
    let archive_path =
        std::path::absolute(archive_path).map_err(|_| anyhow!("backup_archive_unresolved"))?;
    export_data_root(&ExportRequest {
        data_root,
        archive_path,
        writers_stopped,
    })
}

/// Import one archive into an empty target home.
///
/// The generic restore owns publication and its refusals: it validates the archive and
/// every declared member before anything is published, and publishes only into an empty
/// destination. Afterwards this composition rebases owner-managed references when the
/// target differs from the captured logical source home, then re-establishes and verifies
/// the workflow revision protections through their owner.
///
/// The owner checks run after publication, so a failure here is rolled back with a checked
/// cleanup: the destination is restored to the caller's prior state — removed when this
/// call created it, emptied when the caller named an existing empty directory — and the
/// original owner refusal is returned. Cleanup that cannot complete is reported as
/// [`RECOVERY_CLEANUP_FAILED`] instead of being silently ignored, because the caller must
/// know that destination contents or rollback durability are uncertain. The source
/// archive is never deleted: preserve any retained destination for diagnosis and retry
/// into a fresh empty home. This operation does not activate the restored home or claim
/// crash-atomic owner preparation; process interruption can leave an unverified root.
pub fn import_archive(archive_path: &Path, target_root: &Path) -> Result<RecoveryImport> {
    let archive_path =
        std::path::absolute(archive_path).map_err(|_| anyhow!("backup_archive_unresolved"))?;
    let target_root =
        std::path::absolute(target_root).map_err(|_| anyhow!("backup_target_root_unresolved"))?;
    let created_target = !target_root.exists();

    let outcome = restore_data_root(&RestoreRequest {
        archive_path,
        target_root: target_root.clone(),
    })?;

    // Foundation validated absolute provenance before publishing. There must be no
    // fallible post-publication preparation outside the checked rollback branch.
    let source_home = outcome.source_home.clone();
    let relocated = source_home != target_root;
    let verification = (|| -> Result<Vec<String>> {
        crate::domain::mobile_relay::prepare_recovered_custody_metadata(
            &target_root,
            &source_home,
        )?;
        // The existing conversation-snapshot owner owns which references travel with
        // the home; it returns immediately when the source and target are the same.
        crate::domain::conversation::snapshots::relocate_copied_data_home_references(
            &target_root,
            &source_home,
            &target_root,
        )?;
        match crate::domain::workflow_runtime::StrategyPackageImporter::open_restored(&target_root)?
        {
            Some(importer) => importer.restore_revision_invariants(),
            None => Ok(Vec::new()),
        }
    })();
    match verification {
        Ok(verified_workflow_revisions) => Ok(RecoveryImport {
            outcome,
            relocated,
            verified_workflow_revisions,
        }),
        Err(error) => {
            if rollback_published_root(&target_root, created_target).is_err() {
                return Err(error.context(RECOVERY_CLEANUP_FAILED));
            }
            Err(error)
        }
    }
}

/// Restore an import destination to the state the caller left it in.
///
/// The caller's prior state is either "absent" (this call created the directory) or "an
/// empty directory" (the caller named one and the archive owner required it to be empty).
/// Any other state was refused by the owner before publication, so only these two are
/// rolled back. A rollback that cannot complete reports the stable cleanup code; it never
/// pretends the destination is gone.
fn rollback_published_root(target_root: &Path, created_target: bool) -> Result<()> {
    rollback_published_root_with_sync(
        target_root,
        created_target,
        licoup_foundation::platform::file_security::sync_directory,
    )
}

fn rollback_published_root_with_sync(
    target_root: &Path,
    created_target: bool,
    mut sync: impl FnMut(&Path) -> Result<()>,
) -> Result<()> {
    if created_target {
        remove_published_tree(target_root).map_err(|_| anyhow!(RECOVERY_CLEANUP_FAILED))?;
    } else {
        let entries =
            std::fs::read_dir(target_root).map_err(|_| anyhow!(RECOVERY_CLEANUP_FAILED))?;
        for entry in entries {
            let entry = entry.map_err(|_| anyhow!(RECOVERY_CLEANUP_FAILED))?;
            remove_published_tree(&entry.path()).map_err(|_| anyhow!(RECOVERY_CLEANUP_FAILED))?;
        }
        sync(target_root).map_err(|_| anyhow!(RECOVERY_CLEANUP_FAILED))?;
    }
    let parent = target_root
        .parent()
        .ok_or_else(|| anyhow!(RECOVERY_CLEANUP_FAILED))?;
    sync(parent).map_err(|_| anyhow!(RECOVERY_CLEANUP_FAILED))?;
    Ok(())
}

/// Remove one file or tree this call published, clearing the read-only hardening the
/// workflow owner applies to committed revisions.
///
/// A partial owner verification can leave some revision trees hardened. That hardening
/// protects usable revisions; the tree being removed here was never reported as one, and
/// leaving it behind would make the cleanup claim false. Symbolic links are removed as
/// links and never followed.
fn remove_published_tree(path: &Path) -> std::io::Result<()> {
    let metadata = std::fs::symlink_metadata(path)?;
    // A hardened directory refuses the removal of its own entries, so its write
    // permission is restored before the walk continues.
    let directory = metadata.is_dir() && !metadata.file_type().is_symlink();
    if !metadata.file_type().is_symlink() {
        make_removable(path, &metadata, directory)?;
    }
    if directory {
        for entry in std::fs::read_dir(path)? {
            remove_published_tree(&entry?.path())?;
        }
        std::fs::remove_dir(path)
    } else {
        std::fs::remove_file(path)
    }
}

/// Restore owner write permission on one entry of a tree being discarded.
///
/// The workflow owner hardens committed revisions read-only. That tree is being removed
/// because it was never accepted as a usable recovery, so the hardening is cleared with
/// an explicit private mode rather than a world-writable one.
fn make_removable(
    path: &Path,
    metadata: &std::fs::Metadata,
    directory: bool,
) -> std::io::Result<()> {
    if !metadata.permissions().readonly() {
        return Ok(());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = if directory { 0o700 } else { 0o600 };
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
    }
    #[cfg(not(unix))]
    {
        let mut permissions = metadata.permissions();
        permissions.set_readonly(false);
        std::fs::set_permissions(path, permissions)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(label: &str) -> PathBuf {
        let root = std::env::temp_dir()
            .canonicalize()
            .expect("temp dir")
            .join(format!(
                "licoup-local-recovery-{label}-{}",
                std::process::id()
            ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("scratch");
        root
    }

    /// A destination this call created is removed, including read-only revision subtrees
    /// the workflow owner hardens.
    #[test]
    fn checked_cleanup_removes_a_created_destination() {
        let base = scratch("created");
        let target = base.join("target");
        let hardened = target.join("client-state/adaptive-flywheel/strategy-packages/revisions");
        std::fs::create_dir_all(&hardened).expect("hardened tree");
        std::fs::write(hardened.join("workflow.json"), b"{}").expect("revision");
        let mut permissions = std::fs::metadata(&hardened)
            .expect("metadata")
            .permissions();
        permissions.set_readonly(true);
        std::fs::set_permissions(&hardened, permissions).expect("harden");

        rollback_published_root(&target, true).expect("cleanup completes");
        assert!(!target.exists(), "the created destination is gone");
        let _ = std::fs::remove_dir_all(&base);
    }

    /// A caller's own empty directory is emptied but not deleted.
    #[test]
    fn checked_cleanup_restores_a_caller_named_empty_directory() {
        let base = scratch("pre-existing");
        let target = base.join("target");
        std::fs::create_dir_all(target.join("nested")).expect("published tree");
        std::fs::write(target.join("nested/member.txt"), b"published").expect("member");

        rollback_published_root(&target, false).expect("cleanup completes");
        assert!(target.is_dir(), "the caller's directory itself survives");
        assert_eq!(
            std::fs::read_dir(&target)
                .expect("readable directory")
                .count(),
            0,
            "the published content is gone"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    /// A cleanup that cannot read the destination reports the stable code instead of
    /// claiming the destination is gone.
    #[test]
    fn checked_cleanup_requires_durable_removal_for_both_destination_shapes() {
        for created in [false, true] {
            let base = scratch(if created {
                "durability-created"
            } else {
                "durability-existing"
            });
            let target = base.join("target");
            std::fs::create_dir_all(&target).unwrap();
            std::fs::write(target.join("payload"), b"synthetic").unwrap();
            let mut synced = Vec::new();
            let error = rollback_published_root_with_sync(&target, created, |path| {
                synced.push(path.to_path_buf());
                if path == base {
                    Err(anyhow!("synthetic directory sync failure"))
                } else {
                    Ok(())
                }
            })
            .unwrap_err();
            assert_eq!(error.to_string(), RECOVERY_CLEANUP_FAILED);
            let expected = if created {
                vec![base.clone()]
            } else {
                vec![target.clone(), base.clone()]
            };
            assert_eq!(synced, expected);
            assert_eq!(target.exists(), !created);
            std::fs::remove_dir_all(base).unwrap();
        }
    }

    #[test]
    fn checked_cleanup_reports_an_incomplete_rollback() {
        let base = scratch("failed");
        let target = base.join("target");
        std::fs::write(&target, b"not a directory").expect("file destination");

        let error = rollback_published_root(&target, false).expect_err("cannot empty a file");
        assert_eq!(error.to_string(), RECOVERY_CLEANUP_FAILED);
        let _ = std::fs::remove_dir_all(&base);
    }
}
