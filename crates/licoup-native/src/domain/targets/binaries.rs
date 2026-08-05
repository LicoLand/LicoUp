use super::catalog::TargetDef;
use super::parameters::param_string;
use super::platform_paths::kilo_code_extension_roots;
use crate::platform::agent_workspace::default_local_agent_workspace;
use crate::platform::runtime_adapters;
use directories::UserDirs;
use serde_json::Value;
use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::path::{Component, Path, PathBuf};

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
    find_cursor_binary_in_dirs(&binary_search_dirs(), params)
}

fn find_cursor_binary_in_dirs(dirs: &[PathBuf], params: &Value) -> Option<PathBuf> {
    let mut first_cursor_agent = None::<PathBuf>;
    for name in ["cursor-agent", "cursor"] {
        let Some(candidate) = find_binary_in_dirs(&[name], dirs) else {
            continue;
        };
        // Prefer a probed Agent CLI. Keep the first `cursor-agent` as fallback
        // so a flaky short probe (or missing default workspace) cannot hide a
        // PATH-visible conversation binary. Never fall back to the IDE `cursor`
        // shim — it is not the Agent CLI lane.
        if name == "cursor-agent" {
            first_cursor_agent.get_or_insert_with(|| candidate.clone());
        }
        if cursor_binary_supports_acp(&candidate, params) {
            return Some(candidate);
        }
    }
    first_cursor_agent
}

pub(super) fn find_target_binary_with_source(
    def: &TargetDef,
    params: &Value,
) -> Option<(PathBuf, &'static str)> {
    if let Some(path) = find_target_binary(def, params) {
        let source = classify_binary_source(&path);
        return Some((path, source));
    }
    find_extension_bundled_binary(def).map(|path| {
        let source = classify_binary_source(&path);
        (path, source)
    })
}

/// Some targets ship their official executable inside a product package
/// instead of a PATH-visible install. Kilo Code bundles `bin/kilo` (or
/// `bin/kilo.exe` on Windows) inside the VS Code extension directory, and
/// that binary speaks the same `kilo serve` contract as the standalone CLI,
/// so an extension-only install is a full runtime source. The Kimi desktop
/// app installs as a macOS application bundle whose executable is the
/// product's only local binary; discovering it keeps desktop detection
/// honest even though the app exposes no local conversation lane.
pub(super) fn find_extension_bundled_binary(def: &TargetDef) -> Option<PathBuf> {
    match def.id {
        "kilo-code" => {
            let home = UserDirs::new()?.home_dir().to_path_buf();
            find_kilo_code_extension_cli(&kilo_code_extension_roots(&home))
        }
        "kimi" => find_kimi_desktop_app_executable(&kimi_desktop_app_roots()),
        _ => None,
    }
}

fn kimi_desktop_app_roots() -> Vec<PathBuf> {
    macos_application_roots()
}

/// System and per-user application folders used for macOS `.app` bundle
/// detection. Windows and Linux install locations for these desktop apps are
/// not mapped; only verified locations may be listed here.
fn macos_application_roots() -> Vec<PathBuf> {
    match std::env::consts::OS {
        "macos" => {
            let mut roots = vec![PathBuf::from("/Applications")];
            if let Some(home) = UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf()) {
                roots.push(home.join("Applications"));
            }
            roots
        }
        _ => Vec::new(),
    }
}

pub(super) fn find_macos_app_executable(
    app_bundle: &str,
    executable: &str,
    roots: &[PathBuf],
) -> Option<PathBuf> {
    roots
        .iter()
        .map(|root| {
            root.join(app_bundle)
                .join("Contents")
                .join("MacOS")
                .join(executable)
        })
        .find(|candidate| candidate.is_file())
}

pub(super) fn find_kimi_desktop_app_executable(roots: &[PathBuf]) -> Option<PathBuf> {
    find_macos_app_executable("Kimi.app", "Kimi", roots)
}

