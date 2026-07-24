use super::parameters::param_string;
use directories::UserDirs;
use serde_json::Value;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

#[cfg(test)]
pub(super) fn default_config_path(target: &str) -> Option<PathBuf> {
    default_config_path_with_params(target, &Value::Null)
}

pub(super) fn default_config_path_with_params(target: &str, params: &Value) -> Option<PathBuf> {
    let home = UserDirs::new()?.home_dir().to_path_buf();
    if target == "kimi-code"
        && let Some(root) = kimi_code_home_override(params, &home)
    {
        return Some(root.join("config.toml"));
    }
    let app_data = default_app_data_dir(&home);
    default_config_path_for_platform(target, std::env::consts::OS, &home, &app_data)
}

pub(super) fn default_detection_path_with_params(target: &str, params: &Value) -> Option<PathBuf> {
    let home = UserDirs::new()?.home_dir().to_path_buf();
    if target == "kimi-code"
        && let Some(root) = kimi_code_home_override(params, &home)
    {
        return root.exists().then_some(root);
    }
    let app_data = default_app_data_dir(&home);
    default_detection_path_for_platform(target, std::env::consts::OS, &home, &app_data)
}

pub(super) fn kimi_code_home_override(params: &Value, home: &Path) -> Option<PathBuf> {
    param_string(params, "kimiCodeHome")
        .or_else(|| env::var("KIMI_CODE_HOME").ok())
        .map(|value| expand_home_root(&value, home))
}

fn expand_home_root(value: &str, home: &Path) -> PathBuf {
    let trimmed = value.trim();
    if trimmed == "~" {
        return home.to_path_buf();
    }
    if let Some(relative) = trimmed
        .strip_prefix("~/")
        .or_else(|| trimmed.strip_prefix("~\\"))
    {
        return home.join(relative);
    }
    PathBuf::from(trimmed)
}

pub(super) fn default_app_data_dir(home: &Path) -> PathBuf {
    if let Ok(value) = env::var("APPDATA")
        && !value.trim().is_empty()
    {
        return PathBuf::from(value);
    }
    directories::BaseDirs::new()
        .map(|dirs| dirs.data_dir().to_path_buf())
        .unwrap_or_else(|| home.join("AppData").join("Roaming"))
}

pub(super) fn default_config_path_for_platform(
    target: &str,
    platform: &str,
    home: &Path,
    app_data: &Path,
) -> Option<PathBuf> {
    match target {
        "codex" => Some(home.join(".codex").join("config.toml")),
        "code" if platform == "windows" => {
            Some(app_data.join("Code").join("User").join("settings.json"))
        }
        "code" if platform == "macos" => Some(
            home.join("Library")
                .join("Application Support")
                .join("Code")
                .join("User")
                .join("settings.json"),
        ),
        "code" => Some(
            home.join(".config")
                .join("Code")
                .join("User")
                .join("settings.json"),
        ),
        "opencode" if platform == "windows" => {
            Some(app_data.join("opencode").join("opencode.jsonc"))
        }
        "opencode" => Some(home.join(".config").join("opencode").join("opencode.jsonc")),
        "antigravity" => Some(
            home.join(".gemini")
                .join("antigravity")
                .join("mcp_config.json"),
        ),
        "cursor" if platform == "windows" => Some(
            app_data
                .join("Cursor")
                .join("User")
                .join("globalStorage")
                .join("saoudrizwan.claude-dev")
                .join("settings")
                .join("cline_mcp_settings.json"),
        ),
        "cursor" if platform == "macos" => Some(
            home.join("Library")
                .join("Application Support")
                .join("Cursor")
                .join("User")
                .join("globalStorage")
                .join("saoudrizwan.claude-dev")
                .join("settings")
                .join("cline_mcp_settings.json"),
        ),
        "cursor" => Some(
            home.join(".config")
                .join("Cursor")
                .join("User")
                .join("globalStorage")
                .join("saoudrizwan.claude-dev")
                .join("settings")
                .join("cline_mcp_settings.json"),
        ),
        "kilo-code" if platform == "windows" => Some(app_data.join("kilo").join("kilo.json")),
        "kilo-code" => Some(home.join(".config").join("kilo").join("kilo.json")),
        "kimi-code" => Some(home.join(".kimi-code").join("config.toml")),
        "pi" => Some(home.join(".pi").join("agent").join("settings.json")),
        "kimi" if platform == "windows" => Some(app_data.join("Kimi").join("config.json")),
        "kimi" if platform == "macos" => Some(
            home.join("Library")
                .join("Application Support")
                .join("Kimi")
                .join("config.json"),
        ),
        "kimi" => Some(home.join(".config").join("Kimi").join("config.json")),
        "openclaw" => None,
        "claude-code" => Some(home.join(".claude").join("settings.json")),
        "copilot" => None,
        "hermes" => None,
        _ => None,
    }
}

