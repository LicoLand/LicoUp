use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

pub(crate) fn home_dir() -> PathBuf {
    home_dir_from_env(|name| env::var_os(name))
}

pub(crate) fn home_dir_from_env<F>(var: F) -> PathBuf
where
    F: Fn(&str) -> Option<OsString>,
{
    if let Some(path) = env_path_from(&var, "HOME") {
        return path;
    }
    if let Some(path) = env_path_from(&var, "USERPROFILE") {
        return path;
    }
    if let (Some(mut drive), Some(path)) = (var("HOMEDRIVE"), var("HOMEPATH")) {
        if !drive.is_empty() && !path.is_empty() {
            drive.push(path);
            return PathBuf::from(drive);
        }
    }
    directories::UserDirs::new()
        .map(|dirs| dirs.home_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."))
}

pub(crate) fn appdata_dir() -> PathBuf {
    env_path("APPDATA").unwrap_or_else(|| {
        if cfg!(windows) {
            home_dir().join("AppData").join("Roaming")
        } else {
            xdg_config_dir()
        }
    })
}

pub(crate) fn appdata_dir_from_home(home: &Path) -> PathBuf {
    if cfg!(windows) {
        home.join("AppData").join("Roaming")
    } else {
        xdg_config_dir_from_home(home)
    }
}

pub(crate) fn local_appdata_dir() -> PathBuf {
    env_path("LOCALAPPDATA").unwrap_or_else(|| {
        if cfg!(windows) {
            home_dir().join("AppData").join("Local")
        } else {
            xdg_data_dir()
        }
    })
}

pub(crate) fn local_appdata_dir_from_home(home: &Path) -> PathBuf {
    if cfg!(windows) {
        home.join("AppData").join("Local")
    } else {
        xdg_data_dir_from_home(home)
    }
}

pub(crate) fn xdg_config_dir() -> PathBuf {
    env_path("XDG_CONFIG_HOME").unwrap_or_else(|| home_dir().join(".config"))
}

pub(crate) fn xdg_config_dir_from_home(home: &Path) -> PathBuf {
    home.join(".config")
}

pub(crate) fn xdg_data_dir() -> PathBuf {
    env_path("XDG_DATA_HOME").unwrap_or_else(|| home_dir().join(".local/share"))
}

pub(crate) fn xdg_data_dir_from_home(home: &Path) -> PathBuf {
    home.join(".local/share")
}

pub(crate) fn expand_home(value: &str) -> PathBuf {
    expand_home_from(value, home_dir)
}

pub(crate) fn expand_home_from<F>(value: &str, home: F) -> PathBuf
where
    F: Fn() -> PathBuf,
{
    if value == "~" {
        return home();
    }
    if let Some(rest) = value.strip_prefix("~/") {
        return home().join(rest);
    }
    if let Some(rest) = value.strip_prefix("~\\") {
        return home().join(rest);
    }
    PathBuf::from(value)
}

fn env_path(name: &str) -> Option<PathBuf> {
    env_path_from(&|key| env::var_os(key), name)
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
mod tests {
    use super::*;

    #[test]
    fn resolves_cross_platform_home_fallbacks_and_tilde_paths() {
        let separator = char::from(92).to_string();
        let home_path = ["", "Profile", "Arc"].join(&separator);
        let home = home_dir_from_env(|name| match name {
            "HOMEDRIVE" => Some(OsString::from("C:")),
            "HOMEPATH" => Some(OsString::from(&home_path)),
            _ => None,
        });
        assert_eq!(home, PathBuf::from(["C:", "Profile", "Arc"].join(&separator)));
        assert_eq!(
            expand_home_from(
                &["~", ".codex", "sessions"].join(&separator),
                || home.clone()
            ),
            home.join([".codex", "sessions"].join(&separator))
        );
    }
}
