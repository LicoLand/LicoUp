//! Safe archive extraction — streaming, bounded, and no-follow.
//!
//! Replaces the system `tar` subprocess with a Rust-native extractor that
//! enforces path traversal rejection, entry type allowlisting, and
//! configurable byte / entry / depth limits.

use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Component, Path, PathBuf};

#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd};
#[cfg(unix)]
use std::os::unix::ffi::OsStrExt;

use anyhow::{Context, Result, anyhow, ensure};
use flate2::read::GzDecoder;
use tar::{Archive, EntryType};

/// Default maximum total bytes extracted across all entries.
const DEFAULT_MAX_TOTAL_BYTES: u64 = 512 * 1024 * 1024; // 512 MiB

/// Default maximum number of entries.
const DEFAULT_MAX_ENTRIES: usize = 10_000;

/// Default maximum directory depth relative to destination root.
const DEFAULT_MAX_DEPTH: usize = 32;

/// Extract a `.tar.gz` byte slice to `destination` with safety bounds.
///
/// Rejects:
/// - Path traversal components (`../`, absolute paths).
/// - Special entries (device nodes, FIFOs, hard links, symlinks to
///   external paths).
/// - Archives exceeding `max_total_bytes`, `max_entries`, or
///   `max_depth`.
pub fn extract_tar_gz_safe(
    bytes: &[u8],
    destination: &Path,
    max_total_bytes: Option<u64>,
    max_entries: Option<usize>,
    max_depth: Option<usize>,
) -> Result<()> {
    let max_total_bytes = max_total_bytes.unwrap_or(DEFAULT_MAX_TOTAL_BYTES);
    let max_entries = max_entries.unwrap_or(DEFAULT_MAX_ENTRIES);
    let max_depth = max_depth.unwrap_or(DEFAULT_MAX_DEPTH);

    let cursor = std::io::Cursor::new(bytes);
    let decoder = GzDecoder::new(cursor);
    let mut archive = Archive::new(decoder);

    let mut total_bytes = 0_u64;
    let mut entry_count: usize = 0;
    let extraction_root = ExtractionRoot::open(destination)?;

    for entry in archive.entries()? {
        let mut entry = entry?;
        entry_count += 1;

        ensure!(
            entry_count <= max_entries,
            "archive entry count {entry_count} exceeds maximum {max_entries}"
        );

        let entry_type = entry.header().entry_type();

        // Allow only regular files and directories.
        ensure!(
            entry_type == EntryType::Regular || entry_type == EntryType::Directory,
            "archive entry {entry_count} has unsupported type {entry_type:?}; only regular files and directories are allowed"
        );

        // Validate and sanitize the entry path.
        let entry_path = entry.path()?;
        let relative = sanitize_entry_path(&entry_path, max_depth)?;

        if entry_type == EntryType::Directory {
            extraction_root.create_directory(&relative)?;
            continue;
        }

        let declared_size = entry.size();
        let next_total = total_bytes
            .checked_add(declared_size)
            .ok_or_else(|| anyhow!("archive extracted byte count overflowed"))?;
        ensure!(next_total <= max_total_bytes, "archive byte limit exceeded");
        let mut file = extraction_root.create_file(&relative)?;
        let written = std::io::copy(&mut entry, &mut file)?;

        ensure!(
            written == declared_size,
            "archive entry {entry_count} size did not match its header"
        );
        file.flush()?;
        file.sync_all()?;
        total_bytes = next_total;
    }

    Ok(())
}

/// Validate and sanitize a single entry path from the archive.
fn sanitize_entry_path(raw: &Path, max_depth: usize) -> Result<PathBuf> {
    // Reject absolute paths.
    ensure!(
        raw.is_relative(),
        "archive entry path must be relative: {}",
        raw.display()
    );

    // Reject path traversal components.
    for component in raw.components() {
        match component {
            Component::ParentDir => {
                return Err(anyhow!(
                    "archive entry contains path traversal: {}",
                    raw.display()
                ));
            }
            Component::Prefix(_) | Component::RootDir => {
                return Err(anyhow!(
                    "archive entry contains absolute or prefixed component: {}",
                    raw.display()
                ));
            }
            _ => {}
        }
    }

    // Reject empty paths or paths that normalize to empty.
    let normalized: PathBuf = raw
        .components()
        .filter(|c| !matches!(c, std::path::Component::CurDir))
        .collect();
    if normalized.as_os_str().is_empty() {
        return Err(anyhow!("archive entry path is empty after normalization"));
    }

    // Check depth.
    let depth = normalized.components().count();
    ensure!(
        depth <= max_depth,
        "archive entry depth {} exceeds maximum {}: {}",
        depth,
        max_depth,
        normalized.display()
    );

    Ok(normalized)
}

