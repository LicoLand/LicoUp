use anyhow::{Context, Result, anyhow, ensure};
use std::fs::{self, OpenOptions};
#[cfg(windows)]
use std::io::ErrorKind;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
#[cfg(windows)]
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::ffi::OsStrExt;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

const PRIVATE_STATE_FILE_MAX_BYTES: u64 = 64 * 1024;
const PRIVATE_APPEND_FILE_MAX_BYTES: u64 = 64 * 1024 * 1024;
const PRIVATE_APPEND_LINE_MAX_BYTES: usize = 4 * 1024 * 1024;

pub fn append_private_line(path: &Path, line: &str) -> Result<()> {
    ensure!(
        line.len() <= PRIVATE_APPEND_LINE_MAX_BYTES,
        "private append line exceeds its bounded size"
    );
    ensure_private_state_parent(path)?;
    append_private_line_platform(path, line)
}

#[cfg(unix)]
fn append_private_line_platform(path: &Path, line: &str) -> Result<()> {
    use nix::fcntl::{FlockArg, OFlag, flock, openat};
    use nix::sys::stat::{Mode, fchmod, fstat};
    use nix::unistd::{close, fsync, write};

    let parent_path = path
        .parent()
        .ok_or_else(|| anyhow!("private append file parent is missing"))?;
    let leaf = path
        .file_name()
        .ok_or_else(|| anyhow!("private append file name is missing"))?;
    ensure!(
        !leaf.as_bytes().contains(&b'/') && leaf != "." && leaf != "..",
        "private append file name is invalid"
    );

    validate_no_user_owned_symlink_ancestors(parent_path)?;
    let parent_path_metadata = fs::symlink_metadata(parent_path)?;
    validate_private_directory_metadata(&parent_path_metadata)?;
    let mut parent_options = OpenOptions::new();
    parent_options
        .read(true)
        .custom_flags(nix::libc::O_DIRECTORY | nix::libc::O_NOFOLLOW);
    let parent = parent_options
        .open(parent_path)
        .map_err(|_| anyhow!("private append directory could not be opened"))?;
    validate_private_directory_metadata(&parent.metadata()?)?;
    ensure_same_file(&parent_path_metadata, &parent.metadata()?)?;

    let raw_fd = openat(
        parent.as_raw_fd(),
        Path::new(leaf),
        OFlag::O_APPEND | OFlag::O_CLOEXEC | OFlag::O_CREAT | OFlag::O_NOFOLLOW | OFlag::O_WRONLY,
        Mode::S_IRUSR | Mode::S_IWUSR,
    )
    .map_err(|_| anyhow!("private append file could not be opened"))?;
    fchmod(raw_fd, Mode::S_IRUSR | Mode::S_IWUSR)?;
    flock(raw_fd, FlockArg::LockExclusive)
        .map_err(|_| anyhow!("private append file could not be locked"))?;

    let result = (|| -> Result<()> {
        let opened_stat = fstat(raw_fd)?;
        validate_private_file_stat(&opened_stat)?;
        let stable_parent = fs::symlink_metadata(parent_path)
            .map_err(|_| anyhow!("private append directory changed while opening"))?;
        validate_no_user_owned_symlink_ancestors(parent_path)?;
        validate_private_directory_metadata(&stable_parent)?;
        ensure_same_file(&parent_path_metadata, &stable_parent)?;
        let path_metadata = fs::symlink_metadata(path)
            .map_err(|_| anyhow!("private append file changed while opening"))?;
        validate_private_file_metadata(&path_metadata)?;
        ensure_metadata_matches_stat(&path_metadata, &opened_stat)?;
        let append_bytes =
            line.len()
                .checked_add(1)
                .ok_or_else(|| anyhow!("private append size overflow"))? as u64;
        ensure!(
            u64::try_from(opened_stat.st_size)
                .unwrap_or(u64::MAX)
                .checked_add(append_bytes)
                .is_some_and(|size| size <= PRIVATE_APPEND_FILE_MAX_BYTES),
            "private append file exceeds its bounded size"
        );
        let mut record = Vec::with_capacity(line.len() + 1);
        record.extend_from_slice(line.as_bytes());
        record.push(b'\n');
        let mut remaining = record.as_slice();
        while !remaining.is_empty() {
            let written = write(raw_fd, remaining)?;
            ensure!(written > 0, "private append file write made no progress");
            remaining = &remaining[written..];
        }
        fsync(raw_fd)?;
        let stable_path = fs::symlink_metadata(path)
            .map_err(|_| anyhow!("private append file changed while writing"))?;
        validate_private_file_metadata(&stable_path)?;
        ensure_metadata_matches_stat(&stable_path, &fstat(raw_fd)?)
    })();
    let unlock_result = flock(raw_fd, FlockArg::Unlock);
    let close_result = close(raw_fd);
    result?;
    unlock_result.map_err(|_| anyhow!("private append file could not be unlocked"))?;
    close_result.map_err(|_| anyhow!("private append file could not be closed"))?;
    Ok(())
}

