//! Capture one data root into a plaintext archive.
//!
//! The caller names the destination; the owner never defaults one, and it never captures
//! the archive it is writing. Writers must be stopped before capture. The owner takes the
//! same `client-state/migrations/admission.lock` that native state admission already
//! uses, so a capture cannot run while another application writer holds it, and no
//! second locking convention is invented.

use anyhow::{Context, Result, anyhow, ensure};
use flate2::Compression;
use flate2::write::GzEncoder;
use fs2::FileExt;
use std::ffi::OsString;
use std::fs::{File, OpenOptions};
use std::io::{BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};

use super::inventory::{
    ArchiveManifest, InventoryKind, RecoveryCoverage, RecoveryLimitation, inventory_data_root,
};
use super::{ArchiveContainer, DATA_PREFIX, MANIFEST_MEMBER};

/// Application-owned key-reference stores. Their absence is reported as a named
/// limitation so an archive is never described as a complete recovery when a
/// credential domain could not travel with it.
const CREDENTIAL_REFERENCE_STORES: &[(&str, &str)] = &[(
    "gateway-credential-custody",
    "client-state/llm-api-key-inventory.json",
)];

#[derive(Clone, Debug)]
pub struct ExportRequest {
    /// Absolute data root to capture.
    pub data_root: PathBuf,
    /// Destination archive. The container is inferred from its extension.
    pub archive_path: PathBuf,
    /// The caller states that every writer, including older clients, is stopped.
    pub writers_stopped: bool,
}

#[derive(Clone, Debug)]
pub struct ExportOutcome {
    pub container: ArchiveContainer,
    pub coverage: RecoveryCoverage,
    pub limitations: Vec<RecoveryLimitation>,
    pub file_count: usize,
    pub total_bytes: u64,
}

/// Capture `data_root` into a standard plaintext archive.
pub fn export_data_root(request: &ExportRequest) -> Result<ExportOutcome> {
    // The caller names the destination, and the archive is never part of the data the
    // capture operates on. The owner creates the destination before it inventories the
    // root, so an archive named inside the root would be captured as a member of itself
    // and a restore would then write that file back into the restored root. This is
    // decided before anything is created, so a refused capture publishes no file and
    // creates no parent directory inside the root it declined to describe.
    ensure!(
        !archive_path_inside_data_root(&request.data_root, &request.archive_path),
        "archive_path_inside_data_root"
    );
    ensure!(request.writers_stopped, "archive_writers_running");
    ensure!(request.data_root.is_dir(), "data_root_missing");
    let container = ArchiveContainer::from_path(&request.archive_path)?;

    if let Some(parent) = request.archive_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|_| anyhow!("archive_destination_unwritable"))?;
        }
    }

    // Preconditions first: a refused capture must leave no archive and must not
    // touch the source.
    let _admission = AdmissionGuard::acquire(&request.data_root)?;

    let destination = File::create(&request.archive_path)
        .map_err(|_| anyhow!("archive_destination_unwritable"))?;

    let entries = inventory_data_root(&request.data_root)?;
    let limitations = recovery_limitations(&entries);
    let coverage = if limitations.is_empty() {
        RecoveryCoverage::Complete
    } else {
        RecoveryCoverage::Limited
    };
    let manifest = ArchiveManifest::new(
        container.extension(),
        coverage,
        limitations.clone(),
        entries,
    );

    match container {
        ArchiveContainer::Zip => {
            let bytes = build_zip(&request.data_root, &manifest)?;
            let mut writer = BufWriter::new(destination);
            writer
                .write_all(&bytes)
                .map_err(|_| anyhow!("archive_write_failed"))?;
            writer
                .flush()
                .map_err(|_| anyhow!("archive_write_failed"))?;
        }
        ArchiveContainer::TarGz => {
            write_tar_gz(BufWriter::new(destination), &request.data_root, &manifest)?;
        }
    }

    Ok(ExportOutcome {
        container,
        coverage,
        limitations,
        file_count: manifest.file_count(),
        total_bytes: manifest.total_bytes,
    })
}

/// Whether `archive_path` names a destination the capture would read back as its own data.
///
/// The root is compared under its resolved name, and a destination that does not exist yet
/// is resolved through its nearest existing ancestor, so a destination placed inside the
/// root through a symbolic link is refused exactly like a direct one. The root's own path
/// counts as inside it: a capture cannot write over the thing it is describing. A path that
/// cannot be resolved is not this rule's refusal; the capture then reports the destination
/// it cannot write with its own code.
pub fn archive_path_inside_data_root(data_root: &Path, archive_path: &Path) -> bool {
    let (Ok(root), Some(destination)) = (
        data_root.canonicalize(),
        resolve_through_existing_ancestor(archive_path),
    ) else {
        return false;
    };
    destination.starts_with(root)
}

