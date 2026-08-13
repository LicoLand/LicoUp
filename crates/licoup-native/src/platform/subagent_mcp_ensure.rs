//! Agent-agnostic Subagent MCP status/plan/install dispatcher.

use crate::platform::codex_plugin_manager::CodexPluginState;
use crate::platform::{antigravity_subagent_mcp_manager, codex_plugin_manager};
use std::path::Path;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SubagentMcpEnsureState {
    Ready,
    Missing,
    Unavailable,
    Unsupported,
}

impl SubagentMcpEnsureState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Missing => "missing",
            Self::Unavailable => "unavailable",
            Self::Unsupported => "unsupported",
        }
    }

    pub const fn ready(self) -> bool {
        matches!(self, Self::Ready)
    }
}

#[derive(Clone, Debug)]
pub struct SubagentMcpEnsurePlan {
    pub agent_id: String,
    pub digest: String,
    pub plugin_version: String,
    pub source: String,
    pub release: String,
    pub requires_confirmation: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SubagentMcpEnsureError {
    Unsupported,
    ApprovalRequired,
    ApprovalMismatch,
    ApprovalConsumed,
    InvalidBinary,
    InstallFailed,
    ProcessUnavailable,
}

impl SubagentMcpEnsureError {
    pub const fn code(self) -> &'static str {
        match self {
            Self::Unsupported => "subagent_mcp_unsupported",
            Self::ApprovalRequired => "subagent_mcp_approval_required",
            Self::ApprovalMismatch => "subagent_mcp_approval_mismatch",
            Self::ApprovalConsumed => "subagent_mcp_approval_consumed",
            Self::InvalidBinary => "subagent_mcp_binary_invalid",
            Self::InstallFailed => "subagent_mcp_install_failed",
            Self::ProcessUnavailable => "subagent_mcp_process_unavailable",
        }
    }
}

pub fn status(
    agent_id: &str,
    binary_path: Option<&Path>,
    mcp_binary_path: Option<&Path>,
) -> SubagentMcpEnsureState {
    match agent_id {
        "codex" => {
            let Some(path) = binary_path else {
                return SubagentMcpEnsureState::Unavailable;
            };
            match codex_plugin_manager::status(path) {
                CodexPluginState::Ready => SubagentMcpEnsureState::Ready,
                CodexPluginState::Missing => SubagentMcpEnsureState::Missing,
                CodexPluginState::Unavailable => SubagentMcpEnsureState::Unavailable,
            }
        }
        "antigravity" => {
            let owned = mcp_binary_path
                .map(Path::to_path_buf)
                .or_else(antigravity_subagent_mcp_manager::default_mcp_binary_path);
            let Some(path) = owned else {
                return SubagentMcpEnsureState::Unavailable;
            };
            match antigravity_subagent_mcp_manager::status(&path) {
                CodexPluginState::Ready => SubagentMcpEnsureState::Ready,
                CodexPluginState::Missing => SubagentMcpEnsureState::Missing,
                CodexPluginState::Unavailable => SubagentMcpEnsureState::Unavailable,
            }
        }
        _ => SubagentMcpEnsureState::Unsupported,
    }
}

pub fn plan(
    agent_id: &str,
    binary_path: Option<&Path>,
    mcp_binary_path: Option<&Path>,
) -> Result<SubagentMcpEnsurePlan, SubagentMcpEnsureError> {
    match agent_id {
        "codex" => {
            let path = binary_path.ok_or(SubagentMcpEnsureError::InvalidBinary)?;
            let plan = codex_plugin_manager::CodexPluginInstallPlan::prepare("codex", path)
                .map_err(map_codex_error)?;
            Ok(SubagentMcpEnsurePlan {
                agent_id: agent_id.to_owned(),
                digest: plan.digest().to_owned(),
                plugin_version: codex_plugin_manager::CodexPluginInstallPlan::version().to_owned(),
                source: codex_plugin_manager::CodexPluginInstallPlan::source().to_owned(),
                release: codex_plugin_manager::CodexPluginInstallPlan::release().to_owned(),
                requires_confirmation: true,
            })
        }
        "antigravity" => {
            let path = mcp_binary_path
                .map(Path::to_path_buf)
                .or_else(antigravity_subagent_mcp_manager::default_mcp_binary_path)
                .ok_or(SubagentMcpEnsureError::InvalidBinary)?;
            let plan = antigravity_subagent_mcp_manager::AntigravitySubagentMcpPlan::prepare(
                "antigravity",
                &path,
            )
            .map_err(map_antigravity_error)?;
            Ok(SubagentMcpEnsurePlan {
                agent_id: agent_id.to_owned(),
                digest: plan.digest().to_owned(),
                plugin_version:
                    antigravity_subagent_mcp_manager::AntigravitySubagentMcpPlan::version()
                        .to_owned(),
                source: antigravity_subagent_mcp_manager::AntigravitySubagentMcpPlan::source()
                    .to_owned(),
                release: "packaged".to_owned(),
                requires_confirmation: true,
            })
        }
        _ => Err(SubagentMcpEnsureError::Unsupported),
    }
}