#[cfg(not(unix))]
fn append_private_line_platform(path: &Path, line: &str) -> Result<()> {
    if let Some(metadata) = state_marker_metadata(path)? {
        validate_private_file_type_and_owner(&metadata)?;
        ensure!(
            metadata
                .len()
                .checked_add(line.len() as u64 + 1)
                .is_some_and(|size| size <= PRIVATE_APPEND_FILE_MAX_BYTES),
            "private append file exceeds its bounded size"
        );
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    apply_private_file_permissions(&file, path)?;
    validate_open_state_marker(path, &file)?;
    writeln!(file, "{line}")?;
    sync_all_if_supported(&mut file)
}

pub fn atomic_write_private_text(path: &Path, content: &str) -> Result<()> {
    atomic_write_private_text_with_policy(path, content, usize::MAX, false)
}

/// Atomically replaces an owner-only text file and durably synchronizes its directory entry.
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
        ensure_private_state_parent(path)?;
    } else {
        ensure_atomic_write_parent(path)?;
    }
    if let Some(metadata) = state_marker_metadata(path)? {
        if require_private_existing_file {
            validate_private_file_metadata(&metadata)?;
        } else {
            validate_private_file_type_and_owner(&metadata)?;
        }
    }
    let tmp = sibling_temp_path(path);
    let write_result = (|| -> Result<()> {
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            options.mode(0o600).custom_flags(nix::libc::O_NOFOLLOW);
        }
        let mut file = options
            .open(&tmp)
            .map_err(|_| anyhow::anyhow!("private state temporary file could not be created"))?;
        apply_private_file_permissions(&file, &tmp)?;
        file.write_all(content.as_bytes())?;
        sync_all_if_supported(&mut file)?;
        validate_open_state_marker(&tmp, &file)?;
        drop(file);
        rename_into_place(&tmp, path)
            .map_err(|_| anyhow::anyhow!("private state file could not be committed"))?;
        let committed = fs::symlink_metadata(path)
            .map_err(|_| anyhow::anyhow!("private state file disappeared after commit"))?;
        validate_private_file_metadata(&committed)?;
        sync_parent_directory(path)?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    write_result
}

/// Reads an existing owner-only text file without following symbolic links. `None` is returned
/// only when the file is genuinely absent.
pub fn read_private_text_bounded(path: &Path, max_bytes: usize) -> Result<Option<String>> {
    let Some(content) = read_private_bytes_bounded(path, max_bytes)? else {
        return Ok(None);
    };
    String::from_utf8(content)
        .map(Some)
        .map_err(|_| anyhow::anyhow!("private state text is not UTF-8"))
}

/// Opens a validated owner-only marker as an OS lock handle.
pub fn open_private_lock_file(path: &Path) -> Result<fs::File> {
    ensure_private_state_parent(path)?;
    if state_marker_metadata(path)?.is_none()
        && create_private_state_marker(path, b"licolite-private-lock-v1").is_err()
    {
        ensure!(
            state_marker_metadata(path)?.is_some(),
            "private lock file could not be initialized"
        );
    }
    let content = read_private_state_marker(path)?
        .ok_or_else(|| anyhow::anyhow!("private lock file is missing"))?;
    ensure!(
        content == b"licolite-private-lock-v1",
        "private lock file marker is invalid"
    );
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    {
        options.custom_flags(nix::libc::O_NOFOLLOW);
    }
    let file = options
        .open(path)
        .map_err(|_| anyhow::anyhow!("private lock file could not be opened"))?;
    validate_open_state_marker(path, &file)?;
    Ok(file)
}

