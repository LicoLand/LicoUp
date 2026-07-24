use anyhow::{Result, anyhow, ensure};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use super::{sync, validation};

pub fn atomic_write_private_text(path: &Path, content: &str) -> Result<()> {
    atomic_write_private_text_with_policy(path, content, usize::MAX, false)
}

pub fn atomic_write_private_text_bounded(
    path: &Path,
    content: &str,
    max_bytes: usize,
) -> Result<()> {
    atomic_write_private_text_with_policy(path, content, max_bytes, true)
}

fn atomic_write_private_text_with_policy(
    path: &Path,
    content: &str,
    max_bytes: usize,
    require_private_existing_file: bool,
) -> Result<()> {
    ensure!(
        content.len() <= max_bytes,
        "private state file exceeds its bounded size"
    );
    if require_private_existing_file {
        validation::ensure_private_state_parent(path)?;
    } else {
        validation::ensure_atomic_write_parent(path)?;
    }
    if let Some(metadata) = validation::state_marker_metadata(path)? {
        if require_private_existing_file {
            validation::validate_private_file_metadata(&metadata)?;
        } else {
            validation::validate_private_file_type_and_owner(&metadata)?;
        }
    }
    let tmp = sibling_temp_path(path);
    let write_result = (|| -> Result<()> {
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(nix::libc::O_NOFOLLOW);
        }
        let mut file = options
            .open(&tmp)
            .map_err(|_| anyhow!("private state temporary file could not be created"))?;
        validation::apply_private_file_permissions(&file, &tmp)?;
        file.write_all(content.as_bytes())?;
        sync::file(&mut file)?;
        validation::validate_open_state_marker(&tmp, &file)?;
        drop(file);
        rename_into_place(&tmp, path)
            .map_err(|_| anyhow!("private state file could not be committed"))?;
        let committed = fs::symlink_metadata(path)
            .map_err(|_| anyhow!("private state file disappeared after commit"))?;
        validation::validate_private_file_metadata(&committed)?;
        sync::parent(path)?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    write_result
}

pub(super) fn rename_into_place(tmp: &Path, path: &Path) -> Result<()> {
    validation::validate_regular_file_or_missing_no_follow(tmp, false)?;
    validation::validate_regular_file_or_missing_no_follow(path, true)?;
    match fs::rename(tmp, path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::CrossesDevices => {
            copy_cross_device_then_atomic_replace(tmp, path)
        }
        Err(error) => Err(error.into()),
    }
}

fn copy_cross_device_then_atomic_replace(tmp: &Path, path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("atomic replacement destination parent is missing"))?;
    validation::validate_private_path_ancestors(parent)?;
    let stage = sibling_temp_path(path);
    validation::validate_regular_file_or_missing_no_follow(&stage, true)?;

    let source_path_metadata = fs::symlink_metadata(tmp)?;
    validation::validate_private_file_type_and_owner(&source_path_metadata)?;
    let mut source_options = OpenOptions::new();
    source_options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        source_options.custom_flags(nix::libc::O_NOFOLLOW);
    }
    let mut source = source_options
        .open(tmp)
        .map_err(|_| anyhow!("atomic replacement source could not be opened"))?;
    validation::ensure_same_file(&source_path_metadata, &source.metadata()?)?;

    let result = (|| -> Result<()> {
        let mut stage_options = OpenOptions::new();
        stage_options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            stage_options
                .mode(0o600)
                .custom_flags(nix::libc::O_NOFOLLOW);
        }
        let mut staged = stage_options
            .open(&stage)
            .map_err(|_| anyhow!("atomic replacement stage could not be created"))?;
        validation::apply_private_file_permissions(&staged, &stage)?;
        io::copy(&mut source, &mut staged)?;
        sync::file(&mut staged)?;
        validation::validate_open_state_marker(&stage, &staged)?;
        drop(staged);

        validation::validate_private_path_ancestors(parent)?;
        validation::validate_regular_file_or_missing_no_follow(path, true)?;
        fs::rename(&stage, path).map_err(|_| anyhow!("atomic replacement commit failed"))?;
        sync::parent(path)?;
        let stable_source = fs::symlink_metadata(tmp)
            .map_err(|_| anyhow!("atomic replacement source changed before cleanup"))?;
        validation::ensure_same_file(&source_path_metadata, &stable_source)?;
        fs::remove_file(tmp)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&stage);
    }
    result
}

fn sibling_temp_path(path: &Path) -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("lico");
    path.with_extension(format!(
        "{}.tmp-{}-{}",
        extension,
        std::process::id(),
        stamp
    ))
}
