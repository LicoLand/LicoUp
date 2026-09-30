//! Restore one archive into a target root.
//!
//! Restore never writes outside its target and never replaces an active root: the
//! caller supplies a disposable destination, inspects the result, and only then
//! promotes it. The destination is used under its resolved name, so a legitimate
//! destination reached through a symbolic link is accepted while every write stays
//! confined to it.
//!
//! The manifest is parsed, grammar-checked and limit-checked before any member is
//! extracted. Extraction runs in a private staging directory whose name can never
//! overlap a declared payload path, the extracted payload must match the declared
//! inventory exactly, and only then is it published into the target with rollback
//! tracking. Archive and manifest reads are bounded before decompression, so a
//! hostile container cannot make the importer allocate or inflate without limit.

use anyhow::{Result, anyhow, ensure};
use std::collections::BTreeSet;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::core::safe_archive::{
    ZipExtractionLimits, default_zip_extraction_limits, extract_tar_gz_safe, extract_zip_safe,
};
use crate::platform::file_security::{ensure_private_dir, harden_private_path, sync_directory};

use super::inventory::{
    ArchiveManifest, InventoryEntry, InventoryKind, RecoveryCoverage, RecoveryLimitation,
    posix_relative,
};
use super::{ArchiveContainer, MANIFEST_MEMBER};

/// Staging directory base name. The concrete name is chosen so it cannot equal or
/// contain any declared payload path; a payload may legitimately use this name.
const STAGING_DIRECTORY_BASE: &str = ".licoup-restore-staging";

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
    let limits = default_zip_extraction_limits();
    let bytes = read_archive_bounded(&request.archive_path, &limits)?;

    // The manifest is validated before any member is extracted or published, and before
    // the destination is touched: an archive refused on its own shape or limits leaves
    // the caller's destination exactly as it was.
    let manifest = read_manifest(&bytes, container, &limits)?;
    let target_root = prepare_target_root(&request.target_root)?;

    // Staging never overlaps a declared payload path, so its cleanup can never delete
    // an inventoried member.
    let staging = target_root.join(unique_staging_name(&manifest.entries));
    ensure_private_dir(&staging).map_err(|_| anyhow!("archive_target_unwritable"))?;
    let _staging = StagingDirectory {
        path: staging.clone(),
    };

    match container {
        ArchiveContainer::Zip => extract_zip_safe(&bytes, &staging, limits).map(|_| ()),
        ArchiveContainer::TarGz => extract_tar_gz_safe(&bytes, &staging, None, None, None),
    }
    .map_err(|_| anyhow!("archive_extraction_refused"))?;

    verify_payload(&staging, &manifest.entries)?;

    let mut publication = PublicationGuard::new(&target_root);
    publish_payload(
        &mut publication,
        &target_root,
        &staging,
        &manifest.entries,
        publish_entry,
    )?;
    // Durability completes before success; a failed sync rolls the publication back.
    sync_directory(&target_root).map_err(|_| anyhow!("archive_target_unwritable"))?;
    publication.disarm();

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
            fs::read_dir(named)
                .map_err(|_| anyhow!("archive_target_unreadable"))?
                .next()
                .is_none(),
            "archive_target_not_empty"
        );
    } else {
        fs::create_dir_all(named).map_err(|_| anyhow!("archive_target_unwritable"))?;
    }
    let resolved = named
        .canonicalize()
        .map_err(|_| anyhow!("archive_target_invalid"))?;
    // The restored data home and its staging are private, including a pre-existing
    // empty destination the caller prepared.
    ensure_private_dir(&resolved).map_err(|_| anyhow!("archive_target_unwritable"))?;
    Ok(resolved)
}

/// Read the archive only after its own byte limit has been applied to the file.
///
/// The read is additionally capped, so a file that grows after the metadata check
/// cannot make the importer allocate beyond the supported archive size.
fn read_archive_bounded(path: &Path, limits: &ZipExtractionLimits) -> Result<Vec<u8>> {
    let metadata = fs::metadata(path).map_err(|_| anyhow!("archive_unreadable"))?;
    ensure!(metadata.file_type().is_file(), "archive_unreadable");
    ensure!(
        metadata.len() <= limits.max_archive_bytes,
        "archive_extraction_refused"
    );
    let file = fs::File::open(path).map_err(|_| anyhow!("archive_unreadable"))?;
    let mut bytes = Vec::new();
    let mut bounded = file.take(limits.max_archive_bytes.saturating_add(1));
    bounded
        .read_to_end(&mut bytes)
        .map_err(|_| anyhow!("archive_unreadable"))?;
    ensure!(
        bytes.len() as u64 <= limits.max_archive_bytes,
        "archive_extraction_refused"
    );
    Ok(bytes)
}