pub fn ensure_private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    harden_private_path(path)
}

/// Creates a crash-durable, owner-only state marker.
///
/// The marker is intended for fail-closed security state rather than general data storage. Its
/// parent is owner-only, creation is exclusive, symbolic links are rejected, and both the file
/// and containing directory are synchronized before success is reported.
pub fn create_private_state_marker(path: &Path, content: &[u8]) -> Result<()> {
    ensure_private_state_parent(path)?;
    ensure!(
        content.len() <= PRIVATE_STATE_FILE_MAX_BYTES as usize,
        "private security state marker exceeds its bounded size"
    );

    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        options.mode(0o600).custom_flags(nix::libc::O_NOFOLLOW);
    }
    let mut file = options
        .open(path)
        .map_err(|_| anyhow::anyhow!("private security state marker could not be created"))?;
    apply_private_file_permissions(&file, path)?;
    file.write_all(content)?;
    sync_all_if_supported(&mut file)?;
    validate_open_state_marker(path, &file)?;
    sync_parent_directory(path)?;
    Ok(())
}

/// Reads and validates an owner-only state marker without following symbolic links.
///
/// `Ok(None)` is returned only for a genuinely absent marker. An insecure parent, symlink,
/// non-regular file, ownership mismatch, permission mismatch, or path replacement is an error so
/// callers can remain fail closed.
pub fn read_private_state_marker(path: &Path) -> Result<Option<Vec<u8>>> {
    read_private_bytes_bounded(path, PRIVATE_STATE_FILE_MAX_BYTES as usize)
}

fn read_private_bytes_bounded(path: &Path, max_bytes: usize) -> Result<Option<Vec<u8>>> {
    ensure_private_state_parent(path)?;
    let Some(path_metadata) = state_marker_metadata(path)? else {
        return Ok(None);
    };
    validate_private_file_metadata(&path_metadata)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        options.custom_flags(nix::libc::O_NOFOLLOW);
    }
    let mut file = options
        .open(path)
        .map_err(|_| anyhow::anyhow!("private security state marker could not be opened"))?;
    let opened_metadata = file.metadata()?;
    validate_private_file_metadata(&opened_metadata)?;
    ensure_same_file(&path_metadata, &opened_metadata)?;
    ensure!(
        opened_metadata.len() <= max_bytes as u64,
        "private state file exceeds its bounded size"
    );
    let mut content = Vec::with_capacity(opened_metadata.len() as usize);
    Read::by_ref(&mut file)
        .take((max_bytes as u64).saturating_add(1))
        .read_to_end(&mut content)?;
    ensure!(
        content.len() <= max_bytes,
        "private state file exceeds its bounded size"
    );
    let stable_metadata = fs::symlink_metadata(path)
        .map_err(|_| anyhow::anyhow!("private security state marker changed while opening"))?;
    validate_private_file_metadata(&stable_metadata)?;
    ensure_same_file(&opened_metadata, &stable_metadata)?;
    Ok(Some(content))
}

pub fn private_state_marker_exists(path: &Path) -> Result<bool> {
    read_private_state_marker(path).map(|content| content.is_some())
}

/// Removes a validated marker and synchronizes its parent directory before returning.
pub fn remove_private_state_marker(path: &Path) -> Result<bool> {
    ensure_private_state_parent(path)?;
    let Some(path_metadata) = state_marker_metadata(path)? else {
        return Ok(false);
    };
    validate_private_file_metadata(&path_metadata)?;

    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        options.custom_flags(nix::libc::O_NOFOLLOW);
    }
    let file = options
        .open(path)
        .map_err(|_| anyhow::anyhow!("private security state marker could not be opened"))?;
    validate_open_state_marker(path, &file)?;
    let stable_metadata = fs::symlink_metadata(path)
        .map_err(|_| anyhow::anyhow!("private security state marker changed before removal"))?;
    ensure_same_file(&file.metadata()?, &stable_metadata)?;
    fs::remove_file(path)
        .map_err(|_| anyhow::anyhow!("private security state marker could not be removed"))?;
    sync_parent_directory(path)?;
    Ok(true)
}

