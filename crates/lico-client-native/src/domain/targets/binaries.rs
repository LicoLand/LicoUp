use super::catalog::TargetDef;
use super::parameters::param_string;
use crate::platform::runtime_adapters;
use directories::UserDirs;
use serde_json::Value;
use std::collections::BTreeSet;
use std::env;
use std::path::{Path, PathBuf};

pub(super) const BINARY_SOURCE_APPLICATION_STORE: &str = "application-store";
pub(super) const BINARY_SOURCE_PACKAGE_MANAGER: &str = "package-manager";
pub(super) const BINARY_SOURCE_EXECUTABLE_PATH: &str = "executable-path";

pub(super) fn find_binary(names: &[&str]) -> Option<PathBuf> {
    let dirs = binary_search_dirs();
    find_binary_in_dirs(names, &dirs)
}

pub(super) fn find_target_binary(def: &TargetDef, params: &Value) -> Option<PathBuf> {
    if def.id != "cursor" {
        return find_binary(def.binary_names);
    }
    let dirs = binary_search_dirs();
    for name in def.binary_names {
        if let Some(candidate) = find_binary_in_dirs(&[*name], &dirs)
            && cursor_binary_supports_acp(&candidate, params)
        {
            return Some(candidate);
        }
    }
    None
}

pub(super) fn find_target_binary_with_source(
    def: &TargetDef,
    params: &Value,
) -> Option<(PathBuf, &'static str)> {
    find_target_binary(def, params).map(|path| {
        let source = classify_binary_source(&path);
        (path, source)
    })
}

pub(super) fn cursor_binary_supports_acp(binary: &Path, params: &Value) -> bool {
    let cwd = param_string(params, "workingDirectory")
        .or_else(|| param_string(params, "cwd"))
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| env::current_dir().ok());
    let Some(cwd) = cwd else {
        return false;
    };
    runtime_adapters::probe_runtime_driver("cursor", binary, &cwd)
        .get("supported")
        .and_then(Value::as_bool)
        == Some(true)
}

pub(super) fn find_binary_in_dirs(names: &[&str], dirs: &[PathBuf]) -> Option<PathBuf> {
    for dir in dirs {
        for name in names {
            for candidate in binary_candidate_paths(dir, name) {
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
    }
    None
}

fn binary_search_dirs() -> Vec<PathBuf> {
    let mut dirs = env::var_os("PATH")
        .map(|path_var| env::split_paths(&path_var).collect::<Vec<_>>())
        .unwrap_or_default();
    dirs.extend(common_platform_binary_dirs());
    dedupe_paths(dirs)
}

fn binary_candidate_paths(dir: &Path, name: &str) -> Vec<PathBuf> {
    #[cfg(not(target_os = "windows"))]
    let candidates = vec![dir.join(name)];

    #[cfg(target_os = "windows")]
    let mut candidates = vec![dir.join(name)];
    #[cfg(target_os = "windows")]
    {
        if Path::new(name).extension().is_none() {
            for extension in windows_binary_extensions() {
                candidates.push(dir.join(format!("{}{}", name, extension)));
            }
        }
    }
    dedupe_paths(candidates)
}

#[cfg(target_os = "windows")]
fn windows_binary_extensions() -> Vec<String> {
    let mut extensions = env::var("PATHEXT")
        .unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string())
        .split(';')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            if value.starts_with('.') {
                value.to_string()
            } else {
                format!(".{}", value)
            }
        })
        .collect::<Vec<_>>();
    for extension in [".exe", ".cmd", ".bat", ".com"] {
        if !extensions
            .iter()
            .any(|value| value.eq_ignore_ascii_case(extension))
        {
            extensions.push(extension.to_string());
        }
    }
    extensions
}

#[derive(Default)]
struct PlatformBinaryRoots {
    home: Option<PathBuf>,
    app_data: Option<PathBuf>,
    local_app_data: Option<PathBuf>,
    program_data: Option<PathBuf>,
    program_files: Option<PathBuf>,
    program_files_x86: Option<PathBuf>,
}

