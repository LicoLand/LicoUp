//! Antigravity user MCP registration through the common digest-bound manager.

use super::provider_mcp_registration::{
    ProviderConfigKind, RegistrationError, RegistrationPermit, RegistrationPlan,
};
use crate::domain::integration_state::IntegrationState;
use std::path::{Path, PathBuf};

const PLUGIN_VERSION: &str = "0.2.0";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AntigravitySubagentMcpError {
    NotAntigravity,
    InvalidMcpBinary,
    ApprovalRequired,
    ApprovalMismatch,
    ApprovalConsumed,
    ConfigUnavailable,
    ConfigAmbiguous,
    ConfigPathUnsupported,
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
            Self::ConfigAmbiguous => "antigravity_subagent_mcp_config_ambiguous",
            Self::ConfigPathUnsupported => "antigravity_subagent_mcp_config_path_unsupported",
            Self::InstallFailed => "antigravity_subagent_mcp_install_failed",
        }
    }
}

#[derive(Clone, Debug)]
pub struct AntigravitySubagentMcpPlan {
    inner: RegistrationPlan,
}

impl AntigravitySubagentMcpPlan {
    pub fn prepare(
        main_agent_id: &str,
        connector: &Path,
    ) -> Result<Self, AntigravitySubagentMcpError> {
        if main_agent_id != "antigravity" {
            return Err(AntigravitySubagentMcpError::NotAntigravity);
        }
        Ok(Self {
            inner: RegistrationPlan::prepare(ProviderConfigKind::Antigravity, connector)
                .map_err(map_error)?,
        })
    }

    /// Plan against one explicitly discovered Antigravity config path. Only a
    /// canonical reviewed official or legacy candidate is admitted, and the
    /// selected path plus the current config bytes are bound into the approval
    /// digest. The default both-present resolution stays fail-closed.
    pub fn prepare_with_config_path(
        main_agent_id: &str,
        connector: &Path,
        config_path: &Path,
    ) -> Result<Self, AntigravitySubagentMcpError> {
        if main_agent_id != "antigravity" {
            return Err(AntigravitySubagentMcpError::NotAntigravity);
        }
        Ok(Self {
            inner: RegistrationPlan::prepare_with_config_path(
                ProviderConfigKind::Antigravity,
                connector,
                config_path,
            )
            .map_err(map_error)?,
        })
    }

    pub fn digest(&self) -> &str {
        self.inner.digest()
    }

    pub const fn version() -> &'static str {
        PLUGIN_VERSION
    }

    pub const fn source() -> &'static str {
        "LicoUp managed user MCP registration"
    }

    pub fn approve(
        &self,
        confirmed: bool,
        digest: &str,
    ) -> Result<AntigravitySubagentMcpPermit, AntigravitySubagentMcpError> {
        self.inner
            .approve(confirmed, digest)
            .map(|inner| AntigravitySubagentMcpPermit { inner })
            .map_err(map_error)
    }
}

pub struct AntigravitySubagentMcpPermit {
    inner: RegistrationPermit,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AntigravitySubagentMcpReceipt {
    pub installed: bool,
    pub plugin_ready_for_new_conversations: bool,
}

pub fn status(connector: &Path) -> IntegrationState {
    match super::provider_mcp_registration::status(ProviderConfigKind::Antigravity, connector) {
        Ok(true) => IntegrationState::Ready,
        Ok(false) => IntegrationState::Missing,
        Err(_) => IntegrationState::Unavailable,
    }
}

/// Read-only readiness probe at one explicitly discovered config path.
pub fn status_with_config_path(connector: &Path, config_path: &Path) -> IntegrationState {
    match super::provider_mcp_registration::status_with_config_path(
        ProviderConfigKind::Antigravity,
        connector,
        config_path,
    ) {
        Ok(true) => IntegrationState::Ready,
        Ok(false) => IntegrationState::Missing,
        Err(_) => IntegrationState::Unavailable,
    }
}

pub fn install(
    plan: &AntigravitySubagentMcpPlan,
    permit: &mut AntigravitySubagentMcpPermit,
) -> Result<AntigravitySubagentMcpReceipt, AntigravitySubagentMcpError> {
    super::provider_mcp_registration::install(&plan.inner, &mut permit.inner).map_err(map_error)?;
    Ok(AntigravitySubagentMcpReceipt {
        installed: true,
        plugin_ready_for_new_conversations: true,
    })
}

pub fn remove(
    plan: &AntigravitySubagentMcpPlan,
    permit: &mut AntigravitySubagentMcpPermit,
) -> Result<(), AntigravitySubagentMcpError> {
    super::provider_mcp_registration::remove(&plan.inner, &mut permit.inner).map_err(map_error)
}

fn map_error(error: RegistrationError) -> AntigravitySubagentMcpError {
    match error {
        RegistrationError::InvalidConnector => AntigravitySubagentMcpError::InvalidMcpBinary,
        RegistrationError::ApprovalRequired => AntigravitySubagentMcpError::ApprovalRequired,
        RegistrationError::ApprovalMismatch | RegistrationError::ConfigChanged => {
            AntigravitySubagentMcpError::ApprovalMismatch
        }
        RegistrationError::ApprovalConsumed => AntigravitySubagentMcpError::ApprovalConsumed,
        RegistrationError::ConfigAmbiguous | RegistrationError::OwnedEntryAmbiguous => {
            AntigravitySubagentMcpError::ConfigAmbiguous
        }
        RegistrationError::ConfigPathUnsupported => {
            AntigravitySubagentMcpError::ConfigPathUnsupported
        }
        RegistrationError::ConfigUnavailable => AntigravitySubagentMcpError::ConfigUnavailable,
        RegistrationError::WriteFailed => AntigravitySubagentMcpError::InstallFailed,
    }
}

/// Resolve the packaged thin connector next to the running native binary.
pub fn default_mcp_binary_path() -> Option<PathBuf> {
    let directory = std::env::current_exe().ok()?.parent()?.to_path_buf();
    let connector = directory.join(format!("lico-subagent-mcp{}", std::env::consts::EXE_SUFFIX));
    connector.is_file().then_some(connector)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_antigravity_selection_fails_before_config_access() {
        assert_eq!(
            AntigravitySubagentMcpPlan::prepare("cursor", Path::new("connector")).unwrap_err(),
            AntigravitySubagentMcpError::NotAntigravity
        );
    }
}