/// A root directory held open for the whole extraction. On Unix every descendant is opened
/// relative to an already-open directory descriptor with `O_NOFOLLOW`, closing the ancestor
/// symlink race that path-based `canonicalize` checks leave behind.
struct ExtractionRoot {
    #[cfg(unix)]
    directory: fs::File,
    #[cfg(not(unix))]
    path: PathBuf,
}

impl ExtractionRoot {
    fn open(path: &Path) -> Result<Self> {
        ensure!(!path.as_os_str().is_empty(), "archive destination is empty");
        #[cfg(unix)]
        {
            let mut current = if path.is_absolute() {
                open_directory(Path::new("/"))?
            } else {
                open_directory(Path::new("."))?
            };
            for component in path.components() {
                match component {
                    Component::RootDir | Component::CurDir => {}
                    Component::Normal(name) => {
                        current = open_or_create_directory_at(&current, name)?;
                    }
                    Component::ParentDir | Component::Prefix(_) => {
                        return Err(anyhow!(
                            "archive destination contains an unsafe path component"
                        ));
                    }
                }
            }
            Ok(Self { directory: current })
        }
        #[cfg(not(unix))]
        {
            create_directory_path_no_follow(path)?;
            Ok(Self {
                path: path.to_path_buf(),
            })
        }
    }

    fn create_directory(&self, relative: &Path) -> Result<()> {
        #[cfg(unix)]
        {
            let _ = self.open_parent(relative, true)?;
            Ok(())
        }
        #[cfg(not(unix))]
        {
            create_directory_path_no_follow(&self.path.join(relative))
        }
    }

    fn create_file(&self, relative: &Path) -> Result<fs::File> {
        let leaf = relative
            .file_name()
            .ok_or_else(|| anyhow!("archive file entry has no file name"))?;
        #[cfg(unix)]
        {
            let parent = self.open_parent(relative, false)?;
            create_file_at(&parent, leaf)
        }
        #[cfg(not(unix))]
        {
            let destination = self.path.join(relative);
            let parent = destination
                .parent()
                .ok_or_else(|| anyhow!("archive file entry has no parent"))?;
            create_directory_path_no_follow(parent)?;
            ensure_missing_or_regular_no_follow(&destination)?;
            OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&destination)
                .with_context(|| "archive output file could not be created")
        }
    }

    #[cfg(unix)]
    fn open_parent(&self, relative: &Path, include_leaf: bool) -> Result<fs::File> {
        let mut current = self.directory.try_clone()?;
        let component_count = relative.components().count();
        for (index, component) in relative.components().enumerate() {
            let Component::Normal(name) = component else {
                return Err(anyhow!("archive entry contains an unsafe component"));
            };
            if !include_leaf && index + 1 == component_count {
                break;
            }
            current = open_or_create_directory_at(&current, name)?;
        }
        Ok(current)
    }
}

#[cfg(unix)]
fn open_directory(path: &Path) -> Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_DIRECTORY | nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(path)
        .with_context(|| "archive destination ancestor is not a no-follow directory")
}

#[cfg(unix)]
fn component_cstring(name: &std::ffi::OsStr) -> Result<CString> {
    CString::new(name.as_bytes()).map_err(|_| anyhow!("archive path contains a NUL byte"))
}

