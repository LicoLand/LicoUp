use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, ensure};

pub(super) fn checked_app_directory(root: &Path, application_name: &str) -> Result<PathBuf> {
    let canonical_root =
        fs::canonicalize(root).context("failed to canonicalize extraction root")?;
    let candidate = root.join(application_name);
    validate_tree_without_links(&candidate)?;
    let canonical_app =
        fs::canonicalize(candidate).context("failed to canonicalize staged application")?;
    ensure!(
        canonical_app.parent() == Some(canonical_root.as_path()),
        "client update staged application escapes its extraction root"
    );
    Ok(canonical_app)
}

pub(super) fn validate_tree_without_links(root: &Path) -> Result<()> {
    let metadata =
        fs::symlink_metadata(root).context("client update application tree is missing")?;
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "client update application tree must be a directory without links"
    );
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)?;
        ensure!(
            !metadata.file_type().is_symlink(),
            "client update application tree contains a symbolic link"
        );
        if metadata.is_dir() {
            validate_tree_without_links(&path)?;
        } else {
            ensure!(
                metadata.is_file(),
                "client update application tree contains a special file"
            );
        }
    }
    Ok(())
}

pub(super) fn copy_tree(source: &Path, target: &Path) -> Result<()> {
    validate_tree_without_links(source)?;
    fs::create_dir_all(target)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let from = entry.path();
        let to = target.join(entry.file_name());
        let metadata = fs::symlink_metadata(&from)?;
        if metadata.is_dir() {
            copy_tree(&from, &to)?;
        } else {
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

pub(super) fn remove_generated_directory(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "client update generated directory is not a safe directory"
    );
    fs::remove_dir_all(path).context("failed to clear generated client update directory")
}
