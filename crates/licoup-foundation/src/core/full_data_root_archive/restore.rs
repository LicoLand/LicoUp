//! Restore one archive into a target root.
//!
//! Restore never writes outside its target and never replaces an active root: the
//! caller supplies a disposable destination, inspects the result, and only then
//! promotes it. The destination is used under its resolved name, so a legitimate
//! destination reached through a symbolic link is accepted while every write stays
//! confined to it.
//!
//! The manifest is parsed, grammar-checked and limit-checked before any member is
//! extracted. Inspection and extraction both read the archive through the same bounded
//! decoded stream, the whole raw member list is compared against the declared
//! inventory, and extraction runs in a private staging directory whose name is chosen
//! outside every case-normalized declared path. Publication records each side effect
//! before it happens and rolls back with checked cleanup, so a reported failure leaves
//! the target in its prior recoverable state.

use anyhow::{Result, anyhow, ensure};
use std::collections::BTreeSet;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::core::safe_archive::{
    BoundedStream, ZipExtractionLimits, decoded_tar_gz_budget, default_zip_extraction_limits,
    extract_tar_gz_safe, extract_zip_safe,
};
use crate::platform::file_security::{ensure_private_dir, harden_private_path, sync_directory};

use super::inventory::{ArchiveManifest, InventoryEntry, InventoryKind, posix_relative};
use super::{ArchiveContainer, DATA_PREFIX, MANIFEST_MEMBER, RecoveryCoverage, RecoveryLimitation};

/// Staging directory base name. The concrete name is chosen so it cannot equal or
/// contain any declared payload path under the target's case normalization; a payload
/// may legitimately use this name in any letter case.
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

/// One inspected archive: its validated manifest, the manifest member's own bytes, and
/// every raw member name the container declares.
struct InspectedArchive {
    manifest: ArchiveManifest,
    manifest_member_bytes: u64,
    members: Vec<String>,
}

