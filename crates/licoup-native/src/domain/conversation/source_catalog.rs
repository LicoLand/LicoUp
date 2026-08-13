use super::parameters::text_param;
use super::paths::{
    appdata_dir, appdata_dir_from_home, expand_home, expand_home_from, home_dir, local_appdata_dir,
    local_appdata_dir_from_home, xdg_config_dir, xdg_config_dir_from_home, xdg_data_dir,
    xdg_data_dir_from_home,
};
use crate::platform::paths::portable_data_dir;
use serde_json::Value;
use std::env;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum HistoryAdapter {
    Antigravity,
    ClaudeCode,
    Code,
    Codex,
    Copilot,
    Cursor,
    Hermes,
    KiloCode,
    Kimi,
    KimiCode,
    OpenClaw,
    OpenCode,
    Pi,
    LicoAgent,
}

#[derive(Clone, Debug)]
pub(crate) struct HistoryRoot {
    pub(crate) path: PathBuf,
    pub(crate) source_kind: String,
}

impl HistoryAdapter {
    pub(crate) fn id(self) -> &'static str {
        match self {
            Self::Antigravity => "antigravity",
            Self::ClaudeCode => "claude-code",
            Self::Code => "code",
            Self::Codex => "codex",
            Self::Copilot => "copilot",
            Self::Cursor => "cursor",
            Self::Hermes => "hermes",
            Self::KiloCode => "kilo-code",
            Self::Kimi => "kimi",
            Self::KimiCode => "kimi-code",
            Self::OpenClaw => "openclaw",
            Self::OpenCode => "opencode",
            Self::Pi => "pi",
            Self::LicoAgent => "lico-agent",
        }
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Antigravity => "Antigravity - IDE",
            Self::ClaudeCode => "Claude Code - CLI",
            Self::Code => "Visual Studio Code - IDE",
            Self::Codex => "ChatGPT - Desktop",
            Self::Copilot => "GitHub Copilot - Plugin",
            Self::Cursor => "Cursor - IDE",
            Self::Hermes => "Hermes Agent - CLI",
            Self::KiloCode => "Kilo Code - CLI",
            Self::Kimi => "Kimi - Desktop",
            Self::KimiCode => "Kimi Code - CLI",
            Self::OpenClaw => "OpenClaw - CLI",
            Self::OpenCode => "OpenCode - CLI",
            Self::Pi => "Pi Agent - CLI",
            Self::LicoAgent => "Lico Agent - CLI",
        }
    }

    pub(crate) fn accepts_file(self, path: &Path, extension: &str) -> bool {
        if self == Self::KimiCode {
            return extension == "jsonl"
                && path.file_name().and_then(|value| value.to_str()) == Some("wire.jsonl")
                && path
                    .components()
                    .any(|component| component.as_os_str() == "agents");
        }
        if path
            .file_name()
            .and_then(|value| value.to_str())
            .map(|name| name.ends_with(".backup") || name == "codebase-external.sqlite")
            .unwrap_or(false)
        {
            return false;
        }
        match self {
            Self::Codex => matches!(extension, "jsonl" | "ndjson" | "json" | "md"),
            Self::ClaudeCode => matches!(extension, "jsonl" | "json" | "md" | "txt"),
            Self::Code => matches!(
                extension,
                "jsonl"
                    | "ndjson"
                    | "json"
                    | "md"
                    | "txt"
                    | "log"
                    | "sqlite"
                    | "sqlite3"
                    | "db"
                    | "vscdb"
            ),
            Self::Antigravity => matches!(
                extension,
                "jsonl"
                    | "ndjson"
                    | "json"
                    | "md"
                    | "txt"
                    | "log"
                    | "sqlite"
                    | "sqlite3"
                    | "db"
                    | "vscdb"
            ),
            Self::Cursor | Self::Copilot => matches!(
                extension,
                "jsonl" | "ndjson" | "json" | "sqlite" | "sqlite3" | "db" | "vscdb"
            ),
            Self::LicoAgent => matches!(extension, "jsonl" | "ndjson" | "json"),
            Self::KiloCode
            | Self::OpenCode
            | Self::OpenClaw
            | Self::Hermes
            | Self::Kimi
            | Self::KimiCode
            | Self::Pi => matches!(
                extension,
                "jsonl" | "ndjson" | "json" | "md" | "txt" | "log" | "sqlite" | "sqlite3" | "db"
            ),
        }
    }

    pub(crate) fn sqlite_table_may_hold_history(self, name: &str) -> bool {
        let lower = name.to_ascii_lowercase();
        if lower.starts_with("sqlite") || lower.contains("fts") || lower.contains("embedding") {
            return false;
        }
        if self == Self::KiloCode
            && (lower.contains("account") || lower.contains("control_account"))
        {
            return false;
        }
        match self {
            Self::Code => {
                lower == "itemtable"
                    || lower.contains("chat")
                    || lower.contains("conversation")
                    || lower.contains("session")
                    || lower.contains("history")
                    || lower.contains("workspace")
                    || lower.contains("state")
            }
            Self::Cursor | Self::Copilot | Self::Antigravity => {
                lower == "itemtable"
                    || lower == "cursordiskkv"
                    || lower.contains("chat")
                    || lower.contains("conversation")
                    || lower.contains("session")
                    || lower.contains("history")
            }
            _ => {
                lower.contains("chat")
                    || lower.contains("conversation")
                    || lower.contains("session")
                    || lower.contains("history")
                    || lower == "itemtable"
            }
        }
    }

    pub(crate) fn sqlite_row_may_hold_history(
        self,
        table: &str,
        key: Option<&str>,
        row_text: &str,
    ) -> bool {
        let key = key.unwrap_or_default().to_ascii_lowercase();
        let text = row_text.to_ascii_lowercase();
        match self {
            Self::Code => {
                key.contains("chat")
                    || key.contains("conversation")
                    || key.contains("session")
                    || key.contains("history")
                    || key.contains("workspace")
                    || key.contains("recent")
                    || looks_like_history_text(row_text)
            }
            Self::Copilot => {
                key.contains("github.copilot")
                    || key.contains("copilot")
                    || key.contains("chatsessions")
                    || text.contains("copilot")
            }
            Self::Cursor => {
                key.contains("aichat")
                    || key.contains("composer")
                    || key.contains("chat")
                    || key.contains("conversation")
                    || key.starts_with("bubbleid:")
                    || key.starts_with("composerdata:")
                    || looks_like_history_text(row_text)
            }
            Self::KiloCode => {
                !table.to_ascii_lowercase().contains("account") && looks_like_history_text(row_text)
            }
            _ => looks_like_history_text(row_text),
        }
    }
}

