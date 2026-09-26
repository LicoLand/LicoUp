//! Export and import the complete data root.
//!
//! Neither verb implements archiving. Both route to the client's own full-data-root
//! archive owner in `licoup_native::core::full_data_root_archive`, which captures the
//! inventory, writes the plaintext container, verifies every member against its manifest
//! and only then publishes a restore. This module marshals the caller's options and
//! renders the owner's own outcome, so the container format, the inventory and the
//! recovery-coverage rule keep exactly one authority; a second implementation here would
//! be a second answer to "what is inside the archive".
//!
//! Two rules belong to the owner and are reported without reinterpretation: a capture
//! requires the caller's statement that every writer is stopped, and a restore requires
//! an empty destination and a manifest that matches every member. A refusal therefore
//! publishes nothing and is never rendered as a completed export or import.

use crate::error::{ARCHIVE_INSIDE_DATA_ROOT, ToolError, ToolResult};
use licoup_native::core::full_data_root_archive::{
    export_data_root, restore_data_root, ExportRequest, RecoveryCoverage, RecoveryLimitation,
    RestoreRequest,
};
use serde::Serialize;
use std::path::{Path, PathBuf};

/// Export refused because the caller did not state that every writer is stopped.
pub const ARCHIVE_WRITERS_RUNNING: ToolError = ToolError::new("archive_writers_running");
/// The archive name does not name a supported plaintext container.
pub const ARCHIVE_CONTAINER_UNSUPPORTED: ToolError =
    ToolError::new("archive_container_unsupported");
/// Import refused because the destination already holds something.
pub const ARCHIVE_TARGET_NOT_EMPTY: ToolError = ToolError::new("archive_target_not_empty");
/// A refusal this tool does not recognise, reported without the owner's message.
pub const ARCHIVE_REFUSED: ToolError = ToolError::new("archive_refused");

/// Every refusal the native owner reports, passed through unchanged.
///
/// The owner's failures are its own stable codes and its leading token already names one.
/// Echoing only a token from this list keeps that vocabulary in one place and keeps the
/// tool honest about what it can explain: an unexpected failure — whose message may name
/// a local path — collapses to [`ARCHIVE_REFUSED`] instead of leaking the machine the
/// tool ran on.
const OWNER_REFUSALS: &[&str] = &[
    "archive_admission_unavailable",
    "archive_container_unsupported",
    "archive_coverage_invalid",
    "archive_destination_unwritable",
    "archive_extraction_refused",
    "archive_invalid",
    "archive_inventory_mismatch",
    "archive_inventory_path_invalid",
    "archive_layout_unsupported",
    "archive_manifest_invalid",
    "archive_manifest_missing",
    "archive_manifest_unencodable",
    "archive_manifest_unreadable",
    "archive_path_invalid",
    "archive_payload_missing",
    "archive_target_invalid",
    "archive_target_not_directory",
    "archive_target_not_empty",
    "archive_target_unreadable",
    "archive_target_unwritable",
    "archive_unreadable",
    "archive_write_failed",
    "archive_writers_running",
    "data_root_entry_outside_root",
    "data_root_entry_unreadable",
    "data_root_missing",
    "data_root_path_empty",
    "data_root_path_not_utf8",
    "data_root_path_unsafe",
    "data_root_unreadable",
];

/// One completed capture, as the client's own owner reported it.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportReport {
    pub status: &'static str,
    /// `zip` or `tar.gz`, inferred from the archive name by the owner.
    pub container: &'static str,
    /// Whether every application-owned store and exportable credential travelled.
    pub coverage: RecoveryCoverage,
    /// The named domains this archive cannot restore.
    pub limitations: Vec<RecoveryLimitation>,
    pub file_count: usize,
    pub total_bytes: u64,
}

/// One completed restore, as the client's own owner verified and reported it.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportReport {
    pub status: &'static str,
    pub container: &'static str,
    /// The coverage the archive itself declares.
    pub coverage: RecoveryCoverage,
    /// The named domains the restored root does not carry.
    pub limitations: Vec<RecoveryLimitation>,
    pub file_count: usize,
    pub total_bytes: u64,
}

/// Capture one data root into a plaintext archive.
///
/// `writers_stopped` is the caller's statement that every writer, including older
/// clients, has stopped. The owner refuses the capture without it and creates the
/// destination only after the refusal, so an unconfirmed or failed export never leaves
/// behind a file that could be mistaken for a backup.
///
/// The destination is refused before the owner runs when it sits inside the root being
/// captured. The owner creates the destination before it inventories the root, so an
/// archive named inside the root is captured as a member of itself and a restore would
/// then write that archive back into the restored root. A capture that cannot describe
/// the root as it was before the capture is not a backup of it.
pub fn export(
    data_root: &Path,
    archive_path: &Path,
    writers_stopped: bool,
) -> ToolResult<ExportReport> {
    if archive_sits_inside(data_root, archive_path) {
        return Err(ARCHIVE_INSIDE_DATA_ROOT);
    }

    let outcome = export_data_root(&ExportRequest {
        data_root: data_root.to_path_buf(),
        archive_path: archive_path.to_path_buf(),
        writers_stopped,
    })
    .map_err(|error| refusal(&error))?;

    Ok(ExportReport {
        status: "exported",
        container: outcome.container.extension(),
        coverage: outcome.coverage,
        limitations: outcome.limitations,
        file_count: outcome.file_count,
        total_bytes: outcome.total_bytes,
    })
}