/// Extract `archive_path` into `target_root` and verify it against its manifest.
pub fn restore_data_root(request: &RestoreRequest) -> Result<RestoreOutcome> {
    let container = ArchiveContainer::from_path(&request.archive_path)?;
    let limits = default_zip_extraction_limits();
    let bytes = read_archive_bounded(&request.archive_path, &limits)?;
    // Manifest validation and raw member collection happen before the destination is
    // touched: an archive refused on its own shape leaves the caller's target as it was.
    let inspected = inspect_archive(&bytes, container, &limits)?;

    // Extraction enforces exactly what the manifest declares: its payload plus its own
    // manifest member, and the declared member count.
    let declared_stream_bytes = inspected
        .manifest
        .total_bytes
        .saturating_add(inspected.manifest_member_bytes);
    let declared_member_count = inspected.manifest.entries.len().saturating_add(1);

    let target_root = prepare_target_root(&request.target_root)?;
    let staging = target_root.join(unique_staging_name(&inspected.manifest.entries));
    ensure_private_dir(&staging).map_err(|_| anyhow!("archive_target_unwritable"))?;
    let mut staging_directory = StagingDirectory {
        path: staging.clone(),
        cleaned: false,
    };

    let extraction = match container {
        ArchiveContainer::Zip => extract_zip_safe(
            &bytes,
            &staging,
            ZipExtractionLimits {
                max_total_bytes: declared_stream_bytes,
                max_entries: declared_member_count,
                ..limits
            },
        )
        .map(|_| ()),
        ArchiveContainer::TarGz => extract_tar_gz_safe(
            &bytes,
            &staging,
            Some(declared_stream_bytes),
            Some(declared_member_count),
            Some(limits.max_depth),
        ),
    };
    if extraction.is_err() {
        return Err(staging_directory.fail(anyhow!("archive_extraction_refused")));
    }

    // The whole archive inventory must match the declared members, not only what
    // extraction happened to materialize, and the materialized payload must match the
    // declared kinds and sizes before anything is published.
    if let Err(error) = verify_raw_members(&inspected.members, &inspected.manifest) {
        return Err(staging_directory.fail(error));
    }
    if let Err(error) = verify_payload(&staging, &inspected.manifest.entries) {
        return Err(staging_directory.fail(error));
    }

    let mut publication = PublicationGuard::new(&target_root);
    if let Err(error) = publish_payload(
        &mut publication,
        &target_root,
        &staging,
        &inspected.manifest.entries,
        publish_entry,
    ) {
        let error = publication.fail(error);
        return Err(staging_directory.fail(error));
    }
    if let Err(error) = publication.sync_changed_directories() {
        let error = publication.fail(error);
        return Err(staging_directory.fail(error));
    }
    // Checked operation-owned scratch removal, then the final root sync that makes the
    // published tree and the removal durable. A cleanup failure is reported rather than
    // silently leaving scratch behind; the payload itself is already complete.
    staging_directory.cleanup()?;
    if let Err(error) =
        sync_directory(&target_root).map_err(|_| anyhow!("archive_target_unwritable"))
    {
        return Err(publication.fail(error));
    }
    publication.disarm();

    Ok(RestoreOutcome {
        container,
        coverage: inspected.manifest.coverage,
        limitations: inspected.manifest.limitations.clone(),
        file_count: inspected.manifest.file_count(),
        total_bytes: inspected.manifest.total_bytes,
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

fn inspect_archive(
    bytes: &[u8],
    container: ArchiveContainer,
    limits: &ZipExtractionLimits,
) -> Result<InspectedArchive> {
    match container {
        ArchiveContainer::Zip => inspect_zip(bytes, limits),
        ArchiveContainer::TarGz => inspect_tar_gz(bytes, limits),
    }
}

fn inspect_zip(bytes: &[u8], limits: &ZipExtractionLimits) -> Result<InspectedArchive> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes))
        .map_err(|_| anyhow!("archive_invalid"))?;
    ensure!(
        archive.len() <= limits.max_entries,
        "archive_extraction_refused"
    );

    let mut member = archive
        .by_name(MANIFEST_MEMBER)
        .map_err(|_| anyhow!("archive_manifest_missing"))?;
    ensure!(
        member.size() <= limits.max_total_bytes,
        "archive_extraction_refused"
    );
    let mut manifest_bytes = Vec::new();
    let mut bounded = (&mut member).take(limits.max_total_bytes.saturating_add(1));
    bounded
        .read_to_end(&mut manifest_bytes)
        .map_err(|_| anyhow!("archive_manifest_unreadable"))?;
    ensure!(
        manifest_bytes.len() as u64 <= limits.max_total_bytes,
        "archive_extraction_refused"
    );
    drop(member);

    let mut members = Vec::with_capacity(archive.len());
    for index in 0..archive.len() {
        let entry = archive
            .by_index(index)
            .map_err(|_| anyhow!("archive_invalid"))?;
        let name = std::str::from_utf8(entry.name_raw()).map_err(|_| anyhow!("archive_invalid"))?;
        members.push(name.trim_end_matches('/').to_string());
    }

    let manifest_member_bytes = manifest_bytes.len() as u64;
    let manifest = ArchiveManifest::from_bytes(&manifest_bytes, ArchiveContainer::Zip.extension())?;
    Ok(InspectedArchive {
        manifest,
        manifest_member_bytes,
        members,
    })
}