impl PlatformBinaryRoots {
    fn from_environment() -> Self {
        Self {
            home: UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf()),
            app_data: non_empty_env_path("APPDATA"),
            local_app_data: non_empty_env_path("LOCALAPPDATA"),
            program_data: non_empty_env_path("ProgramData"),
            program_files: non_empty_env_path("ProgramFiles"),
            program_files_x86: non_empty_env_path("ProgramFiles(x86)"),
        }
    }
}

fn non_empty_env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn common_platform_binary_dirs() -> Vec<PathBuf> {
    common_binary_dirs_for_platform(
        std::env::consts::OS,
        &PlatformBinaryRoots::from_environment(),
    )
}

fn common_binary_dirs_for_platform(platform: &str, roots: &PlatformBinaryRoots) -> Vec<PathBuf> {
    match platform {
        "windows" => windows_binary_dirs(roots),
        "macos" => macos_binary_dirs(roots),
        "linux" => linux_binary_dirs(roots),
        _ => Vec::new(),
    }
}

fn windows_binary_dirs(roots: &PlatformBinaryRoots) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(app_data) = &roots.app_data {
        dirs.push(app_data.join("npm"));
    }
    if let Some(local) = &roots.local_app_data {
        dirs.push(local.join("Microsoft").join("WindowsApps"));
        dirs.push(local.join("Microsoft").join("WinGet").join("Links"));
        dirs.push(local.join("pnpm"));
        dirs.push(local.join("Programs").join("Microsoft VS Code").join("bin"));
        dirs.push(
            local
                .join("Programs")
                .join("Microsoft VS Code Insiders")
                .join("bin"),
        );
        dirs.push(
            local
                .join("Programs")
                .join("Cursor")
                .join("resources")
                .join("app")
                .join("bin"),
        );
    }
    if let Some(program_data) = &roots.program_data {
        dirs.push(program_data.join("chocolatey").join("bin"));
    }
    if let Some(home) = &roots.home {
        dirs.push(home.join("scoop").join("shims"));
        append_user_package_bins(&mut dirs, home);
    }
    for root in [&roots.program_files, &roots.program_files_x86]
        .into_iter()
        .flatten()
    {
        dirs.push(root.join("Microsoft VS Code").join("bin"));
        dirs.push(root.join("Microsoft VS Code Insiders").join("bin"));
        dirs.push(
            root.join("Cursor")
                .join("resources")
                .join("app")
                .join("bin"),
        );
    }
    dirs
}

fn macos_binary_dirs(roots: &PlatformBinaryRoots) -> Vec<PathBuf> {
    let mut dirs = vec![
        posix_path(&["opt", "homebrew", "bin"]),
        posix_path(&["usr", "local", "bin"]),
        posix_path(&["usr", "bin"]),
        posix_path(&[
            "Applications",
            "Visual Studio Code.app",
            "Contents",
            "Resources",
            "app",
            "bin",
        ]),
        posix_path(&[
            "Applications",
            "Visual Studio Code - Insiders.app",
            "Contents",
            "Resources",
            "app",
            "bin",
        ]),
        posix_path(&[
            "Applications",
            "Cursor.app",
            "Contents",
            "Resources",
            "app",
            "bin",
        ]),
    ];
    if let Some(home) = &roots.home {
        append_user_package_bins(&mut dirs, home);
        dirs.push(home.join("Library").join("pnpm"));
        dirs.push(
            home.join("Applications")
                .join("Visual Studio Code.app")
                .join("Contents")
                .join("Resources")
                .join("app")
                .join("bin"),
        );
        dirs.push(
            home.join("Applications")
                .join("Cursor.app")
                .join("Contents")
                .join("Resources")
                .join("app")
                .join("bin"),
        );
    }
    dirs
}

fn linux_binary_dirs(roots: &PlatformBinaryRoots) -> Vec<PathBuf> {
    let mut dirs = vec![
        posix_path(&["usr", "local", "bin"]),
        posix_path(&["usr", "bin"]),
        posix_path(&["snap", "bin"]),
        posix_path(&["var", "lib", "flatpak", "exports", "bin"]),
    ];
    if let Some(home) = &roots.home {
        append_user_package_bins(&mut dirs, home);
        dirs.push(
            home.join(".local")
                .join("share")
                .join("flatpak")
                .join("exports")
                .join("bin"),
        );
        dirs.push(home.join(".local").join("share").join("pnpm"));
    }
    dirs
}

