use anyhow::{Result, anyhow, ensure};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Take};
use std::path::Path;

pub(in crate::domain::collaboration_plugin) fn read_file_no_follow(
    path: &Path,
    maximum_bytes: usize,
) -> Result<Vec<u8>> {
    let before = fs::symlink_metadata(path)
        .map_err(|_| anyhow!("collaboration_plugin_package_entry_unavailable"))?;
    ensure!(
        before.file_type().is_file() && !before.file_type().is_symlink(),
        "collaboration_plugin_package_entry_type_rejected"
    );
    let mut file = open_no_follow(path)?;
    let opened = file
        .metadata()
        .map_err(|_| anyhow!("collaboration_plugin_package_file_read_failed"))?;
    validate_same_private_file(&before, &opened)?;
    let declared = usize::try_from(opened.len())
        .map_err(|_| anyhow!("collaboration_plugin_package_file_too_large"))?;
    ensure!(
        declared <= maximum_bytes,
        "collaboration_plugin_package_too_large"
    );
    let mut bytes = Vec::with_capacity(declared);
    bounded_reader(&mut file, maximum_bytes).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() == declared && bytes.len() <= maximum_bytes,
        "collaboration_plugin_package_file_changed"
    );
    let after = fs::symlink_metadata(path)
        .map_err(|_| anyhow!("collaboration_plugin_package_file_changed"))?;
    let opened_after = file
        .metadata()
        .map_err(|_| anyhow!("collaboration_plugin_package_file_changed"))?;
    validate_same_private_file(&before, &after)?;
    validate_same_private_file(&opened, &opened_after)?;
    Ok(bytes)
}

fn bounded_reader(file: &mut File, maximum_bytes: usize) -> Take<&mut File> {
    file.take(maximum_bytes.saturating_add(1) as u64)
}

#[cfg(unix)]
fn open_no_follow(path: &Path) -> Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| anyhow!("collaboration_plugin_package_file_read_failed"))
}

#[cfg(windows)]
fn open_no_follow(path: &Path) -> Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|_| anyhow!("collaboration_plugin_package_file_read_failed"))
}

#[cfg(not(any(unix, windows)))]
fn open_no_follow(_path: &Path) -> Result<File> {
    Err(anyhow!("collaboration_plugin_package_platform_unsupported"))
}

#[cfg(unix)]
fn validate_same_private_file(left: &fs::Metadata, right: &fs::Metadata) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    ensure!(
        left.file_type().is_file()
            && right.file_type().is_file()
            && left.nlink() == 1
            && right.nlink() == 1
            && left.dev() == right.dev()
            && left.ino() == right.ino()
            && left.len() == right.len()
            && left.mtime() == right.mtime()
            && left.mtime_nsec() == right.mtime_nsec()
            && left.ctime() == right.ctime()
            && left.ctime_nsec() == right.ctime_nsec(),
        "collaboration_plugin_package_file_changed"
    );
    Ok(())
}

#[cfg(windows)]
fn validate_same_private_file(left: &fs::Metadata, right: &fs::Metadata) -> Result<()> {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    ensure!(
        left.file_type().is_file()
            && right.file_type().is_file()
            && left.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
            && right.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
            && left.number_of_links() == Some(1)
            && right.number_of_links() == Some(1)
            && left.volume_serial_number() == right.volume_serial_number()
            && left.file_index() == right.file_index()
            && left.file_size() == right.file_size()
            && left.last_write_time() == right.last_write_time(),
        "collaboration_plugin_package_file_changed"
    );
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn validate_same_private_file(_left: &fs::Metadata, _right: &fs::Metadata) -> Result<()> {
    Err(anyhow!("collaboration_plugin_package_platform_unsupported"))
}
