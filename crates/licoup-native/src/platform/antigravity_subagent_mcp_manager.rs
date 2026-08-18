//! Digest-confirmed registration of Subagent MCP into Antigravity mcp_config.

use crate::domain::integration_state::IntegrationState;
use crate::platform::paths::user_home_from_env;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

const SERVER_KEY: &str = "lico-up-subagent";
const INSTALL_SCHEMA: &str = "licoup.antigravity-subagent-mcp-install.v1";
const PLUGIN_VERSION: &str = "0.1.0";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AntigravitySubagentMcpError {
    NotAntigravity,
    InvalidMcpBinary,
    ApprovalRequired,
    ApprovalMismatch,
    ApprovalConsumed,
    ConfigUnavailable,
    InstallFailed,
}

impl AntigravitySubagentMcpError {
    pub const fn code(self) -> &'static str {
        match self {
            Self::NotAntigravity => "antigravity_subagent_mcp_not_applicable",
            Self::InvalidMcpBinary => "antigravity_subagent_mcp_binary_invalid",
            Self::ApprovalRequired => "antigravity_subagent_mcp_approval_required",
            Self::ApprovalMismatch => "antigravity_subagent_mcp_approval_mismatch",
            Self::ApprovalConsumed => "antigravity_subagent_mcp_approval_consumed",
            Self::ConfigUnavailable => "antigravity_subagent_mcp_config_unavailable",
            Self::InstallFailed => "antigravity_subagent_mcp_install_failed",
        }
    }
}

#[derive(Clone, Debug)]
pub struct AntigravitySubagentMcpPlan {
    mcp_binary: PathBuf,
    config_path: PathBuf,
    digest: String,
}

impl AntigravitySubagentMcpPlan {
    pub fn prepare(
        main_agent_id: &str,
        mcp_binary: &Path,
    ) -> Result<Self, AntigravitySubagentMcpError> {
        if main_agent_id != "antigravity" {
            return Err(AntigravitySubagentMcpError::NotAntigravity);
        }
        let mcp_binary = canonical_executable(mcp_binary)?;
        let config_path =
            antigravity_mcp_config_path().ok_or(AntigravitySubagentMcpError::ConfigUnavailable)?;
        Ok(Self {
            digest: release_digest(&mcp_binary),
            mcp_binary,
            config_path,
        })
    }

    pub fn digest(&self) -> &str {
        &self.digest
    }

    pub fn config_path(&self) -> &Path {
        &self.config_path
    }

    pub fn mcp_binary(&self) -> &Path {
        &self.mcp_binary
    }

    pub const fn version() -> &'static str {
        PLUGIN_VERSION
    }

    pub const fn source() -> &'static str {
        "LicoUp packaged lico-subagent-mcp"
    }

    pub fn approve(
        &self,
        confirmed: bool,
        expected_digest: &str,
    ) -> Result<AntigravitySubagentMcpPermit, AntigravitySubagentMcpError> {
        if !confirmed {
            return Err(AntigravitySubagentMcpError::ApprovalRequired);
        }
        if expected_digest != self.digest {
            return Err(AntigravitySubagentMcpError::ApprovalMismatch);
        }
        Ok(AntigravitySubagentMcpPermit {
            digest: self.digest.clone(),
            consumed: false,
        })
    }
}