fn posix_path(components: &[&str]) -> PathBuf {
    components
        .iter()
        .fold(PathBuf::from("/"), |path, component| path.join(component))
}

fn append_user_package_bins(dirs: &mut Vec<PathBuf>, home: &Path) {
    dirs.push(home.join(".local").join("bin"));
    dirs.push(home.join(".npm-global").join("bin"));
    dirs.push(home.join(".cargo").join("bin"));
    dirs.push(home.join(".bun").join("bin"));
}

fn classify_binary_source(path: &Path) -> &'static str {
    let normalized = path
        .to_string_lossy()
        .replace('\\', "/")
        .to_ascii_lowercase();
    if normalized.contains("/applications/") || normalized.contains("/windowsapps/") {
        return BINARY_SOURCE_APPLICATION_STORE;
    }
    if [
        "/homebrew/",
        "/winget/",
        "/chocolatey/",
        "/scoop/",
        "/npm/",
        "/pnpm/",
        "/.cargo/",
        "/.bun/",
        "/snap/",
        "/flatpak/",
    ]
    .iter()
    .any(|marker| normalized.contains(marker))
    {
        return BINARY_SOURCE_PACKAGE_MANAGER;
    }
    BINARY_SOURCE_EXECUTABLE_PATH
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = BTreeSet::<String>::new();
    let mut out = Vec::<PathBuf>::new();
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

    #[test]
    fn binary_candidates_preserve_priority_and_dedupe_case_insensitively() {
        let dir = PathBuf::from("/tools");
        let candidates = binary_candidate_paths(&dir, "codex");
        assert_eq!(candidates.first(), Some(&dir.join("codex")));
        let deduped = dedupe_paths(vec![dir.join("Codex"), dir.join("codex")]);
        assert_eq!(deduped.len(), 1);
    }

    #[test]
    fn platform_sources_cover_application_stores_and_package_managers() {
        let roots = PlatformBinaryRoots {
            home: Some(PathBuf::from("/profile")),
            app_data: Some(PathBuf::from("/app-data")),
            local_app_data: Some(PathBuf::from("/local-app-data")),
            program_data: Some(PathBuf::from("/program-data")),
            program_files: Some(PathBuf::from("/program-files")),
            program_files_x86: None,
        };
        let windows = common_binary_dirs_for_platform("windows", &roots);
        assert!(windows.contains(&PathBuf::from("/local-app-data/Microsoft/WindowsApps")));
        assert!(windows.contains(&PathBuf::from("/local-app-data/Microsoft/WinGet/Links")));
        assert!(windows.contains(&PathBuf::from("/profile/scoop/shims")));
        assert!(windows.contains(&PathBuf::from("/program-data/chocolatey/bin")));

        let macos = common_binary_dirs_for_platform("macos", &roots);
        assert!(macos.contains(&posix_path(&["opt", "homebrew", "bin"])));
        assert!(
            macos
                .iter()
                .any(|path| path.to_string_lossy().contains("Cursor.app"))
        );

        let linux = common_binary_dirs_for_platform("linux", &roots);
        assert!(linux.contains(&posix_path(&["snap", "bin"])));
        assert!(linux.contains(&posix_path(&["var", "lib", "flatpak", "exports", "bin"])));
    }

    #[test]
    fn discovered_binary_source_is_minimal_and_stable() {
        assert_eq!(
            classify_binary_source(&posix_path(&[
                "Applications",
                "Cursor.app",
                "Contents",
                "Resources",
                "app",
                "bin",
                "cursor",
            ])),
            BINARY_SOURCE_APPLICATION_STORE
        );
        assert_eq!(
            classify_binary_source(Path::new("/profile/scoop/shims/codex.exe")),
            BINARY_SOURCE_PACKAGE_MANAGER
        );
        assert_eq!(
            classify_binary_source(Path::new("/custom/bin/codex")),
            BINARY_SOURCE_EXECUTABLE_PATH
        );
    }
}
