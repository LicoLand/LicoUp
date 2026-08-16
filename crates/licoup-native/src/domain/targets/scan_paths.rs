//! Allowlisted Agent discovery paths. The TOML manifest is the only automatic
//! search space; PATH, personal library roots, and network volumes are never
//! walked.

use crate::platform::paths::{portable_data_dir, strip_macos_data_volume, user_home_from_env};
use serde::Deserialize;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;

const MANIFEST: &str = include_str!("../../../resources/agent-scan-paths.toml");
pub const SCHEMA_VERSION: &str = "licoup.agent-scan-paths.v1";

#[derive(Clone, Debug, Default)]
pub struct HostRoots {
    pub home: Option<PathBuf>,
    pub appdata: Option<PathBuf>,
    pub local_appdata: Option<PathBuf>,
    pub xdg_config: Option<PathBuf>,
    pub xdg_data: Option<PathBuf>,
    pub program_data: Option<PathBuf>,
    pub program_files: Option<PathBuf>,
    pub program_files_x86: Option<PathBuf>,
    pub portable: Option<PathBuf>,
}

impl HostRoots {
    pub fn from_environment() -> Self {
        let home = user_home_from_env();
        Self {
            appdata: env_path("APPDATA").or_else(|| {
                home.as_ref().map(|home| {
                    if cfg!(windows) {
                        home.join("AppData").join("Roaming")
                    } else {
                        home.join(".config")
                    }
                })
            }),
            local_appdata: env_path("LOCALAPPDATA").or_else(|| {
                home.as_ref().map(|home| {
                    if cfg!(windows) {
                        home.join("AppData").join("Local")
                    } else {
                        home.join(".local").join("share")
                    }
                })
            }),
            xdg_config: env_path("XDG_CONFIG_HOME")
                .or_else(|| home.as_ref().map(|home| home.join(".config"))),
            xdg_data: env_path("XDG_DATA_HOME")
                .or_else(|| home.as_ref().map(|home| home.join(".local").join("share"))),
            program_data: env_path("ProgramData"),
            program_files: env_path("ProgramFiles"),
            program_files_x86: env_path("ProgramFiles(x86)"),
            portable: portable_data_dir().ok(),
            home,
        }
    }

