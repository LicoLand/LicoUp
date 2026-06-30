use anyhow::{Result, anyhow};
use std::{
    cell::RefCell,
    env, fs,
    path::{Path, PathBuf},
};

thread_local! {
    static PORTABLE_DATA_DIR_OVERRIDE: RefCell<Option<PathBuf>> = RefCell::new(None);
}

#[doc(hidden)]
pub fn set_portable_data_dir_override(path: Option<PathBuf>) -> Option<PathBuf> {
    PORTABLE_DATA_DIR_OVERRIDE.with(|value| value.replace(path))
}

pub fn portable_data_dir() -> Result<PathBuf> {
    if let Some(path) = portable_data_dir_override() {
        fs::create_dir_all(&path)?;
        return Ok(path);
    }

    portable_data_dir_from_env(env::var("LICO_PORTABLE_DIR").ok())
}

fn portable_data_dir_override() -> Option<PathBuf> {
    PORTABLE_DATA_DIR_OVERRIDE.with(|value| value.borrow().clone())
}

fn portable_data_dir_from_env(portable_dir: Option<String>) -> Result<PathBuf> {
    portable_data_dir_with_executable(portable_dir, env::current_exe().ok())
}

fn portable_data_dir_with_executable(
    portable_dir: Option<String>,
    executable: Option<PathBuf>,
) -> Result<PathBuf> {
    if executable
        .as_deref()
        .is_some_and(is_bundled_macos_app_executable)
    {
        return application_support_portable_data_dir();
    }

    if let Some(value) = portable_dir {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            let path = PathBuf::from(trimmed);
            fs::create_dir_all(&path)?;
            return Ok(path);
        }
    }

    if let Some(executable) = executable {
        if let Some(parent) = executable.parent() {
            let candidate = parent.join("portable-data");
            if fs::create_dir_all(&candidate).is_ok() {
                return Ok(candidate);
            }
        }
    }

    application_support_portable_data_dir()
}

fn application_support_portable_data_dir() -> Result<PathBuf> {
    let project_dirs = directories::ProjectDirs::from("com", "lico", "client")
        .ok_or_else(|| anyhow!("cannot resolve application support directory"))?;
    let fallback = project_dirs.config_dir().join("portable-data");
    fs::create_dir_all(&fallback)?;
    Ok(fallback)
}

fn is_bundled_macos_app_executable(executable: &Path) -> bool {
    let Some(executable_dir) = executable.parent() else {
        return false;
    };
    let Some(contents_dir) = executable_dir.parent() else {
        return false;
    };
    let Some(app_dir) = contents_dir.parent() else {
        return false;
    };
    executable_dir.file_name().and_then(|value| value.to_str()) == Some("MacOS")
        && contents_dir.file_name().and_then(|value| value.to_str()) == Some("Contents")
        && app_dir.extension().and_then(|value| value.to_str()) == Some("app")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn portable_data_uses_portable_dir_env_when_set() {
        let dir = std::env::temp_dir().join("lico-portable-env-override");
        let resolved =
            portable_data_dir_from_env(Some(dir.to_string_lossy().into_owned())).unwrap();
        assert_eq!(resolved, dir);
        assert!(resolved.exists());
    }

    #[test]
    fn portable_data_falls_back_when_portable_dir_is_empty() {
        let resolved = portable_data_dir_from_env(Some("   ".to_string())).unwrap();
        assert_eq!(
            resolved.file_name().and_then(|value| value.to_str()),
            Some("portable-data")
        );
        assert!(resolved.exists());
    }

    #[test]
    fn portable_data_uses_application_support_for_packaged_macos_sidecar() {
        let env_dir = std::env::temp_dir().join("lico-portable-env-ignored-for-app");
        let executable = std::env::temp_dir()
            .join("LicoClient.app")
            .join("Contents")
            .join("MacOS")
            .join("lico-client");
        let resolved = portable_data_dir_with_executable(
            Some(env_dir.to_string_lossy().into_owned()),
            Some(executable),
        )
        .unwrap();
        assert_ne!(resolved, env_dir);
        assert_eq!(
            resolved.file_name().and_then(|value| value.to_str()),
            Some("portable-data")
        );
        assert!(resolved.exists());
    }

    #[test]
    fn portable_data_uses_override_when_set() {
        let dir = std::env::temp_dir().join("lico-portable-dir-override");
        let _guard = PortableDataDirOverrideGuard::set(dir.clone());
        let resolved = portable_data_dir().unwrap();
        assert_eq!(resolved, dir);
        assert!(resolved.exists());
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
