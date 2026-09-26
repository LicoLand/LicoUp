//! The archive inventory.
//!
//! The inventory is derived from the data root itself and from the owners that
//! write into it. It never enumerates unrelated operating-system credentials, and
//! it never treats an opaque platform key handle as a portable secret.

use anyhow::{anyhow, ensure, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Archive layout identifier. A restore refuses any other value.
pub const ARCHIVE_LAYOUT: &str = "licoup.full-data-root/v1";

/// One captured entry.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct InventoryEntry {
    /// POSIX-relative path inside the data root.
    pub path: String,
    pub kind: InventoryKind,
    /// Uncompressed byte length for a file entry.
    #[serde(default)]
    pub size: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum InventoryKind {
    File,
    Directory,
}

/// What the maintainer is told about recovery completeness.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RecoveryCoverage {
    /// Every application-owned store and exportable credential was captured.
    Complete,
    /// The archive is usable, but a named domain cannot be recovered from it.
    Limited,
}

/// A domain whose secrets cannot travel in a portable archive.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RecoveryLimitation {
    /// Stable domain identifier, for example `gateway-credential-custody`.
    pub domain: String,
    /// Why the domain cannot be recovered from this archive.
    pub reason: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ArchiveManifest {
    pub layout: String,
    pub container: String,
    pub created_at_unix: u64,
    pub coverage: RecoveryCoverage,
    #[serde(default)]
    pub limitations: Vec<RecoveryLimitation>,
    pub entries: Vec<InventoryEntry>,
    /// Total uncompressed bytes across file entries.
    pub total_bytes: u64,
}

impl ArchiveManifest {
    pub(crate) fn new(
        container: &str,
        coverage: RecoveryCoverage,
        limitations: Vec<RecoveryLimitation>,
        entries: Vec<InventoryEntry>,
    ) -> Self {
        let total_bytes = entries
            .iter()
            .filter(|entry| entry.kind == InventoryKind::File)
            .map(|entry| entry.size)
            .sum();
        Self {
            layout: ARCHIVE_LAYOUT.to_string(),
            container: container.to_string(),
            created_at_unix: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|elapsed| elapsed.as_secs())
                .unwrap_or_default(),
            coverage,
            limitations,
            entries,
            total_bytes,
        }
    }

    pub(crate) fn file_count(&self) -> usize {
        self.entries
            .iter()
            .filter(|entry| entry.kind == InventoryKind::File)
            .count()
    }

    pub(crate) fn validate(&self) -> Result<()> {
        ensure!(
            self.layout == ARCHIVE_LAYOUT,
            "archive_layout_unsupported"
        );
        ensure!(
            matches!(self.coverage, RecoveryCoverage::Complete | RecoveryCoverage::Limited),
            "archive_coverage_invalid"
        );
        for entry in &self.entries {
            ensure!(
                !entry.path.is_empty()
                    && !entry.path.starts_with('/')
                    && !entry.path.split('/').any(|part| part == ".." || part.is_empty()),
                "archive_inventory_path_invalid"
            );
        }
        Ok(())
    }

    pub(crate) fn to_bytes(&self) -> Result<Vec<u8>> {
        serde_json::to_vec_pretty(self).map_err(|_| anyhow!("archive_manifest_unencodable"))
    }

    pub(crate) fn from_bytes(bytes: &[u8]) -> Result<Self> {
        let manifest: Self =
            serde_json::from_slice(bytes).map_err(|_| anyhow!("archive_manifest_invalid"))?;
        manifest.validate()?;
        Ok(manifest)
    }
}

/// Inventory of one data root, in deterministic order.
///
/// Symbolic links are not followed and are not captured: an archive carries the
/// client's own files, not whatever a link happens to point at.
pub(crate) fn inventory_data_root(root: &Path) -> Result<Vec<InventoryEntry>> {
    ensure!(root.is_dir(), "data_root_missing");
    let mut entries = Vec::new();
    walk(root, root, &mut entries)?;
    entries.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(entries)
}

fn walk(root: &Path, directory: &Path, entries: &mut Vec<InventoryEntry>) -> Result<()> {
    let mut children: Vec<PathBuf> = std::fs::read_dir(directory)
        .map_err(|_| anyhow!("data_root_unreadable"))?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .collect();
    children.sort();
    for child in children {
        let metadata = std::fs::symlink_metadata(&child)
            .map_err(|_| anyhow!("data_root_entry_unreadable"))?;
        let relative = child
            .strip_prefix(root)
            .map_err(|_| anyhow!("data_root_entry_outside_root"))?;
        let path = posix_relative(relative)?;
        if metadata.is_symlink() {
            // A link is deliberately absent from the inventory; a restore of this
            // archive therefore produces ordinary files and directories only.
            continue;
        }
        if metadata.is_dir() {
            entries.push(InventoryEntry {
                path: path.clone(),
                kind: InventoryKind::Directory,
                size: 0,
            });
            walk(root, &child, entries)?;
        } else if metadata.is_file() {
            entries.push(InventoryEntry {
                path,
                kind: InventoryKind::File,
                size: metadata.len(),
            });
        }
    }
    Ok(())
}

fn posix_relative(relative: &Path) -> Result<String> {
    let mut parts = Vec::new();
    for component in relative.components() {
        match component {
            std::path::Component::Normal(name) => {
                let name = name
                    .to_str()
                    .ok_or_else(|| anyhow!("data_root_path_not_utf8"))?;
                parts.push(name.to_string());
            }
            _ => return Err(anyhow!("data_root_path_unsafe")),
        }
    }
    ensure!(!parts.is_empty(), "data_root_path_empty");
    Ok(parts.join("/"))
}