pub(crate) fn adapter_for_agent(agent_id: &str) -> Option<HistoryAdapter> {
    match agent_id {
        "antigravity" => Some(HistoryAdapter::Antigravity),
        "claude" | "claude-code" => Some(HistoryAdapter::ClaudeCode),
        "code" | "vscode" | "vs-code" => Some(HistoryAdapter::Code),
        "codex" => Some(HistoryAdapter::Codex),
        "copilot" | "github-copilot" => Some(HistoryAdapter::Copilot),
        "cursor" => Some(HistoryAdapter::Cursor),
        "hermes" | "hermes-agent" => Some(HistoryAdapter::Hermes),
        "kilo" | "kilo-code" => Some(HistoryAdapter::KiloCode),
        "kimi" | "moonshot" => Some(HistoryAdapter::Kimi),
        "kimi-code" | "kimi_code" | "kimicode" => Some(HistoryAdapter::KimiCode),
        "openclaw" => Some(HistoryAdapter::OpenClaw),
        "opencode" => Some(HistoryAdapter::OpenCode),
        "pi" | "pi-agent" | "pi-coding-agent" => Some(HistoryAdapter::Pi),
        "lico-agent" | "lico" => Some(HistoryAdapter::LicoAgent),
        _ => None,
    }
}

pub(crate) fn history_roots(adapter: HistoryAdapter, params: &Value) -> Vec<HistoryRoot> {
    if let Some(root) = text_param(params, &["root", "historyRoot"])
        && !root.is_empty()
    {
        return vec![HistoryRoot {
            path: expand_home(&root),
            source_kind: text_param(params, &["historyRootKind", "rootKind"])
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "override-root".to_string()),
        }];
    }
    let home_override = text_param(params, &["homeDir"])
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from);
    let home = home_override.clone().unwrap_or_else(home_dir);
    let appdata = home_override
        .as_ref()
        .map(|path| appdata_dir_from_home(path))
        .unwrap_or_else(appdata_dir);
    let local_appdata = home_override
        .as_ref()
        .map(|path| local_appdata_dir_from_home(path))
        .unwrap_or_else(local_appdata_dir);
    let xdg_config = home_override
        .as_ref()
        .map(|path| xdg_config_dir_from_home(path))
        .unwrap_or_else(xdg_config_dir);
    let xdg_data = home_override
        .as_ref()
        .map(|path| xdg_data_dir_from_home(path))
        .unwrap_or_else(xdg_data_dir);
    let kimi_code_home = kimi_code_history_home(params, &home, home_override.is_none());
    let copilot_home = copilot_history_home(params, &home, home_override.is_none());
    let pi_session_dir = pi_history_session_dir(params, &home, home_override.is_none());
    match adapter {
        HistoryAdapter::Codex => roots(&[
            (home.join(".codex/history.jsonl"), "codex-prompt-history"),
            (
                home.join(".codex/session_index.jsonl"),
                "codex-session-index",
            ),
            (home.join(".codex/sessions"), "codex-session-store"),
            (
                home.join(".codex/archived_sessions"),
                "codex-archived-session-store",
            ),
            (home.join(".codex/memories/MEMORY.md"), "codex-memory"),
            (
                home.join(".codex/memories/rollout_summaries"),
                "codex-rollout-summary",
            ),
        ]),
        HistoryAdapter::Antigravity => roots(&[
            (
                home.join("Library/Application Support/Antigravity IDE"),
                "antigravity-ide-state",
            ),
            (appdata.join("Antigravity IDE"), "antigravity-ide-state"),
            (
                local_appdata.join("Antigravity IDE"),
                "antigravity-ide-state",
            ),
            (xdg_config.join("Antigravity IDE"), "antigravity-ide-state"),
            (home.join(".gemini/antigravity"), "antigravity-bridge"),
            (home.join(".gemini/antigravity-ide"), "antigravity-bridge"),
            (home.join(".gemini/antigravity-cli"), "antigravity-cli"),
        ]),
        HistoryAdapter::ClaudeCode => roots(&[
            (home.join(".claude/projects"), "claude-project-transcripts"),
            (home.join(".claude.json"), "claude-global-state"),
        ]),
        // Chats and projects carry the conversation working directory; scan them
        // before Application Support trees so the shared catalog walk budget is
        // not spent on agent-cli installs and checkpoint noise first.
        HistoryAdapter::Cursor => roots(&[
            (home.join(".cursor/chats"), "cursor-cli-chats"),
            (home.join(".cursor/projects"), "cursor-cli-projects"),
            (
                home.join("Library/Application Support/Cursor/User/workspaceStorage"),
                "cursor-workspace-storage",
            ),
            (
                home.join("Library/Application Support/Cursor/User/globalStorage"),
                "cursor-global-storage",
            ),
            (
                appdata.join("Cursor/User/workspaceStorage"),
                "cursor-workspace-storage",
            ),
            (
                appdata.join("Cursor/User/globalStorage"),
                "cursor-global-storage",
            ),
            (
                xdg_config.join("Cursor/User/workspaceStorage"),
                "cursor-workspace-storage",
            ),
            (
                xdg_config.join("Cursor/User/globalStorage"),
                "cursor-global-storage",
            ),
        ]),
        HistoryAdapter::Code => roots(&[
            (
                home.join("Library/Application Support/Code/User/workspaceStorage"),
                "vscode-workspace-storage",
            ),
            (
                home.join("Library/Application Support/Code/User/globalStorage"),
                "vscode-global-storage",
            ),
            (
                appdata.join("Code/User/workspaceStorage"),
                "vscode-workspace-storage",
            ),
            (
                appdata.join("Code/User/globalStorage"),
                "vscode-global-storage",
            ),
            (
                xdg_config.join("Code/User/workspaceStorage"),
                "vscode-workspace-storage",
            ),
            (
                xdg_config.join("Code/User/globalStorage"),
                "vscode-global-storage",
            ),
        ]),
        HistoryAdapter::Copilot => roots(&[
            (
                copilot_home.join("session-state"),
                "copilot-cli-session-store",
            ),
            (
                home.join("Library/Application Support/Code/User/workspaceStorage"),
                "vscode-copilot-workspace-storage",
            ),
            (
                home.join("Library/Application Support/Code/User/globalStorage"),
                "vscode-copilot-global-storage",
            ),
            (
                appdata.join("Code/User/workspaceStorage"),
                "vscode-copilot-workspace-storage",
            ),
            (
                appdata.join("Code/User/globalStorage"),
                "vscode-copilot-global-storage",
            ),
            (
                xdg_config.join("Code/User/workspaceStorage"),
                "vscode-copilot-workspace-storage",
            ),
            (
                xdg_config.join("Code/User/globalStorage"),
                "vscode-copilot-global-storage",
            ),
        ]),
        HistoryAdapter::KiloCode => roots(&[
            (
                home.join(".local/share/kilo/kilo.db"),
                "kilo-session-database",
            ),
            (
                home.join(".local/share/kilo/storage/session_diff"),
                "kilo-session-diff",
            ),
            (
                home.join(".local/share/kilo/storage/session_share"),
                "kilo-session-share",
            ),
            (home.join(".local/share/kilo/log"), "kilo-log"),
            (home.join(".config/kilo"), "kilo-config"),
            (appdata.join("kilo"), "kilo-appdata"),
            (xdg_data.join("kilo"), "kilo-data"),
        ]),
        HistoryAdapter::OpenCode => roots(&[
            (home.join(".config/opencode"), "opencode-config"),
            (home.join(".local/share/opencode"), "opencode-data"),
            (appdata.join("opencode"), "opencode-appdata"),
            (xdg_data.join("opencode"), "opencode-data"),
        ]),
        HistoryAdapter::OpenClaw => roots(&[
            (home.join(".openclaw"), "openclaw-home"),
            (home.join(".config/openclaw"), "openclaw-config"),
            (appdata.join("OpenClaw"), "openclaw-appdata"),
            (xdg_config.join("openclaw"), "openclaw-config"),
        ]),
        HistoryAdapter::Hermes => roots(&[
            (home.join(".hermes"), "hermes-home"),
            (home.join(".config/hermes"), "hermes-config"),
            (appdata.join("Hermes"), "hermes-appdata"),
            (xdg_config.join("hermes"), "hermes-config"),
        ]),
        HistoryAdapter::Kimi => roots(&[
            (
                home.join("Library/Application Support/Kimi"),
                "kimi-app-state",
            ),
            (
                home.join("Library/Application Support/com.moonshot.kimi"),
                "kimi-app-state",
            ),
            (home.join("Library/Logs/Kimi"), "kimi-log"),
            (appdata.join("Kimi"), "kimi-appdata"),
            (appdata.join("com.moonshot.kimi"), "kimi-appdata"),
            (local_appdata.join("Kimi"), "kimi-local-appdata"),
            (xdg_config.join("Kimi"), "kimi-config"),
            (xdg_data.join("Kimi"), "kimi-data"),
        ]),
        HistoryAdapter::KimiCode => {
            roots(&[(kimi_code_home.join("sessions"), "kimi-code-session-store")])
        }
        HistoryAdapter::Pi => roots(&[(pi_session_dir, "pi-session-store")]),
        HistoryAdapter::LicoAgent => lico_agent_history_roots(params),
    }
}

