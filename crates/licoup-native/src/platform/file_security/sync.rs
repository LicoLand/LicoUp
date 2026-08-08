use anyhow::Result;
use std::fs;
use std::io;
use std::path::Path;

pub(super) fn file(file: &mut fs::File) -> Result<()> {
    if let Err(error) = file.sync_all() {
        if unsupported(&error) {
            return Ok(());
        }
        return Err(error.into());
    }
    Ok(())
}

pub(super) fn parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("private security state marker parent is missing"))?;
    directory(parent)
}

pub(super) fn directory(directory: &Path) -> Result<()> {
    let file = match fs::File::open(directory) {
        Ok(file) => file,
        Err(error) if unsupported(&error) => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if let Err(error) = file.sync_all() {
        if unsupported(&error) {
            return Ok(());
        }
        return Err(error.into());
    }
    Ok(())
}

#[cfg(windows)]
fn unsupported(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::PermissionDenied
}

#[cfg(not(windows))]
fn unsupported(_error: &io::Error) -> bool {
    false
}
