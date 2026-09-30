//! Restore one archive into a target root.
//!
//! Restore never writes outside its target and never replaces an active root: the
//! caller supplies a disposable destination, inspects the result, and only then
//! promotes it. The destination is used under its resolved name, so a legitimate
//! destination reached through a symbolic link is accepted while every write stays
//! confined to it. Extraction reuses the existing safe-archive rules, so traversal
//! members, links and special entries are refused before anything is published.

use anyhow::{Result, anyhow, ensure};
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::core::safe_archive::{
    default_zip_extraction_limits, extract_tar_gz_safe, extract_zip_safe,
};

use super::inventory::{
    ArchiveManifest, InventoryEntry, InventoryKind, RecoveryCoverage, RecoveryLimitation,
};
use super::{ArchiveContainer, MANIFEST_MEMBER};

#[derive(Clone, Debug)]
pub struct RestoreRequest {
    pub archive_path: PathBuf,
    /// Disposable destination. It is created when absent and must be empty.
    pub target_root: PathBuf,
}

#[derive(Clone, Debug)]
pub struct RestoreOutcome {
    pub container: ArchiveContainer,
    pub coverage: RecoveryCoverage,
    pub limitations: Vec<RecoveryLimitation>,
    pub file_count: usize,
    pub total_bytes: u64,
}

/// Extract `archive_path` into `target_root` and verify it against its manifest.
pub fn restore_data_root(request: &RestoreRequest) -> Result<RestoreOutcome> {
    let container = ArchiveContainer::from_path(&request.archive_path)?;
    let target_root = prepare_target_root(&request.target_root)?;

    let bytes = std::fs::read(&request.archive_path).map_err(|_| anyhow!("archive_unreadable"))?;

    // The manifest is validated before any member is published.
    let manifest = read_manifest(&bytes, container)?;

    let staging = target_root.join(".licoup-restore-staging");
    if staging.exists() {
        std::fs::remove_dir_all(&staging).map_err(|_| anyhow!("archive_target_unwritable"))?;
    }
    std::fs::create_dir_all(&staging).map_err(|_| anyhow!("archive_target_unwritable"))?;

    match container {
        ArchiveContainer::Zip => {
            extract_zip_safe(&bytes, &staging, default_zip_extraction_limits())
                .map_err(|_| anyhow!("archive_extraction_refused"))?;
        }
        ArchiveContainer::TarGz => {
            extract_tar_gz_safe(&bytes, &staging, None, None, None)
                .map_err(|_| anyhow!("archive_extraction_refused"))?;
        }
    }

    let extracted_root = staging.join("data");
    ensure!(extracted_root.is_dir(), "archive_payload_missing");

    verify_members(&extracted_root, &manifest.entries)?;

    // Publish only after every member matched the declared inventory.
    for entry in &manifest.entries {
        let source = extracted_root.join(&entry.path);
        let destination = target_root.join(&entry.path);
        match entry.kind {
            InventoryKind::Directory => {
                std::fs::create_dir_all(&destination)
                    .map_err(|_| anyhow!("archive_target_unwritable"))?;
            }
            InventoryKind::File => {
                if let Some(parent) = destination.parent() {
                    std::fs::create_dir_all(parent)
                        .map_err(|_| anyhow!("archive_target_unwritable"))?;
                }
                std::fs::rename(&source, &destination)
                    .or_else(|_| std::fs::copy(&source, &destination).map(|_| ()))
                    .map_err(|_| anyhow!("archive_target_unwritable"))?;
            }
        }
    }
    std::fs::remove_dir_all(&staging).map_err(|_| anyhow!("archive_target_unwritable"))?;

    Ok(RestoreOutcome {
        container,
        coverage: manifest.coverage,
        limitations: manifest.limitations.clone(),
        file_count: manifest.file_count(),
        total_bytes: manifest.total_bytes,
    })
}

/// The destination the caller named, created when absent and returned under its resolved name.
///
/// A directory reached through a symbolic link is the same destination under another
/// name. The operator names the destination, so the owner resolves it instead of
/// refusing a legitimate one whose ancestor chain passes through a link, as the system
/// temporary directory does on macOS. Extraction and publication then use the resolved
/// name, which keeps every write confined to the destination the caller named. A name
/// that does not resolve to exactly one directory stays refused.
fn prepare_target_root(named: &Path) -> Result<PathBuf> {
    ensure!(!named.as_os_str().is_empty(), "archive_target_invalid");
    if named.exists() {
        ensure!(named.is_dir(), "archive_target_not_directory");
        ensure!(
            std::fs::read_dir(named)
                .map_err(|_| anyhow!("archive_target_unreadable"))?
                .next()
                .is_none(),
            "archive_target_not_empty"
        );
    } else {
        std::fs::create_dir_all(named).map_err(|_| anyhow!("archive_target_unwritable"))?;
    }
    named
        .canonicalize()
        .map_err(|_| anyhow!("archive_target_invalid"))
}

fn read_manifest(bytes: &[u8], container: ArchiveContainer) -> Result<ArchiveManifest> {
    let raw = match container {
        ArchiveContainer::Zip => {
            let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes))
                .map_err(|_| anyhow!("archive_invalid"))?;
            let mut member = archive
                .by_name(MANIFEST_MEMBER)
                .map_err(|_| anyhow!("archive_manifest_missing"))?;
            let mut buffer = Vec::new();
            member
                .read_to_end(&mut buffer)
                .map_err(|_| anyhow!("archive_manifest_unreadable"))?;
            buffer
        }
        ArchiveContainer::TarGz => {
            let decoder = flate2::read::GzDecoder::new(std::io::Cursor::new(bytes));
            let mut archive = tar::Archive::new(decoder);
            let mut buffer = Vec::new();
            let entries = archive.entries().map_err(|_| anyhow!("archive_invalid"))?;
            for entry in entries {
                let mut entry = entry.map_err(|_| anyhow!("archive_invalid"))?;
                let path = entry
                    .path()
                    .map_err(|_| anyhow!("archive_invalid"))?
                    .to_path_buf();
                if path == Path::new(MANIFEST_MEMBER) {
                    entry
                        .read_to_end(&mut buffer)
                        .map_err(|_| anyhow!("archive_manifest_unreadable"))?;
                    return ArchiveManifest::from_bytes(&buffer);
                }
            }
            return Err(anyhow!("archive_manifest_missing"));
        }
    };
    ArchiveManifest::from_bytes(&raw)
}

/// Every declared member must exist with the declared kind and size.
fn verify_members(root: &Path, entries: &[InventoryEntry]) -> Result<()> {
    for entry in entries {
        let path = root.join(&entry.path);
        let metadata =
            std::fs::symlink_metadata(&path).map_err(|_| anyhow!("archive_inventory_mismatch"))?;
        ensure!(!metadata.is_symlink(), "archive_inventory_mismatch");
        match entry.kind {
            InventoryKind::Directory => ensure!(metadata.is_dir(), "archive_inventory_mismatch"),
            InventoryKind::File => {
                ensure!(metadata.is_file(), "archive_inventory_mismatch");
                ensure!(metadata.len() == entry.size, "archive_inventory_mismatch");
            }
        }
    }
    Ok(())
}