/// Desktop application presence for agents whose desktop product is a
/// verified macOS bundle. Agents without a mapped desktop product never
/// report detection.
pub(super) fn desktop_app_executable(agent_id: &str) -> Option<PathBuf> {
    let (app_bundle, executable) = match agent_id {
        "codex" => ("ChatGPT.app", "ChatGPT"),
        "antigravity" => ("Antigravity.app", "Antigravity"),
        "cursor" => ("Cursor.app", "Cursor"),
        _ => return None,
    };
    find_macos_app_executable(app_bundle, executable, &macos_application_roots())
}

pub(super) fn find_kilo_code_extension_cli(roots: &[PathBuf]) -> Option<PathBuf> {
    let mut best: Option<(Vec<u64>, usize, PathBuf)> = None;
    for (root_index, root) in roots.iter().enumerate() {
        let Ok(entries) = fs::read_dir(root) else {
            continue;
        };
        for entry in entries.filter_map(|entry| entry.ok()) {
            let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
            if name != "kilocode.kilo-code" && !name.starts_with("kilocode.kilo-code-") {
                continue;
            }
            let Some(binary) = kilo_code_bundled_binary(&entry.path()) else {
                continue;
            };
            let rank = kilo_extension_version_rank(&name);
            let replace = match &best {
                None => true,
                Some((best_rank, best_root, _)) => {
                    rank > *best_rank || (rank == *best_rank && root_index < *best_root)
                }
            };
            if replace {
                best = Some((rank, root_index, binary));
            }
        }
    }
    best.map(|(_, _, path)| path)
}

fn kilo_code_bundled_binary(extension_dir: &Path) -> Option<PathBuf> {
    kilo_bundled_binary_names()
        .into_iter()
        .map(|name| extension_dir.join("bin").join(name))
        .find(|candidate| candidate.is_file())
}

#[cfg(not(target_os = "windows"))]
fn kilo_bundled_binary_names() -> [&'static str; 1] {
    ["kilo"]
}

#[cfg(target_os = "windows")]
fn kilo_bundled_binary_names() -> [&'static str; 2] {
    ["kilo.exe", "kilo"]
}

fn kilo_extension_version_rank(extension_dir_name: &str) -> Vec<u64> {
    extension_dir_name
        .strip_prefix("kilocode.kilo-code-")
        .unwrap_or("")
        .split('-')
        .next()
        .unwrap_or("")
        .split('.')
        .map(|part| part.parse::<u64>().unwrap_or(0))
        .collect()
}