pub fn harden_private_tree(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    ensure!(
        !metadata.file_type().is_symlink(),
        "private tree contains a symbolic link"
    );
    if metadata.file_type().is_dir() {
        harden_private_path(path)?;
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            harden_private_tree(&entry.path())?;
        }
        let stable = fs::symlink_metadata(path)?;
        ensure!(
            stable.file_type().is_dir() && !stable.file_type().is_symlink(),
            "private tree directory changed during hardening"
        );
        return ensure_same_file(&metadata, &stable);
    }
    ensure!(
        metadata.file_type().is_file(),
        "private tree contains an unsupported node"
    );
    harden_private_path(path)?;
    let stable = fs::symlink_metadata(path)?;
    ensure!(
        stable.file_type().is_file() && !stable.file_type().is_symlink(),
        "private tree file changed during hardening"
    );
    ensure_same_file(&metadata, &stable)
}

pub fn harden_private_path(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    #[cfg(unix)]
    {
        let mode = if path.is_dir() { 0o700 } else { 0o600 };
        fs::set_permissions(path, fs::Permissions::from_mode(mode))
            .with_context(|| format!("failed to apply Unix private mode to {}", path.display()))?;
    }
    #[cfg(windows)]
    {
        apply_windows_owner_only_acl(path)?;
    }
    Ok(())
}

#[cfg(windows)]
fn apply_windows_owner_only_acl(path: &Path) -> Result<()> {
    let ace = if path.is_dir() {
        "*S-1-3-4:(OI)(CI)(F)"
    } else {
        "*S-1-3-4:(F)"
    };
    let output = Command::new("icacls")
        .arg(path)
        .args(["/inheritance:r", "/grant:r", ace])
        .output()
        .with_context(|| format!("failed to launch icacls for {}", path.display()))?;
    if output.status.success() {
        return Ok(());
    }
    Err(anyhow!(
        "icacls owner-only ACL failed for {}: {}",
        path.display(),
        String::from_utf8_lossy(&output.stderr).trim()
    ))
}

fn rename_into_place(tmp: &Path, path: &Path) -> Result<()> {
    validate_regular_file_or_missing_no_follow(tmp, false)?;
    validate_regular_file_or_missing_no_follow(path, true)?;
    match fs::rename(tmp, path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::CrossesDevices => {
            copy_cross_device_then_atomic_replace(tmp, path)
        }
        Err(error) => Err(error.into()),
    }
}

