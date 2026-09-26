//! Root-relative reclamation. Like Rust's Unix remove_dir_all and the archive
//! extractor, descent uses open directory descriptors and never follows links.
use super::refusal;
use licoup_application::ApplicationFailure;
use std::path::{Component, Path};

fn unsafe_path() -> ApplicationFailure {
    refusal("package_path_unsafe", "extension/package-storage")
}

/// Validate every existing ancestor, not just the last component. Missing
/// descendants are permitted for installation; dot segments are never inputs.
pub(super) fn check(root: &Path, path: &Path) -> Result<(), ApplicationFailure> {
    let relative = path.strip_prefix(root).map_err(|_| unsafe_path())?;
    let mut current = root.to_path_buf();
    for component in relative.components() {
        let Component::Normal(name) = component else {
            return Err(unsafe_path());
        };
        current.push(name);
        match std::fs::symlink_metadata(&current) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err(unsafe_path());
                }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return Err(unsafe_path());
                    }
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(unsafe_path()),
        }
    }
    Ok(())
}

/// Open a fresh lock description per transaction, including across Store clones
/// and processes. Closing the descriptor releases the lock even after failure.
pub(super) fn lock(root: &Path) -> Result<std::fs::File, ApplicationFailure> {
    let path = root.join(".transaction.lock");
    check(root, &path)?;
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let file = options.open(path).map_err(|_| unsafe_path())?;
    fs2::FileExt::lock_exclusive(&file).map_err(|_| unsafe_path())?;
    Ok(file)
}

pub(super) fn remove(root: &Path, path: &Path) -> Result<u64, ApplicationFailure> {
    check(root, path)?;
    let relative = path.strip_prefix(root).map_err(|_| unsafe_path())?;
    if relative.as_os_str().is_empty() {
        return Err(unsafe_path());
    }
    #[cfg(unix)]
    {
        unix::remove(root, relative).map_err(|_| unsafe_path())
    }
    #[cfg(not(unix))]
    {
        // No path-based fallback: it would reintroduce ancestor replacement
        // between validation and deletion. Platforms need their native handle
        // implementation before they can reclaim optional package bytes.
        Err(refusal(
            "package_reclamation_unsupported",
            "extension/package-storage",
        ))
    }
}

#[cfg(unix)]
mod unix {
    use std::ffi::{CStr, CString, OsStr, OsString};
    use std::fs::{File, OpenOptions};
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    use std::os::unix::fs::OpenOptionsExt;
    use std::path::Path;