fn read_manifest(
    bytes: &[u8],
    container: ArchiveContainer,
    limits: &ZipExtractionLimits,
) -> Result<ArchiveManifest> {
    match container {
        ArchiveContainer::Zip => {
            let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes))
                .map_err(|_| anyhow!("archive_invalid"))?;
            let mut member = archive
                .by_name(MANIFEST_MEMBER)
                .map_err(|_| anyhow!("archive_manifest_missing"))?;
            ensure!(
                member.size() <= limits.max_total_bytes,
                "archive_extraction_refused"
            );
            let mut buffer = Vec::new();
            let mut bounded = (&mut member).take(limits.max_total_bytes.saturating_add(1));
            bounded
                .read_to_end(&mut buffer)
                .map_err(|_| anyhow!("archive_manifest_unreadable"))?;
            ensure!(
                buffer.len() as u64 <= limits.max_total_bytes,
                "archive_extraction_refused"
            );
            ArchiveManifest::from_bytes(&buffer, container.extension())
        }
        ArchiveContainer::TarGz => read_tar_gz_manifest(bytes, container, limits),
    }
}

/// Find the manifest without inflating the archive beyond its declared limits.
///
/// A TAR manifest may follow other members, so the scan itself is the first thing a
/// hostile archive would grow. The decompressed scan budget and the entry count are
/// bounded by the same limits extraction and inventory validation use.
fn read_tar_gz_manifest(
    bytes: &[u8],
    container: ArchiveContainer,
    limits: &ZipExtractionLimits,
) -> Result<ArchiveManifest> {
    let decoder = flate2::read::GzDecoder::new(std::io::Cursor::new(bytes));
    let mut reader = BoundedReader::new(decoder, limits.max_total_bytes);
    let mut manifest_bytes: Option<Vec<u8>> = None;
    let mut scan_error: Option<anyhow::Error> = None;
    let mut entry_count = 0_usize;
    {
        let mut archive = tar::Archive::new(&mut reader);
        match archive.entries() {
            Err(_) => scan_error = Some(anyhow!("archive_invalid")),
            Ok(entries) => {
                for entry in entries {
                    entry_count += 1;
                    if entry_count > limits.max_entries {
                        scan_error = Some(anyhow!("archive_extraction_refused"));
                        break;
                    }
                    let mut entry = match entry {
                        Ok(entry) => entry,
                        Err(_) => {
                            scan_error = Some(anyhow!("archive_invalid"));
                            break;
                        }
                    };
                    let path = match entry.path() {
                        Ok(path) => path.to_path_buf(),
                        Err(_) => {
                            scan_error = Some(anyhow!("archive_invalid"));
                            break;
                        }
                    };
                    if path != Path::new(MANIFEST_MEMBER) {
                        continue;
                    }
                    if entry.size() > limits.max_total_bytes {
                        scan_error = Some(anyhow!("archive_extraction_refused"));
                        break;
                    }
                    let mut buffer = Vec::new();
                    let mut bounded = (&mut entry).take(limits.max_total_bytes.saturating_add(1));
                    if bounded.read_to_end(&mut buffer).is_err() {
                        scan_error = Some(anyhow!("archive_manifest_unreadable"));
                        break;
                    }
                    if buffer.len() as u64 > limits.max_total_bytes {
                        scan_error = Some(anyhow!("archive_extraction_refused"));
                        break;
                    }
                    manifest_bytes = Some(buffer);
                    break;
                }
            }
        }
    }
    if let Some(buffer) = manifest_bytes {
        return ArchiveManifest::from_bytes(&buffer, container.extension());
    }
    if reader.exceeded() {
        return Err(anyhow!("archive_extraction_refused"));
    }
    if let Some(error) = scan_error {
        return Err(error);
    }
    Err(anyhow!("archive_manifest_missing"))
}

/// A reader that refuses to hand out more than its budget and remembers that it did.
struct BoundedReader<R> {
    inner: R,
    remaining: u64,
    exceeded: bool,
}

impl<R> BoundedReader<R> {
    fn new(inner: R, limit: u64) -> Self {
        Self {
            inner,
            remaining: limit,
            exceeded: false,
        }
    }

    fn exceeded(&self) -> bool {
        self.exceeded
    }
}