/// Cross-device fallback for callers that provide a temporary file on another filesystem.
/// Content is copied into a new, no-follow sibling of the destination and only that sibling is
/// renamed over the destination. The live destination is never moved aside or streamed into.
fn copy_cross_device_then_atomic_replace(tmp: &Path, path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("atomic replacement destination parent is missing"))?;
    validate_no_symlink_ancestors(parent)?;
    let stage = sibling_temp_path(path);
    validate_regular_file_or_missing_no_follow(&stage, true)?;

    let source_path_metadata = fs::symlink_metadata(tmp)?;
    validate_private_file_type_and_owner(&source_path_metadata)?;
    let mut source_options = OpenOptions::new();
    source_options.read(true);
    #[cfg(unix)]
    source_options.custom_flags(nix::libc::O_NOFOLLOW);
    let mut source = source_options
        .open(tmp)
        .map_err(|_| anyhow!("atomic replacement source could not be opened"))?;
    ensure_same_file(&source_path_metadata, &source.metadata()?)?;

    let result = (|| -> Result<()> {
        let mut stage_options = OpenOptions::new();
        stage_options.create_new(true).write(true);
        #[cfg(unix)]
        stage_options
            .mode(0o600)
            .custom_flags(nix::libc::O_NOFOLLOW);
        let mut staged = stage_options
            .open(&stage)
            .map_err(|_| anyhow!("atomic replacement stage could not be created"))?;
        apply_private_file_permissions(&staged, &stage)?;
        io::copy(&mut source, &mut staged)?;
        sync_all_if_supported(&mut staged)?;
        validate_open_state_marker(&stage, &staged)?;
        drop(staged);

        validate_no_symlink_ancestors(parent)?;
        validate_regular_file_or_missing_no_follow(path, true)?;
        fs::rename(&stage, path).map_err(|_| anyhow!("atomic replacement commit failed"))?;
        sync_parent_directory(path)?;
        let stable_source = fs::symlink_metadata(tmp)
            .map_err(|_| anyhow!("atomic replacement source changed before cleanup"))?;
        ensure_same_file(&source_path_metadata, &stable_source)?;
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

fn sync_all_if_supported(file: &mut fs::File) -> Result<()> {
    if let Err(error) = file.sync_all() {
        if is_unsupported_sync_error(&error) {
            return Ok(());
        }
        return Err(error.into());
    }
    Ok(())
}

fn ensure_private_state_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("private security state marker parent is missing"))?;
    let parent_existed = parent.try_exists()?;
    if parent_existed {
        validate_private_directory_type_and_owner(parent)?;
    } else {
        fs::create_dir_all(parent)?;
        validate_private_directory_type_and_owner(parent)?;
    }
    apply_private_directory_permissions(parent)?;
    validate_private_directory_metadata(&fs::symlink_metadata(parent)?)?;
    if !parent_existed {
        if let Some(grandparent) = parent.parent() {
            sync_directory_if_supported(grandparent)?;
        }
    }
    Ok(())
}

fn ensure_atomic_write_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("private state file parent is missing"))?;
    if !parent.try_exists()? {
        fs::create_dir_all(parent)?;
    }
    let metadata = fs::symlink_metadata(parent)
        .map_err(|_| anyhow::anyhow!("private state file parent is unavailable"))?;
    ensure!(
        !metadata.file_type().is_symlink() && metadata.file_type().is_dir(),
        "private state file parent is not a stable directory"
    );
    Ok(())
}

fn validate_private_directory_type_and_owner(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|_| anyhow::anyhow!("private security state directory is unavailable"))?;
    ensure!(
        !metadata.file_type().is_symlink() && metadata.file_type().is_dir(),
        "private security state directory is not a stable directory"
    );
    validate_current_owner(&metadata)
}

fn apply_private_directory_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    #[cfg(windows)]
    apply_windows_owner_only_acl(path)?;
    Ok(())
}

fn apply_private_file_permissions(file: &fs::File, path: &Path) -> Result<()> {
    #[cfg(unix)]
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    #[cfg(windows)]
    apply_windows_owner_only_acl(path)?;
    #[cfg(not(windows))]
    let _ = path;
    Ok(())
}

fn state_marker_metadata(path: &Path) -> Result<Option<fs::Metadata>> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(anyhow::anyhow!(
            "private security state marker metadata is unavailable"
        )),
    }
}

fn validate_open_state_marker(path: &Path, file: &fs::File) -> Result<()> {
    let path_metadata = fs::symlink_metadata(path)
        .map_err(|_| anyhow::anyhow!("private security state marker changed while opening"))?;
    let opened_metadata = file.metadata()?;
    validate_private_file_metadata(&path_metadata)?;
    validate_private_file_metadata(&opened_metadata)?;
    ensure_same_file(&path_metadata, &opened_metadata)
}

fn validate_private_file_metadata(metadata: &fs::Metadata) -> Result<()> {
    validate_private_file_type_and_owner(metadata)?;
    #[cfg(unix)]
    ensure!(
        metadata.mode() & 0o777 == 0o600,
        "private security state marker permissions are insecure"
    );
    Ok(())
}

fn validate_private_file_type_and_owner(metadata: &fs::Metadata) -> Result<()> {
    ensure!(
        !metadata.file_type().is_symlink() && metadata.file_type().is_file(),
        "private security state marker is not a stable regular file"
    );
    validate_current_owner(metadata)?;
    Ok(())
}