fn lico_agent_history_roots(params: &Value) -> Vec<HistoryRoot> {
    lico_agent_session_dir(params)
        .map(|dir| roots(&[(dir, "lico-agent-session-store")]))
        .unwrap_or_default()
}

fn lico_agent_session_dir(params: &Value) -> Option<PathBuf> {
    text_param(params, &["licoAgentSessionDir", "licoAgentSessionsDir"])
        .filter(|value| !value.trim().is_empty())
        .map(|value| expand_home(&value))
        .or_else(|| {
            portable_data_dir()
                .ok()
                .map(|portable| portable.join("client-state/lico-agent/sessions"))
        })
}

fn kimi_code_history_home(params: &Value, home: &Path, allow_environment: bool) -> PathBuf {
    let configured = text_param(params, &["kimiCodeHome"]).or_else(|| {
        allow_environment
            .then(|| env::var("KIMI_CODE_HOME").ok())
            .flatten()
    });
    configured
        .map(|value| expand_home_from(&value, || home.to_path_buf()))
        .unwrap_or_else(|| home.join(".kimi-code"))
}

fn copilot_history_home(params: &Value, home: &Path, allow_environment: bool) -> PathBuf {
    let configured = text_param(params, &["copilotHome"]).or_else(|| {
        allow_environment
            .then(|| env::var("COPILOT_HOME").ok())
            .flatten()
    });
    configured
        .map(|value| expand_home_from(&value, || home.to_path_buf()))
        .unwrap_or_else(|| home.join(".copilot"))
}