/// Resolve one path for comparison, following the ancestors that exist.
///
/// A relative name is read against the process working directory, exactly as the capture's
/// own file creation reads it, so the comparison describes the file the capture would open.
fn resolve_through_existing_ancestor(path: &Path) -> Option<PathBuf> {
    let mut existing = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };
    let mut suffix: Vec<OsString> = Vec::new();
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

fn recovery_limitations(entries: &[super::inventory::InventoryEntry]) -> Vec<RecoveryLimitation> {
    CREDENTIAL_REFERENCE_STORES
        .iter()
        .filter(|(_, path)| {
            !entries
                .iter()
                .any(|entry| entry.kind == InventoryKind::File && entry.path == *path)
        })
        .map(|(domain, path)| RecoveryLimitation {
            domain: (*domain).to_string(),
            reason: format!("{path} is absent from the captured root"),
        })
        .collect()
}

fn build_zip(root: &Path, manifest: &ArchiveManifest) -> Result<Vec<u8>> {
    let mut buffer = std::io::Cursor::new(Vec::new());
    let mut zip = zip::ZipWriter::new(&mut buffer);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    zip.start_file(MANIFEST_MEMBER, options)
        .map_err(|_| anyhow!("archive_write_failed"))?;
    zip.write_all(&manifest.to_bytes()?)
        .map_err(|_| anyhow!("archive_write_failed"))?;

    for entry in &manifest.entries {
        let member = format!("{DATA_PREFIX}{}", entry.path);
        match entry.kind {
            InventoryKind::Directory => {
                zip.add_directory(member, options)
                    .map_err(|_| anyhow!("archive_write_failed"))?;
            }
            InventoryKind::File => {
                zip.start_file(member, options)
                    .map_err(|_| anyhow!("archive_write_failed"))?;
                copy_file(root, &entry.path, &mut zip)?;
            }
        }
    }
    zip.finish().map_err(|_| anyhow!("archive_write_failed"))?;
    Ok(buffer.into_inner())
}

fn write_tar_gz<W: Write>(writer: W, root: &Path, manifest: &ArchiveManifest) -> Result<()> {
    let encoder = GzEncoder::new(writer, Compression::default());
    let mut builder = tar::Builder::new(encoder);
    builder.mode(tar::HeaderMode::Deterministic);

    let manifest_bytes = manifest.to_bytes()?;
    let mut header = tar::Header::new_gnu();
    header.set_size(manifest_bytes.len() as u64);
    header.set_mode(0o600);
    header.set_mtime(manifest.created_at_unix);
    header.set_cksum();
    builder
        .append_data(&mut header, MANIFEST_MEMBER, manifest_bytes.as_slice())
        .map_err(|_| anyhow!("archive_write_failed"))?;

    for entry in &manifest.entries {
        let member = format!("{DATA_PREFIX}{}", entry.path);
        match entry.kind {
            InventoryKind::Directory => {
                let mut header = tar::Header::new_gnu();
                header.set_entry_type(tar::EntryType::Directory);
                header.set_size(0);
                header.set_mode(0o700);
                header.set_mtime(manifest.created_at_unix);
                header.set_cksum();
                builder
                    .append_data(&mut header, format!("{member}/"), std::io::empty())
                    .map_err(|_| anyhow!("archive_write_failed"))?;
            }
            InventoryKind::File => {
                let mut header = tar::Header::new_gnu();
                header.set_entry_type(tar::EntryType::Regular);
                header.set_size(entry.size);
                header.set_mode(0o600);
                header.set_mtime(manifest.created_at_unix);
                header.set_cksum();
                let file = File::open(root.join(&entry.path))
                    .map_err(|_| anyhow!("data_root_entry_unreadable"))?;
                builder
                    .append_data(&mut header, member, BufReader::new(file))
                    .map_err(|_| anyhow!("archive_write_failed"))?;
            }
        }
    }

    let encoder = builder
        .into_inner()
        .map_err(|_| anyhow!("archive_write_failed"))?;
    encoder
        .finish()
        .map_err(|_| anyhow!("archive_write_failed"))?;
    Ok(())
}

fn copy_file<W: Write>(root: &Path, relative: &str, writer: &mut W) -> Result<()> {
    let mut file = BufReader::new(
        File::open(root.join(relative)).map_err(|_| anyhow!("data_root_entry_unreadable"))?,
    );
    std::io::copy(&mut file, writer).map_err(|_| anyhow!("archive_write_failed"))?;
    Ok(())
}

/// Exclusive admission, matching the convention native state admission already
/// uses. Holding it proves no other application writer is inside the same window.
struct AdmissionGuard {
    file: File,
}

impl AdmissionGuard {
    fn acquire(data_root: &Path) -> Result<Self> {
        let directory = data_root.join("client-state").join("migrations");
        std::fs::create_dir_all(&directory).context("archive_admission_unavailable")?;
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(directory.join("admission.lock"))
            .context("archive_admission_unavailable")?;
        file.try_lock_exclusive()
            .map_err(|_| anyhow!("archive_writers_running"))?;
        Ok(Self { file })
    }
}

impl Drop for AdmissionGuard {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.file);
    }
}