fn validate_private_directory_metadata(metadata: &fs::Metadata) -> Result<()> {
    ensure!(
        !metadata.file_type().is_symlink() && metadata.file_type().is_dir(),
        "private security state directory is not a stable directory"
    );
    validate_current_owner(metadata)?;
    #[cfg(unix)]
    ensure!(
        metadata.mode() & 0o777 == 0o700,
        "private security state directory permissions are insecure"
    );
    Ok(())
}

#[cfg(unix)]
pub(crate) fn validate_path_owner(metadata: &fs::Metadata) -> Result<()> {
    let effective_uid = nix::unistd::Uid::effective().as_raw();
    ensure!(
        metadata.uid() == effective_uid,
        "path owner is not the current user"
    );
    Ok(())
}

#[cfg(not(unix))]
pub(crate) fn validate_path_owner(_metadata: &fs::Metadata) -> Result<()> {
    Ok(())
}

/// Validate that an export destination path is owned by the current user.
/// For paths that exist, the path itself is checked. For paths that do not
/// yet exist, the nearest existing ancestor directory is checked.
pub(crate) fn validate_export_destination(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(_) => return Err(anyhow!("export destination metadata is unavailable")),
    };
    let check = if metadata.is_some() {
        path
    } else {
        path.parent()
            .ok_or_else(|| anyhow!("export destination has no parent directory"))?
    };
    let metadata = fs::symlink_metadata(check)
        .map_err(|_| anyhow!("export destination metadata is unavailable"))?;
    ensure!(
        !metadata.file_type().is_symlink(),
        "export destination must not be a symlink"
    );
    validate_path_owner(&metadata)
}

/// Reject symbolic links in every existing component of a path. Missing suffixes are allowed so
/// callers can validate a destination before creating it one component at a time.
pub(crate) fn validate_no_symlink_ancestors(path: &Path) -> Result<()> {
    ensure!(
        !path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir)),
        "path contains a parent traversal component"
    );
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut current = PathBuf::new();
    for component in absolute.components() {
        current.push(component.as_os_str());
        match fs::symlink_metadata(&current) {
            Ok(metadata) => ensure!(
                !metadata.file_type().is_symlink(),
                "path contains a symbolic-link ancestor"
            ),
            Err(error) if error.kind() == io::ErrorKind::NotFound => break,
            Err(_) => return Err(anyhow!("path ancestor metadata is unavailable")),
        }
    }
    Ok(())
}

#[cfg(unix)]
fn validate_no_user_owned_symlink_ancestors(path: &Path) -> Result<()> {
    ensure!(
        !path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir)),
        "path contains a parent traversal component"
    );
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut current = PathBuf::new();
    for component in absolute.components() {
        current.push(component.as_os_str());
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => ensure!(
                metadata.uid() == 0,
                "path contains a user-controlled symbolic-link ancestor"
            ),
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => break,
            Err(_) => return Err(anyhow!("path ancestor metadata is unavailable")),
        }
    }
    Ok(())
}

fn validate_regular_file_or_missing_no_follow(path: &Path, allow_missing: bool) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => ensure!(
            metadata.file_type().is_file() && !metadata.file_type().is_symlink(),
            "atomic replacement path is not a stable regular file"
        ),
        Err(error) if allow_missing && error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

#[cfg(unix)]
fn validate_current_owner(metadata: &fs::Metadata) -> Result<()> {
    let effective_uid = nix::unistd::Uid::effective().as_raw();
    ensure!(
        metadata.uid() == effective_uid,
        "private security state path owner is invalid"
    );
    Ok(())
}

#[cfg(not(unix))]
fn validate_current_owner(_metadata: &fs::Metadata) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn ensure_same_file(left: &fs::Metadata, right: &fs::Metadata) -> Result<()> {
    ensure!(
        left.dev() == right.dev() && left.ino() == right.ino(),
        "private security state marker path was replaced"
    );
    Ok(())
}

#[cfg(unix)]
fn validate_private_file_stat(stat: &nix::sys::stat::FileStat) -> Result<()> {
    ensure!(
        stat.st_mode & nix::libc::S_IFMT == nix::libc::S_IFREG,
        "private append file is not a regular file"
    );
    ensure!(
        stat.st_uid == nix::unistd::Uid::effective().as_raw(),
        "private append file owner is invalid"
    );
    ensure!(
        stat.st_mode & 0o777 == 0o600,
        "private append file permissions are insecure"
    );
    ensure!(stat.st_size >= 0, "private append file size is invalid");
    Ok(())
}