/// Find the manifest and collect the whole member inventory in one bounded pass.
///
/// A TAR manifest may follow other members, so the scan itself is the first thing a
/// hostile archive would grow. The physical decoded stream is bounded before the TAR
/// library can buffer GNU or PAX extension metadata, and the entry count uses the same
/// policy extraction and inventory validation use.
fn inspect_tar_gz(bytes: &[u8], limits: &ZipExtractionLimits) -> Result<InspectedArchive> {
    let decoder = flate2::read::GzDecoder::new(std::io::Cursor::new(bytes));
    let budget =
        decoded_tar_gz_budget(limits.max_total_bytes, limits.max_entries, limits.max_depth);
    let mut stream = BoundedStream::new(decoder, budget);
    let mut manifest_bytes: Option<Vec<u8>> = None;
    let mut members = Vec::new();
    let mut scan_error: Option<anyhow::Error> = None;
    let mut entry_count = 0_usize;
    {
        let mut archive = tar::Archive::new(&mut stream);
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
                        Ok(path) => path,
                        Err(_) => {
                            scan_error = Some(anyhow!("archive_invalid"));
                            break;
                        }
                    };
                    let name = match path.to_str() {
                        Some(name) => name.trim_end_matches('/').to_string(),
                        None => {
                            scan_error = Some(anyhow!("archive_extraction_refused"));
                            break;
                        }
                    };
                    if name == MANIFEST_MEMBER {
                        if entry.size() > limits.max_total_bytes {
                            scan_error = Some(anyhow!("archive_extraction_refused"));
                            break;
                        }
                        let mut buffer = Vec::new();
                        let mut bounded =
                            (&mut entry).take(limits.max_total_bytes.saturating_add(1));
                        if bounded.read_to_end(&mut buffer).is_err() {
                            scan_error = Some(anyhow!("archive_manifest_unreadable"));
                            break;
                        }
                        if buffer.len() as u64 > limits.max_total_bytes {
                            scan_error = Some(anyhow!("archive_extraction_refused"));
                            break;
                        }
                        manifest_bytes = Some(buffer);
                    }
                    members.push(name);
                }
            }
        }
    }
    if stream.exceeded() {
        return Err(anyhow!("archive_extraction_refused"));
    }
    if let Some(error) = scan_error {
        return Err(error);
    }
    let manifest_bytes = manifest_bytes.ok_or_else(|| anyhow!("archive_manifest_missing"))?;
    let manifest_member_bytes = manifest_bytes.len() as u64;
    let manifest =
        ArchiveManifest::from_bytes(&manifest_bytes, ArchiveContainer::TarGz.extension())?;
    Ok(InspectedArchive {
        manifest,
        manifest_member_bytes,
        members,
    })
}

/// The raw member list must be exactly the manifest member plus every declared member.
///
/// This catches undeclared top-level members and container-level duplicates or case
/// aliases that extraction would collapse into one filesystem path.
fn verify_raw_members(members: &[String], manifest: &ArchiveManifest) -> Result<()> {
    let mut expected = BTreeSet::new();
    expected.insert(MANIFEST_MEMBER.to_string());
    for entry in &manifest.entries {
        expected.insert(format!("{DATA_PREFIX}{}", entry.path));
    }
    let mut exact = BTreeSet::new();
    let mut folded = BTreeSet::new();
    for member in members {
        let member = member.trim_end_matches('/');
        ensure!(
            exact.insert(member.to_string()),
            "archive_inventory_duplicate"
        );
        ensure!(
            folded.insert(member.to_lowercase()),
            "archive_inventory_case_collision"
        );
        ensure!(expected.contains(member), "archive_inventory_mismatch");
    }
    for name in &expected {
        ensure!(exact.contains(name.as_str()), "archive_inventory_mismatch");
    }
    Ok(())
}

/// A staging name that cannot equal or contain any declared payload path, folded for
/// the target filesystem's case normalization.
///
/// A payload may legitimately contain a `.licoup-restore-staging` path in any letter
/// case; on a case-insensitive target that name aliases the scratch directory,
/// so the comparison and the suffix search are both case-folded.
fn unique_staging_name(entries: &[InventoryEntry]) -> String {
    let mut candidate = STAGING_DIRECTORY_BASE.to_string();
    let mut suffix = 1_u32;
    loop {
        let folded = candidate.to_lowercase();
        let prefix = format!("{folded}/");
        let collides = entries.iter().any(|entry| {
            let path = entry.path.to_lowercase();
            path == folded || path.starts_with(&prefix)
        });
        if !collides {
            return candidate;
        }
        suffix += 1;
        candidate = format!("{STAGING_DIRECTORY_BASE}-{suffix}");
    }
}

/// Every declared member exists with the declared kind and size, and no undeclared
/// member is present under the payload root. A legitimately empty data home carries no
/// payload members.
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

/// Publish the verified payload into the target, recording every side effect it may
/// create before the effect happens.
///
/// Implicit parent directories are recorded too, so a failure at any point — including
/// after a rename or after private-path hardening — can roll back exactly the
/// operation's own output.
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
        let destination = target.join(&entry.path);
        let directory = entry.kind == InventoryKind::Directory;
        let mut ancestor = destination.parent();
        while let Some(path) = ancestor {
            if path == target {
                break;
            }
            guard.record(path.to_path_buf(), true);
            ancestor = path.parent();
        }
        guard.record(destination.clone(), directory);
        publish_one(&extracted.join(&entry.path), &destination, directory)
            .map_err(|_| anyhow!("archive_target_unwritable"))?;
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

