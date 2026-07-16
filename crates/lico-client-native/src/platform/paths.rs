use anyhow::{Result, anyhow};
use std::{
    cell::RefCell,
    env,
    path::{Path, PathBuf},
};

thread_local! {
    static PORTABLE_DATA_DIR_OVERRIDE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

#[doc(hidden)]
pub fn set_portable_data_dir_override(path: Option<PathBuf>) -> Option<PathBuf> {
    PORTABLE_DATA_DIR_OVERRIDE.with(|value| value.replace(path))
}

/// Resolve only the current LicoArc state root.
///
/// Retired environment variables, executable-adjacent roots, and old product
/// namespaces are deliberately never inspected or migrated.
pub fn portable_data_dir() -> Result<PathBuf> {
    if let Some(path) = portable_data_dir_override() {
        return prepare_current_root(path);
    }

    if let Some(path) = portable_data_dir_from_value(env::var("LICOARC_PORTABLE_DIR").ok())? {
        return prepare_current_root(path);
    }

    application_support_portable_data_dir()
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
    if trimmed.is_empty() {
        return Ok(None);
    }
    Ok(Some(PathBuf::from(trimmed)))
}

fn application_support_portable_data_dir() -> Result<PathBuf> {
    let base_dirs = directories::BaseDirs::new()
        .ok_or_else(|| anyhow!("cannot resolve LicoArc application data directory"))?;
    application_support_portable_data_dir_from_base(base_dirs.data_dir())
}

fn application_support_portable_data_dir_from_base(base: &Path) -> Result<PathBuf> {
    prepare_current_root(base.join("LicoArc").join("portable-data"))
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
        let parent = std::env::temp_dir().join(format!("licoarc-paths-{}", uuid::Uuid::new_v4()));
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
    fn current_namespace_is_licoarc_portable_data() {
        let parent = std::env::temp_dir().join(format!("licoarc-base-{}", uuid::Uuid::new_v4()));

        let resolved = application_support_portable_data_dir_from_base(&parent).unwrap();

        assert_eq!(resolved, parent.join("LicoArc").join("portable-data"));
        let _ = std::fs::remove_dir_all(parent);
    }

    #[test]
    fn blank_current_override_does_not_select_a_path() {
        assert_eq!(
            portable_data_dir_from_value(Some("   ".to_string())).unwrap(),
            None
        );
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
