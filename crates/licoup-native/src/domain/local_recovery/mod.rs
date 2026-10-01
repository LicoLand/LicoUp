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
/// The generic restore owns publication and its refusals. Afterwards this composition
/// rebases owner-managed references when the target differs from the captured logical
/// source home, then re-establishes and verifies the workflow revision protections
/// through their owner. A verification failure after publication removes a destination
/// this call created, so the caller is never told a root is usable when an owner
/// refused it.
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

    let source_home = std::path::absolute(&outcome.source_home)
        .map_err(|_| anyhow!("backup_source_home_unresolved"))?;
    let relocated = source_home != target_root;
    let verification = (|| -> Result<Vec<String>> {
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
            if created_target {
                let _ = std::fs::remove_dir_all(&target_root);
            }
            Err(error)
        }
    }
}