impl<R: Read> Read for BoundedReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if self.remaining == 0 {
            self.exceeded = true;
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "archive scan limit exceeded",
            ));
        }
        let allowed = buffer
            .len()
            .min(usize::try_from(self.remaining).unwrap_or(usize::MAX));
        let read = self.inner.read(&mut buffer[..allowed])?;
        self.remaining -= read as u64;
        Ok(read)
    }
}

/// A staging name that cannot equal or contain any declared payload path.
///
/// A payload may legitimately contain a `.licoup-restore-staging` directory or file;
/// the suffix keeps the operation's scratch ownership disjoint from the payload.
fn unique_staging_name(entries: &[InventoryEntry]) -> String {
    let mut candidate = STAGING_DIRECTORY_BASE.to_string();
    let mut suffix = 1_u32;
    while entries
        .iter()
        .any(|entry| entry.path == candidate || entry.path.starts_with(&format!("{candidate}/")))
    {
        suffix += 1;
        candidate = format!("{STAGING_DIRECTORY_BASE}-{suffix}");
    }
    candidate
}

/// Every declared member exists with the declared kind and size, and no undeclared
/// member is present. A legitimately empty data home carries no payload members.
fn verify_payload(staging: &Path, entries: &[InventoryEntry]) -> Result<()> {
    let payload = staging.join("data");
    if entries.is_empty() {
        return match fs::symlink_metadata(&payload) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Ok(metadata) if metadata.file_type().is_dir() => {
                ensure!(
                    fs::read_dir(&payload)
                        .map_err(|_| anyhow!("archive_inventory_mismatch"))?
                        .next()
                        .is_none(),
                    "archive_inventory_mismatch"
                );
                Ok(())
            }
            _ => Err(anyhow!("archive_inventory_mismatch")),
        };
    }
    ensure!(payload.is_dir(), "archive_payload_missing");
    for entry in entries {
        let path = payload.join(&entry.path);
        let metadata =
            fs::symlink_metadata(&path).map_err(|_| anyhow!("archive_inventory_mismatch"))?;
        ensure!(
            !metadata.file_type().is_symlink(),
            "archive_inventory_mismatch"
        );
        match entry.kind {
            InventoryKind::Directory => {
                ensure!(metadata.file_type().is_dir(), "archive_inventory_mismatch");
            }
            InventoryKind::File => {
                ensure!(metadata.file_type().is_file(), "archive_inventory_mismatch");
                ensure!(metadata.len() == entry.size, "archive_inventory_mismatch");
            }
        }
    }
    let mut actual = Vec::new();
    collect_payload_paths(&payload, &payload, &mut actual)?;
    let declared: BTreeSet<&str> = entries.iter().map(|entry| entry.path.as_str()).collect();
    ensure!(
        actual.iter().all(|path| declared.contains(path.as_str())),
        "archive_inventory_mismatch"
    );
    Ok(())
}

fn collect_payload_paths(root: &Path, directory: &Path, paths: &mut Vec<String>) -> Result<()> {
    for entry in fs::read_dir(directory).map_err(|_| anyhow!("archive_inventory_mismatch"))? {
        let entry = entry.map_err(|_| anyhow!("archive_inventory_mismatch"))?;
        let child = entry.path();
        let metadata =
            fs::symlink_metadata(&child).map_err(|_| anyhow!("archive_inventory_mismatch"))?;
        ensure!(
            !metadata.file_type().is_symlink(),
            "archive_inventory_mismatch"
        );
        let relative = child
            .strip_prefix(root)
            .map_err(|_| anyhow!("archive_inventory_mismatch"))?;
        let path = posix_relative(relative).map_err(|_| anyhow!("archive_inventory_mismatch"))?;
        if metadata.file_type().is_dir() {
            paths.push(path);
            collect_payload_paths(root, &child, paths)?;
        } else {
            ensure!(metadata.file_type().is_file(), "archive_inventory_mismatch");
            paths.push(path);
        }
    }
    Ok(())
}

/// Publish the verified payload into the target, recording every published path so a
/// failure can roll back exactly the operation's own output.
fn publish_payload<F>(
    guard: &mut PublicationGuard<'_>,
    target: &Path,
    staging: &Path,
    entries: &[InventoryEntry],
    mut publish_one: F,
) -> Result<()>
where
    F: FnMut(&Path, &Path, bool) -> Result<()>,
{
    let extracted = staging.join("data");
    for entry in entries {
        let source = extracted.join(&entry.path);
        let destination = target.join(&entry.path);
        let directory = entry.kind == InventoryKind::Directory;
        publish_one(&source, &destination, directory)
            .map_err(|_| anyhow!("archive_target_unwritable"))?;
        guard.record(destination, directory);
    }
    Ok(())
}

