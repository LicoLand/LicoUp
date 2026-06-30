#[cfg(windows)]
use anyhow::anyhow;
use anyhow::{Context, Result};
use std::fs::{self, OpenOptions};
#[cfg(windows)]
use std::io::ErrorKind;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
#[cfg(windows)]
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

pub fn append_private_line(path: &Path, line: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    harden_private_path(path)?;
    writeln!(file, "{}", line)?;
    sync_all_if_supported(&mut file)?;
    Ok(())
}

pub fn atomic_write_private_text(path: &Path, content: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = sibling_temp_path(path);
    {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&tmp)?;
        harden_private_path(&tmp)?;
        file.write_all(content.as_bytes())?;
        sync_all_if_supported(&mut file)?;
    }
    rename_into_place(&tmp, path)?;
    harden_private_path(path)?;
    Ok(())
}

pub fn ensure_private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    harden_private_path(path)
}

pub fn harden_private_tree(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    if path.is_dir() {
        harden_private_path(path)?;
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            harden_private_tree(&entry.path())?;
        }
        return Ok(());
    }
    harden_private_path(path)
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
    match fs::rename(tmp, path) {
        Ok(()) => Ok(()),
        Err(error) => {
            if path.exists() {
                fs::remove_file(path)?;
                fs::rename(tmp, path)?;
                Ok(())
            } else {
                Err(error.into())
            }
        }
    }
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
}
