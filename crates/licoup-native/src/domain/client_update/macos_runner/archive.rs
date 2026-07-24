use std::{
    fs,
    io::Read,
    path::{Component, Path},
};

use anyhow::{Context, Result, bail, ensure};
use flate2::read::GzDecoder;
use tar::Archive;

use super::super::model::VerifiedUpdateSelection;
use super::filesystem::validate_tree_without_links;

const MAX_ARCHIVE_ENTRIES: usize = 100_000;
const MAX_EXPANDED_BYTES: u64 = 8 * 1024 * 1024 * 1024;

pub(super) fn extract_signed_archive(
    selection: &VerifiedUpdateSelection,
    staged_path: &Path,
    extraction_root: &Path,
) -> Result<()> {
    let file = fs::File::open(staged_path).context("failed to open signed update archive")?;
    let reader: Box<dyn Read> = if selection.artifact.file_name.ends_with(".tar.gz") {
        Box::new(GzDecoder::new(file))
    } else if selection.artifact.file_name.ends_with(".tar") {
        Box::new(file)
    } else {
        bail!("client update app-bundle artifact must be a signed tar or tar.gz archive")
    };
    let expanded_limit = selection
        .artifact
        .size
        .checked_mul(64)
        .unwrap_or(MAX_EXPANDED_BYTES)
        .min(MAX_EXPANDED_BYTES);
    let mut archive = Archive::new(reader);
    let mut entry_count = 0_usize;
    let mut expanded_bytes = 0_u64;
    for entry in archive
        .entries()
        .context("failed to read signed update archive")?
    {
        let mut entry = entry.context("failed to read signed update archive entry")?;
        entry_count = entry_count
            .checked_add(1)
            .context("client update archive entry count overflow")?;
        ensure!(
            entry_count <= MAX_ARCHIVE_ENTRIES,
            "client update archive contains too many entries"
        );
        let entry_type = entry.header().entry_type();
        ensure!(
            entry_type.is_file() || entry_type.is_dir(),
            "client update archive links and special entries are forbidden"
        );
        let entry_path = entry
            .path()
            .context("client update archive path is invalid")?;
        validate_archive_path(&entry_path)?;
        expanded_bytes = expanded_bytes
            .checked_add(entry.header().size()?)
            .context("client update archive expanded size overflow")?;
        ensure!(
            expanded_bytes <= expanded_limit,
            "client update archive exceeds its expansion limit"
        );
        ensure!(
            entry.unpack_in(extraction_root)?,
            "client update archive entry escapes its extraction root"
        );
    }
    validate_tree_without_links(extraction_root)
}

fn validate_archive_path(path: &Path) -> Result<()> {
    ensure!(
        path.as_os_str().len() <= 1024
            && path
                .components()
                .all(|component| matches!(component, Component::Normal(_))),
        "client update archive path must be relative and normalized"
    );
    Ok(())
}

#[cfg(test)]
pub(in crate::domain::client_update) fn validate_archive_path_for_test(path: &Path) -> Result<()> {
    validate_archive_path(path)
}
