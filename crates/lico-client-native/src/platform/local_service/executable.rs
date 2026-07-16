use serde_json::Value;
use std::path::Path;

use super::params;

pub(in crate::platform) fn resolve(
    params: &Value,
    environment_keys: &[&str],
    default_executable: &str,
) -> String {
    if let Some(value) = params::text(params, &["executable", "binary", "binaryPath"]) {
        return value;
    }
    environment_keys
        .iter()
        .find_map(|key| {
            std::env::var(key)
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        })
        .unwrap_or_else(|| default_executable.to_string())
}

pub(in crate::platform) fn available(executable: &str) -> bool {
    let path = Path::new(executable);
    if path.is_absolute() || executable.contains('/') || executable.contains('\\') {
        return path.is_file();
    }
    which(executable)
}

pub(in crate::platform) fn which(name: &str) -> bool {
    let Ok(path_var) = std::env::var("PATH") else {
        return false;
    };
    std::env::split_paths(&path_var).any(|entry| {
        if entry.join(name).is_file() {
            return true;
        }
        #[cfg(windows)]
        if entry.join(format!("{}.exe", name)).is_file() {
            return true;
        }
        false
    })
}