    fn name(value: &OsStr) -> io::Result<CString> {
        CString::new(value.as_bytes()).map_err(|_| io::ErrorKind::InvalidInput.into())
    }
    fn directory(parent: &File, name: &CStr) -> io::Result<File> {
        // SAFETY: borrowed descriptor and terminated name stay alive for call.
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openat returned a newly owned descriptor.
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    fn entries(dir: &File) -> io::Result<Vec<OsString>> {
        let copy = directory(dir, c".")?;
        let fd = copy.into_raw_fd();
        // SAFETY: fd is transferred to the directory stream on success.
        let stream = unsafe { libc::fdopendir(fd) };
        if stream.is_null() {
            let error = io::Error::last_os_error();
            // SAFETY: fdopendir failed, so ownership of fd never transferred.
            unsafe {
                libc::close(fd);
            }
            return Err(error);
        }
        struct Stream(*mut libc::DIR);
        impl Drop for Stream {
            fn drop(&mut self) {
                // SAFETY: a successful fdopendir returned this exclusively
                // owned stream, and Drop runs once.
                unsafe {
                    libc::closedir(self.0);
                }
            }
        }
        let stream = Stream(stream);
        let mut result = Vec::new();
        loop {
            // SAFETY: this function exclusively owns the DIR stream. readdir's
            // storage stays valid until the next call, and the name is copied
            // before then. Avoid readdir_r: its caller-sized dirent buffer
            // cannot safely represent filesystems whose NAME_MAX exceeds the
            // libc dirent declaration.
            let found = unsafe { libc::readdir(stream.0) };
            if found.is_null() {
                // A read error leaves entries behind, so the descriptor-relative
                // AT_REMOVEDIR below refuses the non-empty directory. Treating a
                // null result as the end here therefore cannot turn a partial
                // walk into successful reclamation.
                break;
            }
            // SAFETY: readdir returned a live dirent whose d_name is
            // NUL-terminated and remains valid until the next stream call.
            let bytes = unsafe { CStr::from_ptr((*found).d_name.as_ptr()) }.to_bytes();
            if bytes != b"." && bytes != b".." {
                result.push(OsString::from_vec(bytes.to_vec()));
            }
        }
        Ok(result)
    }
    fn remove_at(parent: &File, name: &CStr) -> io::Result<u64> {
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: initialized by fstatat on success, with no symlink following.
        if unsafe {
            libc::fstatat(
                parent.as_raw_fd(),
                name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::NotFound {
                Ok(0)
            } else {
                Err(error)
            };
        }
        let stat = unsafe { stat.assume_init() };
        let kind = stat.st_mode & libc::S_IFMT;
        let mut bytes = 0;
        let flags = if kind == libc::S_IFDIR {
            let child = directory(parent, name)?;
            for entry in entries(&child)? {
                bytes += remove_at(&child, &self::name(&entry)?)?;
            }
            libc::AT_REMOVEDIR
        } else if kind == libc::S_IFREG {
            bytes = stat.st_size.max(0) as u64;
            0
        } else {
            return Err(io::ErrorKind::InvalidInput.into());
        };
        // SAFETY: unlink is relative to the held parent, never a resolved path.
        if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), flags) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(bytes)
    }
    pub(super) fn remove(root: &Path, relative: &Path) -> io::Result<u64> {
        let mut parent = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(root)?;
        let mut parts = relative.iter().peekable();
        while let Some(part) = parts.next() {
            let name = name(part)?;
            if parts.peek().is_none() {
                return remove_at(&parent, &name);
            }
            parent = match directory(&parent, &name) {
                Ok(dir) => dir,
                Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
                Err(error) => return Err(error),
            };
        }
        Err(io::ErrorKind::InvalidInput.into())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn sandbox(label: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "licoup-managed-{label}-{}",
            super::super::unique_suffix()
        ));
        super::super::ensure_private_directory(&root).expect("sandbox");
        root
    }

    #[test]
    fn descriptor_walk_removes_nested_files_and_accounts_for_their_bytes() {
        let root = sandbox("nested");
        let target = root.join("package");
        super::super::ensure_private_directory(&target.join("nested")).expect("nested");
        std::fs::write(target.join("root.bin"), [1_u8; 7]).expect("root file");
        std::fs::write(target.join("nested/leaf.bin"), [2_u8; 11]).expect("leaf file");

        assert_eq!(remove(&root, &target).expect("remove"), 18);
        assert!(!target.exists());
        std::fs::remove_dir(&root).expect("sandbox cleanup");
    }

    #[test]
    fn descriptor_walk_refuses_a_symlink_and_preserves_its_target() {
        let root = sandbox("symlink");
        let outside = sandbox("outside");
        let sentinel = outside.join("sentinel");
        std::fs::write(&sentinel, b"keep").expect("sentinel");
        let target = root.join("package");
        super::super::ensure_private_directory(&target).expect("package");
        symlink(&outside, target.join("escape")).expect("symlink");

        assert_eq!(
            remove(&root, &target).expect_err("refuse link").code,
            "package_path_unsafe"
        );
        assert_eq!(std::fs::read(&sentinel).expect("sentinel remains"), b"keep");

        std::fs::remove_file(target.join("escape")).expect("link cleanup");
        std::fs::remove_dir(&target).expect("target cleanup");
        std::fs::remove_dir(&root).expect("root cleanup");
        std::fs::remove_file(&sentinel).expect("sentinel cleanup");
        std::fs::remove_dir(&outside).expect("outside cleanup");
    }
}