    pub fn from_home(home: &Path) -> Self {
        Self {
            home: Some(home.to_path_buf()),
            appdata: Some(if cfg!(windows) {
                home.join("AppData").join("Roaming")
            } else {
                home.join(".config")
            }),
            local_appdata: Some(if cfg!(windows) {
                home.join("AppData").join("Local")
            } else {
                home.join(".local").join("share")
            }),
            xdg_config: Some(home.join(".config")),
            xdg_data: Some(home.join(".local").join("share")),
            program_data: None,
            program_files: None,
            program_files_x86: None,
            portable: portable_data_dir().ok(),
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
struct Manifest {
    schema_version: String,
    deny: DenySpec,
    #[serde(default)]
    binaries: Vec<BinaryGroup>,
    #[serde(default)]
    agents: Vec<AgentPaths>,
}

#[derive(Clone, Debug, Deserialize)]
struct DenySpec {
    #[serde(default)]
    network_prefixes: Vec<String>,
    #[serde(default)]
    home_roots: Vec<String>,
    #[serde(default)]
    media_library_extensions: Vec<String>,
    #[serde(default)]
    other_app_home_prefixes: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct BinaryGroup {
    #[serde(default)]
    oses: Vec<String>,
    #[serde(default)]
    dirs: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct AgentPaths {
    id: String,
    #[serde(default)]
    binaries: Vec<String>,
    #[serde(default)]
    apps: Vec<String>,
    #[serde(default)]
    extension_roots: Vec<String>,
    #[serde(default)]
    config: Vec<OsPath>,
    #[serde(default)]
    detection: Vec<OsPath>,
    #[serde(default)]
    history: Vec<HistoryPath>,
}

#[derive(Clone, Debug, Deserialize)]
struct OsPath {
    path: String,
    #[serde(default)]
    oses: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct HistoryPath {
    path: String,
    #[serde(default)]
    kind: String,
}

#[derive(Clone, Debug)]
pub struct HistoryScanRoot {
    pub path: PathBuf,
    pub kind: String,
}

fn manifest() -> &'static Manifest {
    static PARSED: OnceLock<Manifest> = OnceLock::new();
    PARSED.get_or_init(|| {
        let parsed: Manifest = toml::from_str(MANIFEST).expect("agent-scan-paths.toml");
        assert_eq!(parsed.schema_version, SCHEMA_VERSION);
        parsed
    })
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn os_matches(oses: &[String], os: &str) -> bool {
    oses.is_empty() || oses.iter().any(|value| value == os)
}

fn expand_template(template: &str, roots: &HostRoots) -> Option<PathBuf> {
    let mut remaining = template;
    let mut path = PathBuf::new();
    if let Some(token) = remaining.strip_prefix('{') {
        let (name, rest) = token.split_once('}')?;
        let base = match name {
            "home" => roots.home.as_ref()?,
            "appdata" => roots.appdata.as_ref()?,
            "local_appdata" => roots.local_appdata.as_ref()?,
            "xdg_config" => roots.xdg_config.as_ref()?,
            "xdg_data" => roots.xdg_data.as_ref()?,
            "program_data" => roots.program_data.as_ref()?,
            "program_files" => roots.program_files.as_ref()?,
            "program_files_x86" => roots.program_files_x86.as_ref()?,
            "portable" => roots.portable.as_ref()?,
            _ => return None,
        };
        path.push(base);
        remaining = rest.trim_start_matches(['/', '\\']);
    }
    if !remaining.is_empty() {
        path.push(remaining);
    }
    Some(path)
}

fn expand_all(templates: &[String], roots: &HostRoots) -> Vec<PathBuf> {
    templates
        .iter()
        .filter_map(|template| expand_template(template, roots))
        .collect()
}

fn nvm_default_bin_dirs(home: &Path) -> Vec<PathBuf> {
    nvm_default_version(home)
        .map(|version| {
            home.join(".nvm")
                .join("versions")
                .join("node")
                .join(version)
                .join("bin")
        })
        .into_iter()
        .collect()
}

fn nvm_default_version(home: &Path) -> Option<String> {
    let nvm = home.join(".nvm");
    let mut seen = BTreeSet::new();
    let mut current = String::from("default");
    for _ in 0..8 {
        if !seen.insert(current.clone()) {
            return None;
        }
        if let Some(version) = nvm_node_version_dir_name(&current) {
            return Some(version);
        }
        if current.contains("..") || Path::new(&current).is_absolute() {
            return None;
        }
        let alias = nvm.join("alias").join(&current);
        if denied(&alias, Some(home)) {
            return None;
        }
        let text = fs::read_to_string(alias).ok()?;
        current = text.trim().to_string();
        if current.is_empty() || current.len() > 64 {
            return None;
        }
    }
    None
}

fn nvm_node_version_dir_name(value: &str) -> Option<String> {
    let trimmed = value.trim().trim_start_matches('v');
    let mut parts = trimmed.split('.');
    let major = parts.next()?;
    let minor = parts.next()?;
    if major.is_empty()
        || !major.chars().all(|item| item.is_ascii_digit())
        || minor.is_empty()
        || !minor.chars().next()?.is_ascii_digit()
    {
        return None;
    }
    Some(format!("v{trimmed}"))
}

fn agent<'a>(id: &str) -> Option<&'a AgentPaths> {
    manifest().agents.iter().find(|agent| agent.id == id)
}

pub fn binary_dirs(os: &str, roots: &HostRoots) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for group in &manifest().binaries {
        if !os_matches(&group.oses, os) {
            continue;
        }
        dirs.extend(expand_all(&group.dirs, roots));
    }
    for agent in &manifest().agents {
        dirs.extend(expand_all(&agent.binaries, roots));
    }
    if let Some(home) = roots.home.as_deref() {
        dirs.extend(nvm_default_bin_dirs(home));
    }
    dedupe(dirs)
        .into_iter()
        .filter(|path| !denied(path, roots.home.as_deref()))
        .collect()
}

pub fn config_path(agent_id: &str, os: &str, roots: &HostRoots) -> Option<PathBuf> {
    agent(agent_id).and_then(|agent| {
        agent.config.iter().find_map(|entry| {
            os_matches(&entry.oses, os)
                .then(|| expand_template(&entry.path, roots))
                .flatten()
        })
    })
}

pub fn detection_paths(agent_id: &str, os: &str, roots: &HostRoots) -> Vec<PathBuf> {
    let Some(agent) = agent(agent_id) else {
        return Vec::new();
    };
    agent
        .detection
        .iter()
        .filter(|entry| os_matches(&entry.oses, os))
        .filter_map(|entry| expand_template(&entry.path, roots))
        .collect()
}

pub fn history_roots(agent_id: &str, roots: &HostRoots) -> Vec<HistoryScanRoot> {
    let Some(agent) = agent(agent_id) else {
        return Vec::new();
    };
    agent
        .history
        .iter()
        .filter_map(|entry| {
            Some(HistoryScanRoot {
                path: expand_template(&entry.path, roots)?,
                kind: entry.kind.clone(),
            })
        })
        .collect()
}

pub fn extension_roots(agent_id: &str, roots: &HostRoots) -> Vec<PathBuf> {
    agent(agent_id)
        .map(|agent| expand_all(&agent.extension_roots, roots))
        .unwrap_or_default()
}

pub fn app_executables(agent_id: &str, roots: &HostRoots) -> Vec<PathBuf> {
    agent(agent_id)
        .map(|agent| expand_all(&agent.apps, roots))
        .unwrap_or_default()
}

pub fn allow_prefixes(os: &str, roots: &HostRoots) -> Vec<PathBuf> {
    let mut prefixes = Vec::new();
    for group in &manifest().binaries {
        if os_matches(&group.oses, os) {
            prefixes.extend(expand_all(&group.dirs, roots));
        }
    }
    for agent in &manifest().agents {
        prefixes.extend(expand_all(&agent.binaries, roots));
        prefixes.extend(expand_all(&agent.apps, roots));
        prefixes.extend(expand_all(&agent.extension_roots, roots));
        for entry in agent
            .config
            .iter()
            .chain(agent.detection.iter())
            .filter(|entry| os_matches(&entry.oses, os))
        {
            if let Some(path) = expand_template(&entry.path, roots) {
                prefixes.push(path);
            }
        }
        for entry in &agent.history {
            if let Some(path) = expand_template(&entry.path, roots) {
                prefixes.push(path);
            }
        }
    }
    if let Some(home) = roots.home.as_deref() {
        prefixes.extend(nvm_default_bin_dirs(home));
    }
    dedupe(prefixes)
        .into_iter()
        .filter(|path| !denied(path, roots.home.as_deref()))
        .collect()
}

pub fn admitted_scan_path(path: &Path) -> bool {
    admitted_scan_path_with(path, &HostRoots::from_environment())
}

pub fn admitted_scan_path_with(path: &Path, roots: &HostRoots) -> bool {
    let normalized = lexical(path);
    if denied(&normalized, roots.home.as_deref()) {
        return false;
    }
    let os = std::env::consts::OS;
    allow_prefixes(os, roots).iter().any(|prefix| {
        let prefix = lexical(prefix);
        normalized == prefix || normalized.starts_with(&prefix)
    })
}

pub fn probe_exists(path: &Path) -> bool {
    automatic_probe_admitted(path) && path.exists()
}

pub fn probe_is_file(path: &Path) -> bool {
    automatic_probe_admitted(path) && path.is_file()
}

pub fn probe_is_dir(path: &Path) -> bool {
    automatic_probe_admitted(path) && path.is_dir()
}

fn automatic_probe_admitted(path: &Path) -> bool {
    admitted_scan_path(path)
        && !is_other_app_container(path)
        && !symlink_escapes_denied_location(path)
}

/// `read_link` is lexical. Following the symlink with `exists` would stat the
/// target, including a personal library root. Skip those before the probe.
pub(crate) fn symlink_escapes_denied_location(path: &Path) -> bool {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return false;
    };
    if !metadata.file_type().is_symlink() {
        return false;
    }
    let Ok(target) = fs::read_link(path) else {
        return true;
    };
    let resolved = if target.is_absolute() {
        lexical(&target)
    } else {
        lexical(
            &path
                .parent()
                .map(|parent| parent.join(&target))
                .unwrap_or(target),
        )
    };
    let home = crate::platform::paths::user_home_from_env();
    denied(&resolved, home.as_deref()) || is_other_app_container(&resolved)
}

/// Other-app containers listed in the manifest. Lexical; does not stat.
/// Automatic unused-agent probes skip these. Selecting that Agent may still
/// read its store.
pub fn is_other_app_container(path: &Path) -> bool {
    is_other_app_container_with(path, &HostRoots::from_environment())
}

fn is_other_app_container_with(path: &Path, roots: &HostRoots) -> bool {
    let Some(home) = roots
        .home
        .as_deref()
        .map(|home| strip_macos_data_volume(&lexical(home)))
    else {
        return false;
    };
    let normalized = strip_macos_data_volume(&lexical(path));
    manifest()
        .deny
        .other_app_home_prefixes
        .iter()
        .any(|relative| {
            let root = home.join(relative);
            normalized == root || normalized.starts_with(&root)
        })
}

pub fn denied(path: &Path, home: Option<&Path>) -> bool {
    let normalized = strip_macos_data_volume(&lexical(path));
    let deny = &manifest().deny;
    if deny.network_prefixes.iter().any(|prefix| {
        let prefix = Path::new(prefix);
        normalized == prefix || normalized.starts_with(prefix)
    }) {
        return true;
    }
    if is_media_library(&normalized, &deny.media_library_extensions) {
        return true;
    }
    let Some(home) = home.map(|home| strip_macos_data_volume(&lexical(home))) else {
        return false;
    };
    if home.starts_with(&normalized) {
        return true;
    }
    deny.home_roots.iter().any(|name| {
        let root = home.join(name);
        normalized == root || normalized.starts_with(&root)
    })
}

fn is_media_library(path: &Path, extensions: &[String]) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .is_some_and(|extension| extensions.iter().any(|item| item == &extension))
}

fn lexical(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    if normalized.as_os_str().is_empty() {
        path.to_path_buf()
    } else {
        normalized
    }
}

fn dedupe(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = BTreeSet::<String>::new();
    let mut out = Vec::new();
    for path in paths {
        let key = path.to_string_lossy().to_ascii_lowercase();
        if seen.insert(key) {
            out.push(path);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_roots() -> HostRoots {
        let home = PathBuf::from("/profile");
        HostRoots {
            home: Some(home.clone()),
            appdata: Some(PathBuf::from("/app-data")),
            local_appdata: Some(PathBuf::from("/local-app-data")),
            xdg_config: Some(home.join(".config")),
            xdg_data: Some(home.join(".local/share")),
            program_data: Some(PathBuf::from("/program-data")),
            program_files: Some(PathBuf::from("/program-files")),
            program_files_x86: None,
            portable: Some(PathBuf::from("/portable")),
        }
    }

    #[test]
    fn manifest_parses_with_the_published_schema() {
        assert_eq!(manifest().schema_version, SCHEMA_VERSION);
        assert!(!manifest().agents.is_empty());
        assert!(!manifest().binaries.is_empty());
    }

    #[test]
    fn personal_and_network_locations_are_denied_without_stating() {
        let home = PathBuf::from("/profile");
        for denied_path in [
            PathBuf::from("/profile/Downloads/bin"),
            PathBuf::from("/profile/Desktop/tools"),
            PathBuf::from("/profile/Documents/scripts"),
            PathBuf::from("/profile/Pictures"),
            PathBuf::from("/profile/Music/library"),
            PathBuf::from("/profile/Pictures/Personal.photoslibrary"),
            PathBuf::from("/Volumes/team-share/bin"),
            PathBuf::from("/System/Volumes/Data/profile/Desktop/tools"),
            PathBuf::from("/System/Volumes/Data/profile/Pictures"),
            PathBuf::from("/System/Volumes/Data/profile/Music/library"),
        ] {
            assert!(denied(&denied_path, Some(&home)));
        }
        assert!(denied(
            &PathBuf::from("/profile/Desktop/tools"),
            Some(&PathBuf::from("/System/Volumes/Data/profile")),
        ));
    }

    #[test]
    fn agent_store_locations_are_admitted() {
        let roots = fixture_roots();
        let cursor = PathBuf::from("/profile/.cursor/chats");
        let homebrew = PathBuf::from("/opt/homebrew/bin");
        assert!(!denied(&cursor, roots.home.as_deref()));
        assert!(!denied(&homebrew, roots.home.as_deref()));
        assert!(admitted_scan_path_with(&cursor, &roots));
        assert!(!probe_is_dir(Path::new("/Volumes/team-share")));
        assert!(
            binary_dirs("macos", &roots).contains(&PathBuf::from("/opt/homebrew/bin"))
                || binary_dirs("linux", &roots).contains(&PathBuf::from("/usr/bin"))
        );
        assert!(denied(
            &PathBuf::from("/profile/.local/bin/../../Desktop/tool"),
            roots.home.as_deref()
        ));
        assert!(!admitted_scan_path_with(
            &PathBuf::from("/opt/homebrew/bin/../Desktop/tool"),
            &roots
        ));
    }

    #[test]
    fn history_roots_come_from_the_manifest() {
        let roots = HostRoots::from_home(&PathBuf::from("synthetic-home"));
        let cursor = history_roots("cursor", &roots);
        assert!(cursor.iter().any(|root| {
            root.kind == "cursor-cli-chats"
                && root.path == PathBuf::from("synthetic-home/.cursor/chats")
        }));
        let xdg = history_roots("cursor", &roots);
        assert!(xdg.iter().any(|root| {
            root.path == PathBuf::from("synthetic-home/.config/Cursor/User/workspaceStorage")
        }));
    }

    #[test]
    fn windows_package_manager_dirs_are_listed() {
        let roots = fixture_roots();
        let dirs = binary_dirs("windows", &roots);
        assert!(dirs.contains(&PathBuf::from("/local-app-data/Microsoft/WindowsApps")));
        assert!(dirs.contains(&PathBuf::from("/profile/scoop/shims")));
        assert!(dirs.contains(&PathBuf::from("/program-data/chocolatey/bin")));
    }

    #[test]
    fn nvm_default_alias_adds_that_node_bin_dir() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let home = std::env::temp_dir().join(format!(
            "lico-scan-nvm-{}-{}",
            stamp.as_secs(),
            stamp.subsec_nanos()
        ));
        fs::create_dir_all(home.join(".nvm/alias/lts")).unwrap();
        fs::write(home.join(".nvm/alias/default"), "lts/krypton\n").unwrap();
        fs::write(home.join(".nvm/alias/lts/krypton"), "22.14.0\n").unwrap();
        let roots = HostRoots::from_home(&home);
        let expected = home.join(".nvm/versions/node/v22.14.0/bin");
        assert!(binary_dirs("macos", &roots).contains(&expected));
        assert!(allow_prefixes("macos", &roots).contains(&expected));
        fs::write(home.join(".nvm/alias/default"), "../Desktop\n").unwrap();
        let roots = HostRoots::from_home(&home);
        assert!(
            !binary_dirs("macos", &roots)
                .iter()
                .any(|path| path.ends_with("Desktop") || path.ends_with("Desktop/bin"))
        );
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn unused_agent_probes_skip_other_app_containers_without_denying_them() {
        let roots = fixture_roots();
        let cursor_support = PathBuf::from("/profile/Library/Application Support/Cursor");
        let kimi_logs = PathBuf::from("/profile/Library/Logs/Kimi");
        let pnpm = PathBuf::from("/profile/Library/pnpm");
        let claude = PathBuf::from("/profile/.claude");
        assert!(admitted_scan_path_with(&cursor_support, &roots));
        assert!(is_other_app_container_with(&cursor_support, &roots));
        assert!(is_other_app_container_with(&kimi_logs, &roots));
        assert!(!is_other_app_container_with(&pnpm, &roots));
        assert!(!is_other_app_container_with(&claude, &roots));
        assert!(!denied(&cursor_support, roots.home.as_deref()));
        assert!(is_other_app_container_with(
            &PathBuf::from("/profile/Library/Mobile Documents/com~apple~CloudDocs"),
            &roots
        ));
        assert!(is_other_app_container_with(
            &PathBuf::from("/profile/Library/CloudStorage/iCloudDrive"),
            &roots
        ));
    }
}