/// Publish one verified member privately: create private directories, rename the file
/// in place, and harden the published file's permissions.
fn publish_entry(source: &Path, destination: &Path, directory: bool) -> Result<()> {
    if let Some(parent) = destination.parent() {
        ensure_private_dir(parent)?;
    }
    if directory {
        ensure_private_dir(destination)?;
    } else {
        fs::rename(source, destination)?;
        harden_private_path(destination)?;
    }
    Ok(())
}

/// Removes published entries in reverse order unless the publication completed.
struct PublicationGuard<'a> {
    target: &'a Path,
    published: Vec<(PathBuf, bool)>,
    armed: bool,
}

impl<'a> PublicationGuard<'a> {
    fn new(target: &'a Path) -> Self {
        Self {
            target,
            published: Vec::new(),
            armed: true,
        }
    }

    fn record(&mut self, path: PathBuf, directory: bool) {
        self.published.push((path, directory));
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for PublicationGuard<'_> {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        for (path, directory) in self.published.iter().rev() {
            // Rollback removes only paths this operation published below the target.
            if !path.starts_with(self.target) {
                continue;
            }
            if *directory {
                let _ = fs::remove_dir(path);
            } else {
                let _ = fs::remove_file(path);
            }
        }
    }
}

/// Removes the staging directory on every path; it is operation-owned scratch.
struct StagingDirectory {
    path: PathBuf,
}

impl Drop for StagingDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_entry(path: &str, size: u64) -> InventoryEntry {
        InventoryEntry {
            path: path.to_string(),
            kind: InventoryKind::File,
            size,
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("lico-restore-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create scratch");
        root
    }

    #[test]
    fn staging_names_never_overlap_declared_payload_paths() {
        let entries = vec![
            InventoryEntry {
                path: ".licoup-restore-staging/keep.bin".to_string(),
                kind: InventoryKind::File,
                size: 1,
            },
            InventoryEntry {
                path: ".licoup-restore-staging-2/keep.bin".to_string(),
                kind: InventoryKind::File,
                size: 1,
            },
        ];
        let name = unique_staging_name(&entries);
        assert_ne!(name, ".licoup-restore-staging");
        assert_ne!(name, ".licoup-restore-staging-2");
        assert_eq!(name, ".licoup-restore-staging-3");
    }

    #[test]
    fn bounded_reader_stops_at_its_budget() {
        let mut reader = BoundedReader::new(std::io::repeat(0_u8), 8);
        let mut buffer = [0_u8; 16];
        let mut total = 0_usize;
        loop {
            match reader.read(&mut buffer) {
                Ok(read) => {
                    total += read;
                }
                Err(error) => {
                    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
                    break;
                }
            }
        }
        assert_eq!(total, 8);
        assert!(reader.exceeded());
    }

    #[test]
    fn publication_failure_rolls_back_only_published_entries() {
        let root = scratch("publication");
        fs::create_dir_all(root.join("staging/data")).expect("create staging");
        fs::write(root.join("staging/data/first.txt"), b"first").expect("first");
        fs::write(root.join("staging/data/second.txt"), b"second").expect("second");
        let entries = vec![file_entry("first.txt", 5), file_entry("second.txt", 6)];
        let mut guard = PublicationGuard::new(&root);
        let mut calls = 0_usize;
        let result = publish_payload(
            &mut guard,
            &root,
            &root.join("staging"),
            &entries,
            |source, destination, _directory| {
                calls += 1;
                if calls == 2 {
                    return Err(anyhow!("injected publication failure"));
                }
                fs::rename(source, destination)?;
                Ok(())
            },
        );
        assert!(result.is_err());
        drop(guard);
        assert!(!root.join("first.txt").exists());
        assert!(!root.join("second.txt").exists());
        fs::remove_dir_all(root).expect("remove scratch");
    }

    #[test]
    fn an_injected_reader_fault_propagates_through_the_scan() {
        struct FaultyReader {
            remaining: usize,
        }
        impl Read for FaultyReader {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                if self.remaining == 0 {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "injected read fault",
                    ));
                }
                let read = buffer.len().min(self.remaining);
                self.remaining -= read;
                buffer[..read].fill(0);
                Ok(read)
            }
        }
        let mut reader = BoundedReader::new(FaultyReader { remaining: 4 }, 8);
        let mut buffer = [0_u8; 2];
        assert_eq!(reader.read(&mut buffer).expect("first read"), 2);
        assert_eq!(reader.read(&mut buffer).expect("second read"), 2);
        assert!(reader.read(&mut buffer).is_err());
    }
}