pub fn install(
    agent_id: &str,
    binary_path: Option<&Path>,
    mcp_binary_path: Option<&Path>,
    confirmation: &str,
    confirmed: bool,
) -> Result<(bool, bool), SubagentMcpEnsureError> {
    match agent_id {
        "codex" => {
            let path = binary_path.ok_or(SubagentMcpEnsureError::InvalidBinary)?;
            let plan = codex_plugin_manager::CodexPluginInstallPlan::prepare("codex", path)
                .map_err(map_codex_error)?;
            let mut permit = plan
                .approve(confirmed, confirmation)
                .map_err(map_codex_error)?;
            let receipt =
                codex_plugin_manager::install(&plan, &mut permit).map_err(map_codex_error)?;
            Ok((
                receipt.installed,
                receipt.plugin_ready_for_new_conversations,
            ))
        }
        "antigravity" => {
            let path = mcp_binary_path
                .map(Path::to_path_buf)
                .or_else(antigravity_subagent_mcp_manager::default_mcp_binary_path)
                .ok_or(SubagentMcpEnsureError::InvalidBinary)?;
            let plan = antigravity_subagent_mcp_manager::AntigravitySubagentMcpPlan::prepare(
                "antigravity",
                &path,
            )
            .map_err(map_antigravity_error)?;
            let mut permit = plan
                .approve(confirmed, confirmation)
                .map_err(map_antigravity_error)?;
            let receipt = antigravity_subagent_mcp_manager::install(&plan, &mut permit)
                .map_err(map_antigravity_error)?;
            Ok((
                receipt.installed,
                receipt.plugin_ready_for_new_conversations,
            ))
        }
        _ => Err(SubagentMcpEnsureError::Unsupported),
    }
}

fn map_codex_error(error: codex_plugin_manager::CodexPluginInstallError) -> SubagentMcpEnsureError {
    use codex_plugin_manager::CodexPluginInstallError::*;
    match error {
        NotCodex => SubagentMcpEnsureError::Unsupported,
        InvalidExecutable => SubagentMcpEnsureError::InvalidBinary,
        ApprovalRequired => SubagentMcpEnsureError::ApprovalRequired,
        ApprovalMismatch => SubagentMcpEnsureError::ApprovalMismatch,
        ApprovalConsumed => SubagentMcpEnsureError::ApprovalConsumed,
        ProcessUnavailable => SubagentMcpEnsureError::ProcessUnavailable,
        InstallFailed => SubagentMcpEnsureError::InstallFailed,
    }
}

fn map_antigravity_error(
    error: antigravity_subagent_mcp_manager::AntigravitySubagentMcpError,
) -> SubagentMcpEnsureError {
    use antigravity_subagent_mcp_manager::AntigravitySubagentMcpError::*;
    match error {
        NotAntigravity => SubagentMcpEnsureError::Unsupported,
        InvalidMcpBinary => SubagentMcpEnsureError::InvalidBinary,
        ApprovalRequired => SubagentMcpEnsureError::ApprovalRequired,
        ApprovalMismatch => SubagentMcpEnsureError::ApprovalMismatch,
        ApprovalConsumed => SubagentMcpEnsureError::ApprovalConsumed,
        ConfigUnavailable | InstallFailed => SubagentMcpEnsureError::InstallFailed,
    }
}