pub(super) fn default_detection_path_for_platform(
    target: &str,
    platform: &str,
    home: &Path,
    app_data: &Path,
) -> Option<PathBuf> {
    default_detection_paths_for_platform(target, platform, home, app_data)
        .into_iter()
        .find(|path| path.exists())
        .or_else(|| {
            if target == "kilo-code" {
                kilo_code_extension_roots(home)
                    .into_iter()
                    .find_map(existing_kilo_code_extension_dir)
            } else {
                None
            }
        })
}

pub(super) fn default_detection_paths_for_platform(
    target: &str,
    platform: &str,
    home: &Path,
    app_data: &Path,
) -> Vec<PathBuf> {
    match target {
        "cursor" => match platform {
            "windows" => vec![app_data.join("Cursor")],
            "macos" => vec![
                home.join("Library")
                    .join("Application Support")
                    .join("Cursor"),
            ],
            _ => vec![home.join(".config").join("Cursor")],
        },
        "kilo-code" => {
            let storage_roots = match platform {
                "windows" => vec![
                    app_data.join("Code"),
                    app_data.join("Code - Insiders"),
                    app_data.join("Cursor"),
                    app_data.join("VSCodium"),
                ],
                "macos" => {
                    let app_support = home.join("Library").join("Application Support");
                    vec![
                        app_support.join("Code"),
                        app_support.join("Code - Insiders"),
                        app_support.join("Cursor"),
                        app_support.join("VSCodium"),
                    ]
                }
                _ => vec![
                    home.join(".config").join("Code"),
                    home.join(".config").join("Code - Insiders"),
                    home.join(".config").join("Cursor"),
                    home.join(".config").join("VSCodium"),
                ],
            };
            storage_roots
                .into_iter()
                .map(|root| {
                    root.join("User")
                        .join("globalStorage")
                        .join("kilocode.kilo-code")
                })
                .collect()
        }
        "kimi-code" => vec![
            home.join(".kimi-code").join("config.toml"),
            home.join(".kimi-code").join("session_index.jsonl"),
            home.join(".kimi-code").join("sessions"),
        ],
        "pi" => vec![
            home.join(".pi").join("agent").join("settings.json"),
            home.join(".pi").join("agent").join("sessions"),
        ],
        "kimi" => match platform {
            "windows" => vec![app_data.join("Kimi"), app_data.join("com.moonshot.kimi")],
            "macos" => {
                let app_support = home.join("Library").join("Application Support");
                vec![
                    app_support.join("Kimi"),
                    app_support.join("com.moonshot.kimi"),
                ]
            }
            _ => vec![
                home.join(".config").join("Kimi"),
                home.join(".local").join("share").join("Kimi"),
            ],
        },
        _ => Vec::new(),
    }
}

fn kilo_code_extension_roots(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(".vscode").join("extensions"),
        home.join(".vscode-insiders").join("extensions"),
        home.join(".cursor").join("extensions"),
        home.join(".vscodium").join("extensions"),
    ]
}

fn existing_kilo_code_extension_dir(root: PathBuf) -> Option<PathBuf> {
    let entries = fs::read_dir(root).ok()?;
    for entry in entries.filter_map(|entry| entry.ok()) {
        let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
        if name == "kilocode.kilo-code" || name.starts_with("kilocode.kilo-code-") {
            return Some(entry.path());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_mapping_keeps_config_and_detection_policies_separate() {
        let home = PathBuf::from("/profile");
        let app_data = PathBuf::from("/app-data");
        assert_eq!(
            default_config_path_for_platform("code", "windows", &home, &app_data),
            Some(app_data.join("Code/User/settings.json"))
        );
        assert_eq!(
            default_detection_paths_for_platform("kimi", "linux", &home, &app_data),
            vec![home.join(".config/Kimi"), home.join(".local/share/Kimi")]
        );
        assert_eq!(
            expand_home_root("~/.kimi-code", &home),
            home.join(".kimi-code")
        );
    }
}