/// Restore one archive into an empty destination.
///
/// The owner extracts into its own staging area, verifies every declared member against
/// the archive manifest, and only then publishes into `target_root`; a destination that
/// already holds anything is refused. This tool reports that verdict and never promotes
/// a partial restore itself.
pub fn import(archive_path: &Path, target_root: &Path) -> ToolResult<ImportReport> {
    let outcome = restore_data_root(&RestoreRequest {
        archive_path: archive_path.to_path_buf(),
        target_root: target_root.to_path_buf(),
    })
    .map_err(|error| refusal(&error))?;

    Ok(ImportReport {
        status: "imported",
        container: outcome.container.extension(),
        coverage: outcome.coverage,
        limitations: outcome.limitations,
        file_count: outcome.file_count,
        total_bytes: outcome.total_bytes,
    })
}

/// Whether the destination archive sits inside the root a capture would read.
///
/// The root's own path counts as inside it: a capture cannot write over the thing it is
/// describing, so the conservative answer is the safe one.
/// A path that does not exist yet is resolved through its nearest existing ancestor, so
/// a symbolic link anywhere above the destination is seen the same way the owner will see
/// it when it opens the file.
fn archive_sits_inside(data_root: &Path, archive_path: &Path) -> bool {
    let (Ok(root), Some(destination)) = (
        data_root.canonicalize(),
        resolve_for_comparison(archive_path),
    ) else {
        // An unresolvable destination is not this check's refusal: the owner reports the
        // destination it cannot write, with its own code.
        return false;
    };
    destination.starts_with(&root)
}

/// Resolve one path for comparison, following the ancestors that exist.
fn resolve_for_comparison(path: &Path) -> Option<PathBuf> {
    let mut existing = path.to_path_buf();
    let mut suffix: Vec<std::ffi::OsString> = Vec::new();
    loop {
        if existing.exists() {
            let mut resolved = existing.canonicalize().ok()?;
            while let Some(component) = suffix.pop() {
                resolved.push(component);
            }
            return Some(resolved);
        }
        let name = existing.file_name()?.to_os_string();
        suffix.push(name);
        if !existing.pop() {
            return None;
        }
    }
}

/// Reduce one owner failure to a stable code, never to its message.
///
/// The owner raises two shapes of message: a bare code, and a code carrying a context
/// (`<code>: <detail>`). Both are read as their leading token, so the tool repeats the
/// owner's own vocabulary and never its detail.
fn refusal(error: &anyhow::Error) -> ToolError {
    let message = error.to_string();
    let code = message
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .trim_end_matches(':');
    match OWNER_REFUSALS.iter().find(|known| **known == code).copied() {
        Some(known) => ToolError::new(known),
        None => ARCHIVE_REFUSED,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_known_refusal_keeps_the_owner_code_and_drops_its_message() {
        let error = anyhow::anyhow!(
            "archive_admission_unavailable: Permission denied (os error 13) at \
             /Users/maintainer/Library/Application Support/LicoUp"
        );
        let refusal = refusal(&error);
        assert_eq!(refusal.code(), "archive_admission_unavailable");
        assert!(!refusal.to_string().contains("maintainer"));
    }

    #[test]
    fn an_unrecognised_refusal_carries_no_message_and_no_path() {
        let error = anyhow::anyhow!("sqlite error at /Users/maintainer/private/state.db");
        let refusal = refusal(&error);
        assert_eq!(refusal, ARCHIVE_REFUSED);
        assert_eq!(refusal.code(), "archive_refused");
        assert!(!refusal.to_string().contains("maintainer"));
    }

    #[test]
    fn the_passed_through_codes_are_stable_tokens() {
        for code in OWNER_REFUSALS {
            assert!(
                !code.is_empty()
                    && code
                        .bytes()
                        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'),
                "{code} is not a stable code token"
            );
        }
        let mut sorted = OWNER_REFUSALS.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), OWNER_REFUSALS.len(), "codes are unique");
    }

    /// A disposable base directory with a real root and a sibling archive directory.
    fn scratch_base(label: &str) -> PathBuf {
        let base = std::env::temp_dir()
            .canonicalize()
            .expect("temp dir")
            .join(format!("licoup-archive-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("root")).expect("create root");
        std::fs::create_dir_all(base.join("archives")).expect("create archives directory");
        base
    }

    #[test]
    fn a_destination_inside_the_captured_root_is_recognised() {
        let base = scratch_base("inside");
        let root = base.join("root");

        assert!(archive_sits_inside(&root, &root.join("backup.zip")));
        // The destination does not exist yet, so its nearest existing ancestor is what
        // decides whether it is inside the root.
        assert!(archive_sits_inside(
            &root,
            &root.join("nested/deeper/backup.tar.gz")
        ));
        // The root itself is inside itself, and its parent is not.
        assert!(archive_sits_inside(&root, &root));
        assert!(!archive_sits_inside(&root, &base.join("archives/backup.zip")));
        // A sibling whose name merely starts with the root's name is not inside it.
        let lookalike = base.join("root-copy");
        std::fs::create_dir_all(&lookalike).expect("create lookalike");
        assert!(!archive_sits_inside(&root, &lookalike.join("backup.zip")));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_destination_reached_through_a_link_is_still_inside_the_root() {
        let base = scratch_base("link");
        let root = base.join("root");
        let link = base.join("link-to-root");
        std::os::unix::fs::symlink(&root, &link).expect("create link");

        assert!(
            archive_sits_inside(&root, &link.join("backup.zip")),
            "a linked destination resolves into the root the owner will read"
        );
        let _ = std::fs::remove_dir_all(&base);
    }
}