#[cfg(unix)]
fn open_or_create_directory_at(parent: &fs::File, name: &std::ffi::OsStr) -> Result<fs::File> {
    let name = component_cstring(name)?;
    let flags =
        nix::libc::O_RDONLY | nix::libc::O_DIRECTORY | nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC;
    let mut fd = unsafe { nix::libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::NotFound {
            return Err(anyhow!(
                "archive destination ancestor is not a no-follow directory"
            ));
        }
        let created = unsafe { nix::libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
        if created != 0 {
            let create_error = std::io::Error::last_os_error();
            if create_error.kind() != std::io::ErrorKind::AlreadyExists {
                return Err(anyhow!(
                    "archive destination directory could not be created"
                ));
            }
        }
        fd = unsafe { nix::libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
    }
    if fd < 0 {
        return Err(anyhow!(
            "archive destination ancestor changed during extraction"
        ));
    }
    Ok(unsafe { fs::File::from_raw_fd(fd) })
}

#[cfg(unix)]
fn create_file_at(parent: &fs::File, name: &std::ffi::OsStr) -> Result<fs::File> {
    let name = component_cstring(name)?;
    let flags = nix::libc::O_WRONLY
        | nix::libc::O_CREAT
        | nix::libc::O_EXCL
        | nix::libc::O_NOFOLLOW
        | nix::libc::O_CLOEXEC;
    let fd = unsafe { nix::libc::openat(parent.as_raw_fd(), name.as_ptr(), flags, 0o600) };
    if fd < 0 {
        return Err(anyhow!(
            "archive output must be a new regular file below the extraction root"
        ));
    }
    Ok(unsafe { fs::File::from_raw_fd(fd) })
}

#[cfg(not(unix))]
fn create_directory_path_no_follow(path: &Path) -> Result<()> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut current = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::Prefix(_) | Component::RootDir | Component::Normal(_) => {
                current.push(component.as_os_str());
            }
            Component::CurDir => continue,
            Component::ParentDir => {
                return Err(anyhow!("archive path contains a parent component"));
            }
        }
        match fs::symlink_metadata(&current) {
            Ok(metadata) => ensure!(
                metadata.is_dir() && !metadata.file_type().is_symlink(),
                "archive destination ancestor is not a no-follow directory"
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&current)?;
                ensure_missing_or_regular_no_follow(&current)?;
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

#[cfg(not(unix))]
fn ensure_missing_or_regular_no_follow(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => ensure!(
            !metadata.file_type().is_symlink(),
            "archive output path is a symbolic link"
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temp_dir() -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let id = COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("lico-safe-archive-test-{id}"));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    }

    fn create_test_tar_gz(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut tar_buf = Vec::new();
        {
            let mut builder = tar::Builder::new(&mut tar_buf);
            for (path, data) in entries {
                let mut header = tar::Header::new_gnu();
                header.set_path(path).unwrap();
                header.set_size(data.len() as u64);
                header.set_mode(0o644);
                header.set_cksum();
                builder.append(&header, &data[..]).unwrap();
            }
            builder.finish().unwrap();
        }
        let mut gz_buf = Vec::new();
        {
            let mut encoder =
                flate2::write::GzEncoder::new(&mut gz_buf, flate2::Compression::default());
            encoder.write_all(&tar_buf).unwrap();
            encoder.finish().unwrap();
        }
        gz_buf
    }

    /// `tar::Header::set_path` rejects hostile paths itself. Writing the raw name field ensures
    /// these fixtures reach the production extractor instead of failing in setup.
    fn create_test_tar_gz_with_raw_path(path: &[u8], data: &[u8]) -> Vec<u8> {
        assert!(path.len() < 100);
        let mut tar_buf = Vec::new();
        {
            let mut builder = tar::Builder::new(&mut tar_buf);
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o600);
            header.set_entry_type(EntryType::Regular);
            let bytes = header.as_mut_bytes();
            bytes[..100].fill(0);
            bytes[..path.len()].copy_from_slice(path);
            header.set_cksum();
            builder.append(&header, data).unwrap();
            builder.finish().unwrap();
        }
        let mut gz_buf = Vec::new();
        {
            let mut encoder =
                flate2::write::GzEncoder::new(&mut gz_buf, flate2::Compression::default());
            encoder.write_all(&tar_buf).unwrap();
            encoder.finish().unwrap();
        }
        gz_buf
    }

    #[test]
    fn safe_extract_regular_files() {
        let temp = temp_dir();
        let dest = temp.join("out");
        let archive = create_test_tar_gz(&[
            ("hello.txt", b"hello world"),
            ("sub/deep.txt", b"deep content"),
        ]);
        extract_tar_gz_safe(&archive, &dest, None, None, None).unwrap();
        assert!(dest.join("hello.txt").exists());
        assert!(dest.join("sub").join("deep.txt").exists());
        assert_eq!(
            fs::read_to_string(dest.join("hello.txt")).unwrap(),
            "hello world"
        );
    }

    #[test]
    fn rejects_path_traversal() {
        let temp = temp_dir();
        let dest = temp.join("out");
        let archive = create_test_tar_gz_with_raw_path(b"../outside.txt", b"evil");
        let result = extract_tar_gz_safe(&archive, &dest, None, None, None);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("path traversal"));
    }

    #[test]
    fn rejects_absolute_path() {
        let temp = temp_dir();
        let dest = temp.join("out");
        let absolute_path = ["/", "etc", "/", "passwd"].concat();
        let archive = create_test_tar_gz_with_raw_path(absolute_path.as_bytes(), b"evil");
        let result = extract_tar_gz_safe(&archive, &dest, None, None, None);
        assert!(result.is_err());
    }

    #[test]
    fn rejects_symlink_to_external() {
        let temp = temp_dir();
        let dest = temp.join("out");
        // Create a tar entry that is a symlink.
        let mut tar_buf = Vec::new();
        {
            let mut builder = tar::Builder::new(&mut tar_buf);
            let mut header = tar::Header::new_gnu();
            let absolute_path = ["/", "etc", "/", "passwd"].concat();
            header.set_path("link").unwrap();
            header.set_size(0);
            header.set_entry_type(EntryType::Symlink);
            header.set_link_name(absolute_path).unwrap();
            header.set_cksum();
            builder.append(&header, &[][..]).unwrap();
            builder.finish().unwrap();
        }
        let mut gz_buf = Vec::new();
        {
            let mut encoder =
                flate2::write::GzEncoder::new(&mut gz_buf, flate2::Compression::default());
            encoder.write_all(&tar_buf).unwrap();
            encoder.finish().unwrap();
        }
        let result = extract_tar_gz_safe(&gz_buf, &dest, None, None, None);
        assert!(result.is_err());
    }

    #[test]
    fn enforces_byte_limit() {
        let temp = temp_dir();
        let dest = temp.join("out");
        let archive = create_test_tar_gz(&[("big.txt", &[b'x'; 1024])]);
        let result = extract_tar_gz_safe(&archive, &dest, Some(100), None, None);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("limit exceeded"));
    }

    #[test]
    fn enforces_entry_limit() {
        let temp = temp_dir();
        let dest = temp.join("out");
        let entries: Vec<_> = (0..10)
            .map(|i| {
                (
                    format!("file_{i}.txt").leak() as &str,
                    &b"data"[..] as &[u8],
                )
            })
            .collect();
        let archive = create_test_tar_gz(&entries);
        let result = extract_tar_gz_safe(&archive, &dest, None, Some(5), None);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("entry count"));
    }

    #[test]
    fn enforces_depth_limit() {
        let temp = temp_dir();
        let dest = temp.join("out");
        let archive = create_test_tar_gz(&[("a/b/c/d/e/f/g/h/i/j/k/file.txt", b"deep")]);
        let result = extract_tar_gz_safe(&archive, &dest, None, None, Some(3));
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("depth"));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_preexisting_symlink_ancestor_below_destination() {
        use std::os::unix::fs::symlink;

        let temp = temp_dir();
        let dest = temp.join("out");
        let external = temp.join("external");
        fs::create_dir_all(&dest).unwrap();
        fs::create_dir_all(&external).unwrap();
        symlink(&external, dest.join("sub")).unwrap();
        let archive = create_test_tar_gz(&[("sub/escaped.txt", b"blocked")]);

        let result = extract_tar_gz_safe(&archive, &dest, None, None, None);

        assert!(result.is_err());
        assert!(!external.join("escaped.txt").exists());
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_ancestor_of_destination_root() {
        use std::os::unix::fs::symlink;

        let temp = temp_dir();
        let external = temp.join("external");
        fs::create_dir_all(&external).unwrap();
        let redirect = temp.join("redirect");
        symlink(&external, &redirect).unwrap();
        let archive = create_test_tar_gz(&[("escaped.txt", b"blocked")]);

        let result = extract_tar_gz_safe(&archive, &redirect.join("out"), None, None, None);

        assert!(result.is_err());
        assert!(!external.join("out").exists());
    }
}