fn pi_history_session_dir(params: &Value, home: &Path, allow_environment: bool) -> PathBuf {
    let configured =
        text_param(params, &["piSessionDir", "piCodingAgentSessionDir"]).or_else(|| {
            allow_environment
                .then(|| env::var("PI_CODING_AGENT_SESSION_DIR").ok())
                .flatten()
        });
    configured
        .map(|value| expand_home_from(&value, || home.to_path_buf()))
        .unwrap_or_else(|| home.join(".pi/agent/sessions"))
}

fn roots(items: &[(PathBuf, &'static str)]) -> Vec<HistoryRoot> {
    items
        .iter()
        .map(|(path, source_kind)| HistoryRoot {
            path: path.clone(),
            source_kind: source_kind.to_string(),
        })
        .collect()
}

fn looks_like_history_text(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    lower.contains("assistant")
        || lower.contains("user")
        || lower.contains("prompt")
        || lower.contains("message")
        || lower.contains("conversation")
        || lower.contains("chat")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn aliases_and_root_overrides_resolve_in_the_catalog() {
        assert_eq!(adapter_for_agent("vscode"), Some(HistoryAdapter::Code));
        assert_eq!(
            adapter_for_agent("kimi_code"),
            Some(HistoryAdapter::KimiCode)
        );

        let history_root = PathBuf::from("test-data").join("history");
        let roots = history_roots(
            HistoryAdapter::Codex,
            &json!({"historyRoot": history_root, "rootKind": "fixture"}),
        );
        assert_eq!(roots.len(), 1);
        assert_eq!(roots[0].path, history_root);
        assert_eq!(roots[0].source_kind, "fixture");
    }

    #[test]
    fn sqlite_catalog_rejects_indexes_and_account_tables() {
        assert!(!HistoryAdapter::Cursor.sqlite_table_may_hold_history("chat_fts"));
        assert!(!HistoryAdapter::KiloCode.sqlite_table_may_hold_history("account"));
        assert!(HistoryAdapter::Code.sqlite_table_may_hold_history("ItemTable"));
    }

    #[test]
    fn catalog_includes_cli_usage_stores_without_overlapping_pi_roots() {
        let home = PathBuf::from("synthetic-home");
        let params = json!({"homeDir": home});

        let antigravity = history_roots(HistoryAdapter::Antigravity, &params);
        assert!(antigravity.iter().any(|root| {
            root.source_kind == "antigravity-cli"
                && root.path == home.join(".gemini/antigravity-cli")
        }));

        let copilot = history_roots(HistoryAdapter::Copilot, &params);
        assert!(copilot.iter().any(|root| {
            root.source_kind == "copilot-cli-session-store"
                && root.path == home.join(".copilot/session-state")
        }));

        let pi = history_roots(HistoryAdapter::Pi, &params);
        assert_eq!(pi.len(), 1);
        assert_eq!(pi[0].path, home.join(".pi/agent/sessions"));

        let lico_override = json!({"licoAgentSessionDir": "/tmp/lico-agent-sessions"});
        let lico = history_roots(HistoryAdapter::LicoAgent, &lico_override);
        assert_eq!(lico.len(), 1);
        assert_eq!(lico[0].path, PathBuf::from("/tmp/lico-agent-sessions"));
        assert_eq!(lico[0].source_kind, "lico-agent-session-store");
        assert_eq!(
            adapter_for_agent("lico-agent"),
            Some(HistoryAdapter::LicoAgent)
        );
        assert_eq!(adapter_for_agent("lico"), Some(HistoryAdapter::LicoAgent));
    }
}
