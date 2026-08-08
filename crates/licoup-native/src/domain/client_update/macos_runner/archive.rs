use std::{
    fs,
    io::Read,
    os::unix::fs::symlink,
    path::{Component, Path, PathBuf},
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
    let mut links = Vec::<(PathBuf, PathBuf)>::new();
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
            entry_type.is_file() || entry_type.is_dir() || entry_type.is_symlink(),
            "client update archive hard links and special entries are forbidden"
        );
        let entry_path = entry
            .path()
            .context("client update archive path is invalid")?;
        validate_archive_path(&entry_path)?;
        if entry_type.is_symlink() {
            let target = entry
                .link_name()?
                .context("client update archive link target is missing")?;
            validate_relative_link_target(&entry_path, &target)?;
            links.push((entry_path.into_owned(), target.into_owned()));
            continue;
        }
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
    for (relative, target) in links {
        let destination = extraction_root.join(relative);
        ensure!(
            !destination.exists(),
            "client update archive link destination already exists"
        );
        symlink(target, destination).context("failed to create client update archive link")?;
    }
    validate_tree_without_links(extraction_root)
}

fn validate_relative_link_target(entry_path: &Path, target: &Path) -> Result<()> {
    ensure!(
        target.is_relative() && target.as_os_str().len() <= 1024,
        "client update archive link target must be relative"
    );
    let mut depth = entry_path
        .parent()
        .map_or(0, |path| path.components().count()) as isize;
    for component in target.components() {
        match component {
            Component::Normal(_) => depth += 1,
            Component::ParentDir if depth > 0 => depth -= 1,
            Component::CurDir => {}
            _ => bail!("client update archive link target escapes its root"),
        }
    }
    Ok(())
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