#[cfg(unix)]
fn ensure_metadata_matches_stat(
    metadata: &fs::Metadata,
    stat: &nix::sys::stat::FileStat,
) -> Result<()> {
    let stat_device =
        u64::try_from(stat.st_dev).map_err(|_| anyhow!("private append file device is invalid"))?;
    let stat_inode =
        u64::try_from(stat.st_ino).map_err(|_| anyhow!("private append file inode is invalid"))?;
    ensure!(
        metadata.dev() == stat_device && metadata.ino() == stat_inode,
        "private append file path was replaced"
    );
    Ok(())
}

#[cfg(not(unix))]
fn ensure_same_file(left: &fs::Metadata, right: &fs::Metadata) -> Result<()> {
    ensure!(
        left.file_type().is_file()
            && right.file_type().is_file()
            && left.len() == right.len()
            && left.created().ok() == right.created().ok(),
        "private security state marker path was replaced"
    );
    Ok(())
}

fn sync_parent_directory(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("private security state marker parent is missing"))?;
    sync_directory_if_supported(parent)
}

fn sync_directory_if_supported(directory: &Path) -> Result<()> {
    let file = match fs::File::open(directory) {
        Ok(file) => file,
        Err(error) if is_unsupported_sync_error(&error) => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if let Err(error) = file.sync_all() {
        if is_unsupported_sync_error(&error) {
            return Ok(());
        }
        return Err(error.into());
    }
    Ok(())
}

#[cfg(windows)]
fn is_unsupported_sync_error(error: &io::Error) -> bool {
    error.kind() == ErrorKind::PermissionDenied
}

#[cfg(not(windows))]
fn is_unsupported_sync_error(_error: &io::Error) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    fn temp_path(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        env::temp_dir().join(format!("lico-file-security-{}-{}", name, stamp))
    }

    #[cfg(windows)]
    #[test]
    fn harden_private_path_sets_owner_rights_acl() {
        let path = temp_path("owner-rights.txt");
        fs::write(&path, "secret").unwrap();

        harden_private_path(&path).unwrap();

        let output = Command::new("icacls").arg(&path).output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(output.status.success());
        assert!(stdout.contains("OWNER RIGHTS:(F)"));

        fs::remove_file(path).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn atomic_write_private_text_applies_private_file_mode() {
        let path = temp_path("unix-mode.json");

        atomic_write_private_text(&path, "{\"ok\":true}\n").unwrap();

        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        fs::remove_file(path).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn private_state_marker_survives_reopen_and_is_durably_removed() {
        let root = temp_path("private-state-marker");
        let path = root.join("security.guard");
        let body = br#"{"schemaVersion":1,"state":"blocked"}\n"#;

        create_private_state_marker(&path, body).unwrap();
        assert_eq!(
            read_private_state_marker(&path).unwrap(),
            Some(body.to_vec())
        );
        assert_eq!(
            fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );

        assert!(remove_private_state_marker(&path).unwrap());
        assert!(!private_state_marker_exists(&path).unwrap());
        fs::remove_dir(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn private_state_marker_rejects_symbolic_link_substitution() {
        use std::os::unix::fs::symlink;

        let root = temp_path("private-state-marker-symlink");
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let target = root.join("target");
        let marker = root.join("security.guard");
        fs::write(&target, b"insecure").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        symlink(&target, &marker).unwrap();

        assert!(private_state_marker_exists(&marker).is_err());
        assert!(remove_private_state_marker(&marker).is_err());

        fs::remove_file(marker).unwrap();
        fs::remove_file(target).unwrap();
        fs::remove_dir(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn private_append_rejects_symbolic_link_without_touching_referent() {
        use std::os::unix::fs::symlink;

        let root = temp_path("private-append-symlink");
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let referent = root.join("referent.jsonl");
        let append_path = root.join("activity.jsonl");
        fs::write(&referent, b"preserve\n").unwrap();
        fs::set_permissions(&referent, fs::Permissions::from_mode(0o600)).unwrap();
        symlink(&referent, &append_path).unwrap();

        assert!(append_private_line(&append_path, r#"{"secret":"blocked"}"#).is_err());
        assert_eq!(fs::read(&referent).unwrap(), b"preserve\n");

        fs::remove_file(append_path).unwrap();
        fs::remove_file(referent).unwrap();
        fs::remove_dir(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn private_append_rejects_user_owned_symbolic_link_ancestor() {
        use std::os::unix::fs::symlink;

        let root = temp_path("private-append-ancestor");
        let outside = temp_path("private-append-ancestor-outside");
        let outside_nested = outside.join("nested");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(&outside_nested).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&outside, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&outside_nested, fs::Permissions::from_mode(0o700)).unwrap();
        symlink(&outside, root.join("redirect")).unwrap();
        let append_path = root.join("redirect/nested/activity.jsonl");

        assert!(append_private_line(&append_path, r#"{"secret":"blocked"}"#).is_err());
        assert!(!outside_nested.join("activity.jsonl").exists());

        fs::remove_file(root.join("redirect")).unwrap();
        fs::remove_dir_all(root).unwrap();
        fs::remove_dir_all(outside).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn private_append_creates_owner_only_bounded_regular_file() {
        let root = temp_path("private-append-owner-only");
        let append_path = root.join("activity.jsonl");

        append_private_line(&append_path, r#"{"ok":true}"#).unwrap();

        let metadata = fs::symlink_metadata(&append_path).unwrap();
        assert!(metadata.file_type().is_file());
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::read_to_string(&append_path).unwrap(), "{\"ok\":true}\n");

        fs::remove_file(append_path).unwrap();
        fs::remove_dir(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn harden_private_tree_rejects_nested_and_broken_symbolic_links() {
        use std::os::unix::fs::symlink;

        let root = temp_path("private-tree-symlink");
        let nested = root.join("nested");
        fs::create_dir_all(&nested).unwrap();
        let outside = temp_path("private-tree-outside");
        fs::write(&outside, b"preserve").unwrap();
        symlink(&outside, nested.join("external-link")).unwrap();

        assert!(harden_private_tree(&root).is_err());
        assert_eq!(fs::read(&outside).unwrap(), b"preserve");
        fs::remove_file(nested.join("external-link")).unwrap();
        symlink(root.join("missing"), nested.join("broken-link")).unwrap();
        assert!(harden_private_tree(&root).is_err());

        fs::remove_file(nested.join("broken-link")).unwrap();
        fs::remove_dir_all(root).unwrap();
        fs::remove_file(outside).unwrap();
    }

    #[test]
    fn atomic_replacement_does_not_treat_non_cross_device_errors_as_copy_fallback() {
        let root = temp_path("atomic-non-exdev");
        fs::create_dir_all(&root).unwrap();
        let temporary = root.join("source.tmp");
        let destination = root.join("destination");
        fs::write(&temporary, b"replacement").unwrap();
        fs::create_dir(&destination).unwrap();
        fs::write(destination.join("sentinel"), b"preserve").unwrap();

        let result = rename_into_place(&temporary, &destination);

        assert!(result.is_err());
        assert_eq!(fs::read(destination.join("sentinel")).unwrap(), b"preserve");
        assert_eq!(fs::read(&temporary).unwrap(), b"replacement");
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn atomic_replacement_rejects_destination_symlink_without_touching_referent() {
        use std::os::unix::fs::symlink;

        let root = temp_path("atomic-destination-link");
        fs::create_dir_all(&root).unwrap();
        let temporary = root.join("source.tmp");
        let referent = root.join("referent");
        let destination = root.join("destination");
        fs::write(&temporary, b"replacement").unwrap();
        fs::write(&referent, b"preserve").unwrap();
        symlink(&referent, &destination).unwrap();

        let result = rename_into_place(&temporary, &destination);

        assert!(result.is_err());
        assert_eq!(fs::read(&referent).unwrap(), b"preserve");
        assert_eq!(fs::read(&temporary).unwrap(), b"replacement");
        fs::remove_dir_all(root).unwrap();
    }
}