/// Records every path publication may create and rolls them back with checked cleanup.
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

    /// Remove every recorded path; report the first removal that did not complete.
    ///
    /// Files are removed first, then directories deepest first, so a parent directory is
    /// never seen non-empty because of a child this rollback still has to visit.
    fn rollback(&mut self) -> Result<()> {
        self.armed = false;
        let mut failure: Option<std::io::Error> = None;
        let mut files = Vec::new();
        let mut directories = BTreeSet::new();
        for (path, directory) in &self.published {
            // Rollback removes only paths this operation published below the target.
            if !path.starts_with(self.target) {
                continue;
            }
            if *directory {
                directories.insert(path.clone());
            } else {
                files.push(path.clone());
            }
        }
        let mut ordered: Vec<PathBuf> = directories.into_iter().collect();
        ordered.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
        let remove =
            |result: std::io::Result<()>, failure: &mut Option<std::io::Error>| match result {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    if failure.is_none() {
                        *failure = Some(error);
                    }
                }
            };
        for path in &files {
            remove(fs::remove_file(path), &mut failure);
        }
        for path in &ordered {
            remove(fs::remove_dir(path), &mut failure);
        }
        match failure {
            Some(error) => Err(error.into()),
            None => Ok(()),
        }
    }

    /// Return the publication failure after the checked rollback, naming any cleanup
    /// that could not complete instead of swallowing it.
    fn fail(&mut self, error: anyhow::Error) -> anyhow::Error {
        match self.rollback() {
            Ok(()) => error,
            Err(rollback) => anyhow!("{error}; archive_target_rollback_incomplete: {rollback}"),
        }
    }

    /// Sync every directory that received a published entry, deepest first, so nested
    /// renames are durable and not only the target root.
    fn sync_changed_directories(&self) -> Result<()> {
        let mut directories = BTreeSet::new();
        directories.insert(self.target.to_path_buf());
        for (path, directory) in &self.published {
            if *directory {
                directories.insert(path.clone());
            }
            if let Some(parent) = path.parent() {
                directories.insert(parent.to_path_buf());
            }
        }
        let mut ordered: Vec<PathBuf> = directories.into_iter().collect();
        ordered.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
        for directory in ordered {
            sync_directory(&directory).map_err(|_| anyhow!("archive_target_unwritable"))?;
        }
        Ok(())
    }
}

impl Drop for PublicationGuard<'_> {
    fn drop(&mut self) {
        if self.armed {
            // Last resort for panics only; every normal failure path rolls back explicitly.
            let _ = self.rollback();
        }
    }
}

/// Removes the staging directory on every path; it is operation-owned scratch.
struct StagingDirectory {
    path: PathBuf,
    cleaned: bool,
}

impl StagingDirectory {
    /// Checked removal used on the success path and on every handled failure.
    fn cleanup(&mut self) -> Result<()> {
        self.cleaned = true;
        fs::remove_dir_all(&self.path).map_err(|_| anyhow!("archive_target_cleanup_failed"))
    }

    /// Return the failure after the checked cleanup, naming cleanup that did not
    /// complete instead of swallowing it.
    fn fail(&mut self, error: anyhow::Error) -> anyhow::Error {
        match self.cleanup() {
            Ok(()) => error,
            Err(cleanup) => anyhow!("{error}; archive_target_cleanup_incomplete: {cleanup}"),
        }
    }
}

