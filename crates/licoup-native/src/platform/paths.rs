use anyhow::{Result, anyhow};
use std::{
    cell::RefCell,
    env,
    ffi::OsString,
    path::{Path, PathBuf},
};

thread_local! {
    static PORTABLE_DATA_DIR_OVERRIDE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

#[doc(hidden)]
pub fn set_portable_data_dir_override(path: Option<PathBuf>) -> Option<PathBuf> {
    PORTABLE_DATA_DIR_OVERRIDE.with(|value| value.replace(path))
}

/// Resolve only the current LicoUp state root.
///
/// The default root is the `.lico-up` directory in the user's home, next to
/// other agent state namespaces like `.claude` and `.codex`. Retired
/// environment variables, executable-adjacent roots, and old product
/// namespaces are deliberately never inspected or migrated.
pub fn portable_data_dir() -> Result<PathBuf> {
    prepare_current_root(portable_data_dir_read_only()?)
}

/// Resolve the current LicoUp state root lexically without creating or
/// hardening it. Read-only observers use this before opening existing state.
pub(crate) fn portable_data_dir_read_only() -> Result<PathBuf> {
    if let Some(path) = portable_data_dir_override() {
        return Ok(path);
    }

    if let Some(path) = portable_data_dir_from_value(env::var("LICOUP_PORTABLE_DIR").ok())? {
        return Ok(path);
    }

    let home =
        user_home_from_env().ok_or_else(|| anyhow!("cannot resolve the LicoUp home directory"))?;
    Ok(home.join(".lico-up"))
}

fn portable_data_dir_override() -> Option<PathBuf> {
    PORTABLE_DATA_DIR_OVERRIDE.with(|value| value.borrow().clone())
}

#[doc(hidden)]
pub fn portable_data_dir_override_path() -> Option<PathBuf> {
    portable_data_dir_override()
}

fn portable_data_dir_from_value(value: Option<String>) -> Result<Option<PathBuf>> {
    let Some(value) = value else {
        return Ok(None);
    };
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.starts_with('$')
        || trimmed.contains("${")
        || trimmed.contains("${env:")
    {
        return Ok(None);
    }
    Ok(Some(PathBuf::from(trimmed)))
}

/// Home from `HOME` / `USERPROFILE` / `HOMEDRIVE`+`HOMEPATH` only.
///
/// Never call `directories::UserDirs` or `directories::BaseDirs` for `$HOME`.
/// Those constructors also assemble Desktop, Documents, Downloads, Pictures,
/// Music, and Movies by joining `$HOME`; that is path construction, not a TCC
/// trigger. Keep this owner anyway so home resolution stays lexical, firmlink-
/// normalized, and independent of that crate.
pub(crate) fn user_home_from_env() -> Option<PathBuf> {
    env_home_from(|name| env::var_os(name))
}

/// Drop the macOS data-volume firmlink prefix so a home-relative path and the
/// same path under that prefix classify as the same location.
/// Lexical only; does not stat.
fn macos_data_volume_prefix() -> PathBuf {
    Path::new("/").join("System").join("Volumes").join("Data")
}

#[cfg(test)]
pub(crate) fn posix_absolute(parts: &[&str]) -> PathBuf {
    PathBuf::from(format!("/{}", parts.join("/")))
}

pub(crate) fn strip_macos_data_volume(path: &Path) -> PathBuf {
    match path.strip_prefix(macos_data_volume_prefix()) {
        Ok(rest) if rest.as_os_str().is_empty() => PathBuf::from("/"),
        Ok(rest) => Path::new("/").join(rest),
        Err(_) => path.to_path_buf(),
    }
}

pub(crate) fn env_home_from<F>(var: F) -> Option<PathBuf>
where
    F: Fn(&str) -> Option<OsString>,
{
    if let Some(path) = env_path_from(&var, "HOME") {
        return Some(path);
    }
    if let Some(path) = env_path_from(&var, "USERPROFILE") {
        return Some(path);
    }
    let drive = var("HOMEDRIVE").filter(|value| !value.is_empty())?;
    let path = var("HOMEPATH").filter(|value| !value.is_empty())?;
    let mut combined = drive;
    combined.push(path);
    Some(PathBuf::from(combined))
}

fn env_path_from<F>(var: &F, name: &str) -> Option<PathBuf>
where
    F: Fn(&str) -> Option<OsString>,
{
    var(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

#[cfg(test)]
fn home_portable_data_dir_from_home(home: &Path) -> Result<PathBuf> {
    prepare_current_root(home.join(".lico-up"))
}

fn prepare_current_root(path: PathBuf) -> Result<PathBuf> {
    crate::platform::file_security::ensure_private_dir(&path)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_override_is_private_and_uses_only_requested_root() {
        let parent = std::env::temp_dir().join(format!("licoup-paths-{}", uuid::Uuid::new_v4()));
        let current = parent.join("current");
        let retired = parent.join("retired");
        std::fs::create_dir_all(&retired).unwrap();
        let sentinel = retired.join("must-not-be-read-or-modified");
        std::fs::write(&sentinel, b"retired").unwrap();
        let _guard = PortableDataDirOverrideGuard::set(current.clone());

        let resolved = portable_data_dir().unwrap();

        assert_eq!(resolved, current);
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"retired");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                resolved.metadata().unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
        let _ = std::fs::remove_dir_all(parent);
    }

    #[test]
    fn current_namespace_is_home_dot_lico_up() {
        let parent = std::env::temp_dir().join(format!("licoup-base-{}", uuid::Uuid::new_v4()));

        let resolved = home_portable_data_dir_from_home(&parent).unwrap();

        assert_eq!(resolved, parent.join(".lico-up"));
        let _ = std::fs::remove_dir_all(parent);
    }

    #[test]
    fn blank_current_override_does_not_select_a_path() {
        assert_eq!(
            portable_data_dir_from_value(Some("   ".to_string())).unwrap(),
            None
        );
    }

    #[test]
    fn unexpanded_interpolation_does_not_select_a_path() {
        for value in [
            "${LICOUP_PORTABLE_DIR}",
            "$LICOUP_PORTABLE_DIR",
            "${env:LICOUP_PORTABLE_DIR}",
        ] {
            assert_eq!(
                portable_data_dir_from_value(Some(value.to_string())).unwrap(),
                None
            );
        }
    }

    #[test]
    fn macos_firmlink_prefix_does_not_change_home_relative_classification() {
        fn posix(parts: &[&str]) -> PathBuf {
            PathBuf::from(format!("/{}", parts.join("/")))
        }
        assert_eq!(
            strip_macos_data_volume(&posix(&[
                "System", "Volumes", "Data", "profile", "fixture", "Desktop"
            ])),
            posix(&["profile", "fixture", "Desktop"])
        );
        assert_eq!(
            strip_macos_data_volume(&posix(&["Users", "fixture", "Documents"])),
            posix(&["Users", "fixture", "Documents"])
        );
        assert_eq!(
            strip_macos_data_volume(&posix(&["System", "Volumes", "Data"])),
            PathBuf::from("/")
        );
    }

    #[test]
    fn home_comes_from_environment_variables_not_user_dirs() {
        let separator = char::from(92).to_string();
        let home_path = ["", "Profile", "Arc"].join(&separator);
        let home = env_home_from(|name| match name {
            "HOMEDRIVE" => Some(OsString::from("C:")),
            "HOMEPATH" => Some(OsString::from(&home_path)),
            _ => None,
        });
        assert_eq!(
            home,
            Some(PathBuf::from(["C:", "Profile", "Arc"].join(&separator)))
        );
        assert_eq!(env_home_from(|_| None), None);
    }

    struct PortableDataDirOverrideGuard {
        previous: Option<PathBuf>,
    }

    impl PortableDataDirOverrideGuard {
        fn set(path: PathBuf) -> Self {
            let previous = set_portable_data_dir_override(Some(path));
            Self { previous }
        }
    }

    impl Drop for PortableDataDirOverrideGuard {
        fn drop(&mut self) {
            set_portable_data_dir_override(self.previous.take());
        }
    }
}