pub(super) fn cursor_binary_supports_acp(binary: &Path, params: &Value) -> bool {
    // The Cursor capability probe only runs `--version` / `--help` and does not
    // need a project workspace. Keep a cwd for the shared probe API, but never
    // treat a missing default workspace as "binary unsupported" — that hid a
    // working `cursor-agent` from Adaptive Flywheel and conversation relays.
    let cwd = param_string(params, "workingDirectory")
        .or_else(|| param_string(params, "cwd"))
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| default_local_agent_workspace("cursor"))
        .unwrap_or_else(env::temp_dir);
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
    let roots = PlatformBinaryRoots::from_environment();
    let mut dirs = env::var_os("PATH")
        .map(|path_var| {
            env::split_paths(&path_var)
                .filter(|path| {
                    automatic_binary_search_dir_allowed(
                        std::env::consts::OS,
                        path,
                        roots.home.as_deref(),
                    )
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    dirs.extend(common_binary_dirs_for_platform(
        std::env::consts::OS,
        &roots,
    ));
    dedupe_paths(dirs)
}

fn automatic_binary_search_dir_allowed(platform: &str, path: &Path, home: Option<&Path>) -> bool {
    if platform != "macos" {
        return true;
    }
    let mut components = path.components();
    if !matches!(components.next(), Some(Component::RootDir)) {
        return false;
    }
    let Some(Component::Normal(root_name)) = components.next() else {
        return false;
    };
    if root_name == "Volumes" {
        return false;
    }
    if matches!(
        root_name.to_str(),
        Some("usr" | "opt" | "bin" | "sbin" | "Applications")
    ) {
        return true;
    }
    let Some(home) = home else {
        return false;
    };
    let Ok(relative) = path.strip_prefix(home) else {
        return false;
    };
    let Some(first) = relative.components().next() else {
        return false;
    };
    let first = first.as_os_str().to_string_lossy();
    first.starts_with('.')
        || relative.starts_with("Library/pnpm")
        || relative.starts_with("Applications")
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
    components.iter().fold(
        PathBuf::from(char::from(47).to_string()),
        |path, component| path.join(component),
    )
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
    // Editor extension directories are installed from the editor's extension
    // marketplace, which is an application store for discovery purposes.
    if [
        "/.vscode/extensions/",
        "/.vscode-insiders/extensions/",
        "/.cursor/extensions/",
        "/.vscodium/extensions/",
    ]
    .iter()
    .any(|marker| normalized.contains(marker))
    {
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
        let dir = posix_path(&["tools"]);
        let candidates = binary_candidate_paths(&dir, "codex");
        assert_eq!(candidates.first(), Some(&dir.join("codex")));
        let deduped = dedupe_paths(vec![dir.join("Codex"), dir.join("codex")]);
        assert_eq!(deduped.len(), 1);
    }

    #[test]
    fn platform_sources_cover_application_stores_and_package_managers() {
        let roots = PlatformBinaryRoots {
            home: Some(posix_path(&["profile"])),
            app_data: Some(posix_path(&["app-data"])),
            local_app_data: Some(posix_path(&["local-app-data"])),
            program_data: Some(posix_path(&["program-data"])),
            program_files: Some(posix_path(&["program-files"])),
            program_files_x86: None,
        };
        let windows = common_binary_dirs_for_platform("windows", &roots);
        assert!(windows.contains(&posix_path(&["local-app-data", "Microsoft", "WindowsApps"])));
        assert!(windows.contains(&posix_path(&[
            "local-app-data",
            "Microsoft",
            "WinGet",
            "Links"
        ])));
        assert!(windows.contains(&posix_path(&["profile", "scoop", "shims"])));
        assert!(windows.contains(&posix_path(&["program-data", "chocolatey", "bin"])));

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
    fn macos_automatic_search_skips_protected_and_network_locations() {
        let home = posix_path(&["profile"]);
        for protected in [
            posix_path(&["profile", "Downloads", "bin"]),
            posix_path(&["profile", "Desktop", "tools"]),
            posix_path(&["profile", "Documents", "scripts"]),
            posix_path(&["Volumes", "team-share", "bin"]),
        ] {
            assert!(!automatic_binary_search_dir_allowed(
                "macos",
                &protected,
                Some(&home),
            ));
        }
    }

    #[test]
    fn macos_automatic_search_keeps_system_and_hidden_package_locations() {
        let home = posix_path(&["profile"]);
        for allowed in [
            posix_path(&["usr", "local", "bin"]),
            posix_path(&["opt", "homebrew", "bin"]),
            posix_path(&[
                "Applications",
                "Cursor.app",
                "Contents",
                "Resources",
                "app",
                "bin",
            ]),
            posix_path(&["profile", ".local", "bin"]),
            posix_path(&["profile", ".nvm", "versions", "node", "current", "bin"]),
            posix_path(&["profile", "Library", "pnpm"]),
        ] {
            assert!(automatic_binary_search_dir_allowed(
                "macos",
                &allowed,
                Some(&home),
            ));
        }
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
            classify_binary_source(&posix_path(&["profile", "scoop", "shims", "codex.exe"])),
            BINARY_SOURCE_PACKAGE_MANAGER
        );
        assert_eq!(
            classify_binary_source(&posix_path(&["custom", "bin", "codex"])),
            BINARY_SOURCE_EXECUTABLE_PATH
        );
    }

    #[test]
    fn editor_extension_bundled_binary_is_an_application_store_source() {
        for root in [".vscode", ".vscode-insiders", ".cursor", ".vscodium"] {
            let bundled = posix_path(&[
                "profile",
                root,
                "extensions",
                "kilocode.kilo-code-7.4.15",
                "bin",
                "kilo",
            ]);
            assert_eq!(
                classify_binary_source(&bundled),
                BINARY_SOURCE_APPLICATION_STORE
            );
        }
    }

    #[test]
    fn kilo_extension_version_rank_orders_semver_like_names() {
        let newer = kilo_extension_version_rank("kilocode.kilo-code-7.4.15-darwin-arm64");
        let older = kilo_extension_version_rank("kilocode.kilo-code-7.4.2-darwin-arm64");
        let unversioned = kilo_extension_version_rank("kilocode.kilo-code");
        assert!(newer > older);
        assert!(older > unversioned);
        assert_eq!(
            kilo_extension_version_rank("kilocode.kilo-code-7.10.0"),
            kilo_extension_version_rank("kilocode.kilo-code-7.10.0-darwin-arm64")
        );
    }

    #[test]
    fn kilo_code_extension_cli_prefers_newest_version_with_bundled_binary() {
        let dir = unique_temp_dir("kilo-extension-cli");
        let stable_root = dir.join(".vscode").join("extensions");
        let insiders_root = dir.join(".vscode-insiders").join("extensions");
        // Newest install lacks the bundled binary and must be skipped.
        fs::create_dir_all(stable_root.join("kilocode.kilo-code-9.0.0")).unwrap();
        let bundled = stable_root
            .join("kilocode.kilo-code-7.4.15-darwin-arm64")
            .join("bin")
            .join(kilo_bundled_binary_names()[0]);
        fs::create_dir_all(bundled.parent().unwrap()).unwrap();
        fs::write(&bundled, "kilo").unwrap();
        let older = insiders_root
            .join("kilocode.kilo-code-6.0.0")
            .join("bin")
            .join(kilo_bundled_binary_names()[0]);
        fs::create_dir_all(older.parent().unwrap()).unwrap();
        fs::write(&older, "kilo").unwrap();
        // Unrelated extensions must be ignored.
        fs::create_dir_all(stable_root.join("kilocode.other-1.0.0").join("bin")).unwrap();

        let found = find_kilo_code_extension_cli(&[stable_root, insiders_root]).unwrap();

        assert_eq!(found, bundled);
    }

    #[test]
    fn kilo_code_extension_cli_prefers_earlier_root_on_version_tie() {
        let dir = unique_temp_dir("kilo-extension-cli-tie");
        let stable_root = dir.join(".vscode").join("extensions");
        let cursor_root = dir.join(".cursor").join("extensions");
        for root in [&stable_root, &cursor_root] {
            let binary = root
                .join("kilocode.kilo-code-7.4.15")
                .join("bin")
                .join(kilo_bundled_binary_names()[0]);
            fs::create_dir_all(binary.parent().unwrap()).unwrap();
            fs::write(binary, "kilo").unwrap();
        }

        let found = find_kilo_code_extension_cli(&[stable_root.clone(), cursor_root]).unwrap();

        assert!(found.starts_with(&stable_root));
    }

    #[test]
    fn kilo_code_extension_cli_returns_none_without_bundled_binary() {
        let dir = unique_temp_dir("kilo-extension-cli-empty");
        let root = dir.join(".vscode").join("extensions");
        fs::create_dir_all(root.join("kilocode.kilo-code-7.4.15")).unwrap();
        fs::create_dir_all(dir.join("empty-root")).unwrap();

        assert!(find_kilo_code_extension_cli(&[root, dir.join("empty-root")]).is_none());
        assert!(find_kilo_code_extension_cli(&[dir.join("missing-root")]).is_none());
    }

    #[test]
    fn kimi_desktop_app_executable_resolves_bundle_in_install_roots() {
        let dir = unique_temp_dir("kimi-desktop-app");
        let system_root = dir.join("Applications");
        let executable = system_root
            .join("Kimi.app")
            .join("Contents")
            .join("MacOS")
            .join("Kimi");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        fs::write(&executable, "kimi").unwrap();

        let found = find_kimi_desktop_app_executable(&[system_root]).unwrap();

        assert_eq!(found, executable);
    }

    #[test]
    fn kimi_desktop_app_executable_prefers_earlier_root_and_skips_incomplete_bundles() {
        let dir = unique_temp_dir("kimi-desktop-app-roots");
        let first_root = dir.join("first");
        let second_root = dir.join("second");
        // First root has a bundle without the executable; second root is complete.
        fs::create_dir_all(first_root.join("Kimi.app").join("Contents")).unwrap();
        let executable = second_root
            .join("Kimi.app")
            .join("Contents")
            .join("MacOS")
            .join("Kimi");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        fs::write(&executable, "kimi").unwrap();

        let found = find_kimi_desktop_app_executable(&[first_root, second_root]).unwrap();

        assert_eq!(found, executable);
        assert!(find_kimi_desktop_app_executable(&[dir.join("missing")]).is_none());
        assert!(find_kimi_desktop_app_executable(&[]).is_none());
    }

    #[test]
    fn macos_app_executable_resolves_any_verified_bundle() {
        let dir = unique_temp_dir("macos-app-executable");
        let root = dir.join("Applications");
        let executable = root
            .join("ChatGPT.app")
            .join("Contents")
            .join("MacOS")
            .join("ChatGPT");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        fs::write(&executable, "chatgpt").unwrap();

        assert_eq!(
            find_macos_app_executable("ChatGPT.app", "ChatGPT", &[root.clone()]),
            Some(executable)
        );
        assert!(
            find_macos_app_executable("Antigravity.app", "Antigravity", &[root.clone()]).is_none()
        );
        assert!(find_macos_app_executable("ChatGPT.app", "Other", &[root]).is_none());
    }

    #[test]
    fn desktop_app_executable_maps_only_verified_agent_products() {
        // Unmapped agents never report desktop detection.
        for agent in ["claude-code", "opencode", "kimi-code", "pi"] {
            assert!(desktop_app_executable(agent).is_none());
        }
        // Mapped agents read only the verified macOS roots; on non-macOS
        // platforms no roots exist and detection is always empty.
        if std::env::consts::OS != "macos" {
            for agent in ["codex", "antigravity", "cursor"] {
                assert!(desktop_app_executable(agent).is_none());
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn cursor_agent_binds_even_when_short_capability_probe_fails() {
        use std::os::unix::fs::PermissionsExt;

        let dir = unique_temp_dir("cursor-agent-fallback-bind");
        let agent = dir.join("cursor-agent");
        // Help intentionally omits create-chat so the short probe rejects it.
        fs::write(
            &agent,
            "#!/bin/sh\ncase \"$1\" in\n--version) echo 1; exit 0 ;;\n--help) echo 'Usage: agent'; exit 0 ;;\n*) exit 1 ;;\nesac\n",
        )
        .unwrap();
        fs::set_permissions(&agent, fs::Permissions::from_mode(0o755)).unwrap();

        let found = find_cursor_binary_in_dirs(&[dir.clone()], &serde_json::json!({}));
        assert_eq!(found.as_deref(), Some(agent.as_path()));
        assert!(!cursor_binary_supports_acp(&agent, &serde_json::json!({})));
    }

    fn unique_temp_dir(name: &str) -> PathBuf {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let dir = env::temp_dir().join(format!(
            "lico-targets-{}-{}-{}",
            name,
            stamp.as_secs(),
            stamp.subsec_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