impl Drop for StagingDirectory {
    fn drop(&mut self) {
        if !self.cleaned {
            // Last resort for panics only; every normal failure path cleans up explicitly.
            let _ = fs::remove_dir_all(&self.path);
        }
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

    fn directory_entry(path: &str) -> InventoryEntry {
        InventoryEntry {
            path: path.to_string(),
            kind: InventoryKind::Directory,
            size: 0,
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
            file_entry(".licoup-restore-staging/keep.bin", 1),
            file_entry(".licoup-restore-staging-2/keep.bin", 1),
        ];
        let name = unique_staging_name(&entries);
        assert_ne!(name, ".licoup-restore-staging");
        assert_ne!(name, ".licoup-restore-staging-2");
        assert_eq!(name, ".licoup-restore-staging-3");
    }

    #[test]
    fn staging_names_are_case_folded_against_declared_payload_paths() {
        let entries = vec![
            directory_entry(".LICOUP-RESTORE-STAGING"),
            file_entry(".LICOUP-RESTORE-STAGING/keep.bin", 1),
        ];
        let name = unique_staging_name(&entries);
        assert_ne!(name.to_lowercase(), ".licoup-restore-staging");
        assert_eq!(name, ".licoup-restore-staging-2");
    }

    #[test]
    fn raw_member_inventory_must_match_the_declared_members_exactly() {
        let manifest = ArchiveManifest::new(
            "zip",
            RecoveryCoverage::Limited,
            Vec::new(),
            vec![file_entry("a.txt", 1), directory_entry("d")],
        )
        .expect("manifest");
        let exact = vec![
            MANIFEST_MEMBER.to_string(),
            "data/a.txt".to_string(),
            "data/d".to_string(),
        ];
        assert!(verify_raw_members(&exact, &manifest).is_ok());
        assert!(verify_raw_members(&[MANIFEST_MEMBER.to_string()], &manifest).is_err());

        let mut undeclared = exact.clone();
        undeclared.push("escaped.bin".to_string());
        assert!(verify_raw_members(&undeclared, &manifest).is_err());

        let mut duplicate = exact.clone();
        duplicate.push("data/d/".to_string());
        assert_eq!(
            verify_raw_members(&duplicate, &manifest)
                .expect_err("duplicate member")
                .to_string(),
            "archive_inventory_duplicate"
        );

        let mut aliased = exact.clone();
        aliased.push("data/A.TXT".to_string());
        assert_eq!(
            verify_raw_members(&aliased, &manifest)
                .expect_err("case alias")
                .to_string(),
            "archive_inventory_case_collision"
        );
    }

    #[test]
    fn publication_failure_after_a_rename_rolls_back_the_file_and_its_parent() {
        let root = scratch("publication-after-rename");
        fs::create_dir_all(root.join("staging/data/a")).expect("create staging");
        fs::write(root.join("staging/data/a/first.txt"), b"first").expect("first");
        let entries = vec![file_entry("a/first.txt", 5)];
        let mut guard = PublicationGuard::new(&root);
        let result = publish_payload(
            &mut guard,
            &root,
            &root.join("staging"),
            &entries,
            |source, destination, _directory| {
                if let Some(parent) = destination.parent() {
                    fs::create_dir_all(parent)?;
                }
                fs::rename(source, destination)?;
                // Simulates a failure after the rename, such as private-path hardening.
                Err(anyhow!("injected post-rename failure"))
            },
        );
        let error = guard.fail(result.expect_err("publication must fail"));
        assert_eq!(error.to_string(), "archive_target_unwritable");
        assert!(
            !root.join("a").exists(),
            "rollback removes the published file and its implicit parent"
        );
        drop(guard);
        fs::remove_dir_all(root).expect("remove scratch");
    }

    #[test]
    fn rollback_reports_state_it_cannot_remove() {
        let root = scratch("publication-unremovable");
        fs::create_dir_all(root.join("staging/data/a")).expect("create staging");
        fs::write(root.join("staging/data/a/first.txt"), b"first").expect("first");
        let entries = vec![file_entry("a/first.txt", 5)];
        let mut guard = PublicationGuard::new(&root);
        let result = publish_payload(
            &mut guard,
            &root,
            &root.join("staging"),
            &entries,
            |source, destination, _directory| {
                if let Some(parent) = destination.parent() {
                    fs::create_dir_all(parent)?;
                }
                fs::rename(source, destination)?;
                // A file the operation never recorded keeps the directory non-empty.
                fs::write(root.join("a/foreign.txt"), b"foreign")?;
                Err(anyhow!("injected post-rename failure"))
            },
        );
        let error = guard.fail(result.expect_err("publication must fail"));
        assert!(
            error
                .to_string()
                .contains("archive_target_rollback_incomplete"),
            "{error}"
        );
        drop(guard);
        fs::remove_dir_all(root).expect("remove scratch");
    }
}