#[derive(Debug)]
pub struct AntigravitySubagentMcpPermit {
    digest: String,
    consumed: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AntigravitySubagentMcpReceipt {
    pub installed: bool,
    pub plugin_ready_for_new_conversations: bool,
}

pub fn status(mcp_binary: &Path) -> IntegrationState {
    let Ok(mcp_binary) = canonical_executable(mcp_binary) else {
        return IntegrationState::Unavailable;
    };
    let Some(config_path) = antigravity_mcp_config_path() else {
        return IntegrationState::Unavailable;
    };
    match read_config(&config_path) {
        Ok(config) => {
            if entry_is_ready(&config, &mcp_binary) {
                IntegrationState::Ready
            } else {
                IntegrationState::Missing
            }
        }
        Err(_) => {
            if config_path.exists() {
                IntegrationState::Unavailable
            } else {
                IntegrationState::Missing
            }
        }
    }
}

pub fn install(
    plan: &AntigravitySubagentMcpPlan,
    permit: &mut AntigravitySubagentMcpPermit,
) -> Result<AntigravitySubagentMcpReceipt, AntigravitySubagentMcpError> {
    if permit.consumed {
        return Err(AntigravitySubagentMcpError::ApprovalConsumed);
    }
    permit.consumed = true;
    if permit.digest != plan.digest || release_digest(&plan.mcp_binary) != plan.digest {
        return Err(AntigravitySubagentMcpError::ApprovalMismatch);
    }
    let mut config = if plan.config_path.exists() {
        read_config(&plan.config_path)?
    } else {
        json!({ "mcpServers": {} })
    };
    let servers = config
        .as_object_mut()
        .ok_or(AntigravitySubagentMcpError::InstallFailed)?
        .entry("mcpServers")
        .or_insert_with(|| json!({}));
    let servers = servers
        .as_object_mut()
        .ok_or(AntigravitySubagentMcpError::InstallFailed)?;
    servers.insert(
        SERVER_KEY.to_owned(),
        json!({
            "command": plan.mcp_binary.to_string_lossy(),
            "args": [],
            "env": {
                "LICOUP_MAIN_AGENT_ID": "antigravity"
            },
            "disabled": false
        }),
    );
    write_config(&plan.config_path, &config)?;
    if !entry_is_ready(&config, &plan.mcp_binary) {
        return Err(AntigravitySubagentMcpError::InstallFailed);
    }
    Ok(AntigravitySubagentMcpReceipt {
        installed: true,
        plugin_ready_for_new_conversations: true,
    })
}

/// Official Antigravity CLI/IDE global MCP config, with legacy bridge fallback.
pub fn antigravity_mcp_config_path() -> Option<PathBuf> {
    let home = user_home_from_env()?;
    let official = home.join(".gemini").join("config").join("mcp_config.json");
    let legacy = home
        .join(".gemini")
        .join("antigravity")
        .join("mcp_config.json");
    if official.exists() {
        return Some(official);
    }
    if legacy.exists() {
        return Some(legacy);
    }
    Some(official)
}

fn release_digest(mcp_binary: &Path) -> String {
    let mut digest = Sha256::new();
    digest.update(INSTALL_SCHEMA.as_bytes());
    digest.update([0]);
    digest.update(SERVER_KEY.as_bytes());
    digest.update([0]);
    digest.update(PLUGIN_VERSION.as_bytes());
    digest.update([0]);
    digest.update(mcp_binary.to_string_lossy().as_bytes());
    format!("{:x}", digest.finalize())
}

fn canonical_executable(path: &Path) -> Result<PathBuf, AntigravitySubagentMcpError> {
    let path = fs::canonicalize(path).map_err(|_| AntigravitySubagentMcpError::InvalidMcpBinary)?;
    if !path.is_file() {
        return Err(AntigravitySubagentMcpError::InvalidMcpBinary);
    }
    Ok(path)
}

fn read_config(path: &Path) -> Result<Value, AntigravitySubagentMcpError> {
    let raw =
        fs::read_to_string(path).map_err(|_| AntigravitySubagentMcpError::ConfigUnavailable)?;
    serde_json::from_str(&raw).map_err(|_| AntigravitySubagentMcpError::ConfigUnavailable)
}

fn write_config(path: &Path, value: &Value) -> Result<(), AntigravitySubagentMcpError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|_| AntigravitySubagentMcpError::InstallFailed)?;
    }
    let body =
        serde_json::to_vec_pretty(value).map_err(|_| AntigravitySubagentMcpError::InstallFailed)?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, body).map_err(|_| AntigravitySubagentMcpError::InstallFailed)?;
    fs::rename(&tmp, path).map_err(|_| AntigravitySubagentMcpError::InstallFailed)?;
    Ok(())
}

fn entry_is_ready(config: &Value, mcp_binary: &Path) -> bool {
    let Some(entry) = config
        .get("mcpServers")
        .and_then(Value::as_object)
        .and_then(|servers| servers.get(SERVER_KEY))
        .and_then(Value::as_object)
    else {
        return false;
    };
    if entry
        .get("disabled")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return false;
    }
    let command = entry.get("command").and_then(Value::as_str).unwrap_or("");
    if command.is_empty() {
        return false;
    }
    let command_path = Path::new(command);
    let Ok(canonical_command) = fs::canonicalize(command_path) else {
        return command_path == mcp_binary;
    };
    let Ok(canonical_binary) = fs::canonicalize(mcp_binary) else {
        return false;
    };
    if canonical_command != canonical_binary {
        return false;
    }
    entry
        .get("env")
        .and_then(Value::as_object)
        .and_then(|env| env.get("LICOUP_MAIN_AGENT_ID"))
        .and_then(Value::as_str)
        == Some("antigravity")
}

/// Resolve packaged `lico-subagent-mcp` next to the running CLI/native binary.
pub fn default_mcp_binary_path() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let candidate = dir.join("lico-subagent-mcp");
    if candidate.is_file() {
        return Some(candidate);
    }
    #[cfg(target_os = "windows")]
    {
        let candidate = dir.join("lico-subagent-mcp.exe");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entry_ready_preserves_other_servers() {
        let root = std::env::temp_dir().join(format!(
            "licoup-agy-mcp-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let binary = root.join("lico-subagent-mcp");
        fs::write(&binary, b"bin").unwrap();
        let mut config = json!({ "mcpServers": { "other": { "command": "echo" } } });
        config
            .as_object_mut()
            .unwrap()
            .get_mut("mcpServers")
            .unwrap()
            .as_object_mut()
            .unwrap()
            .insert(
                SERVER_KEY.to_owned(),
                json!({
                    "command": binary.to_string_lossy(),
                    "args": [],
                    "env": { "LICOUP_MAIN_AGENT_ID": "antigravity" },
                    "disabled": false
                }),
            );
        assert!(entry_is_ready(&config, &binary));
        assert!(
            config["mcpServers"]
                .as_object()
                .unwrap()
                .contains_key("other")
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn digest_requires_confirmation_match() {
        let binary = std::env::temp_dir().join(format!(
            "licoup-agy-mcp-bin-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        fs::write(&binary, b"bin").unwrap();
        let plan = AntigravitySubagentMcpPlan {
            mcp_binary: binary.clone(),
            config_path: std::env::temp_dir().join("mcp_config.json"),
            digest: release_digest(&binary),
        };
        assert!(matches!(
            plan.approve(false, plan.digest()),
            Err(AntigravitySubagentMcpError::ApprovalRequired)
        ));
        assert!(matches!(
            plan.approve(true, "nope"),
            Err(AntigravitySubagentMcpError::ApprovalMismatch)
        ));
        assert!(plan.approve(true, plan.digest()).is_ok());
        let _ = fs::remove_file(&binary);
    }
}
