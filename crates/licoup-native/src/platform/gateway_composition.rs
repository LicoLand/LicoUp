//! Gateway sidecar composition: this host's answers for the runtime ports.
//!
//! The Gateway Runtime process (`lico-gateway`) never links conversation or
//! custody internals. It asks the ports below; this composition supplies the
//! verified lane answers, the credential handoff lease and the readiness
//! callback once per process.

use anyhow::{Result, anyhow};
use licoup_gateway_core::credentials::llm_api_key_vault::{
    GatewayCredentialHandoff, GatewayCredentialLease,
};
use licoup_gateway_core::ports::lane::{self, LanePort};
use licoup_gateway_core::ports::readiness;
use licoup_gateway_core::ports::vault::{self, GatewayVaultPort};
use serde_json::Value;
use std::sync::Arc;

use super::llm_api_key_vault::PlatformLlmApiKeyVault;

struct ProductionGatewayVault {
    vault: PlatformLlmApiKeyVault,
}

impl GatewayVaultPort for ProductionGatewayVault {
    fn lease_from_handoff(
        &self,
        handoff: GatewayCredentialHandoff,
    ) -> Result<GatewayCredentialLease> {
        self.vault.gateway_lease_from_handoff(handoff)
    }
}

fn dispatch_lane(operation: &str, params: &Value) -> Result<Value> {
    super::dispatch_lane_operation(operation, params)
        .map_err(|error| anyhow!("gateway_lane_dispatch_failed:{error}"))
}

/// Install every port the Gateway Runtime consumes.
pub fn install() -> Result<(), &'static str> {
    readiness::install(super::runtime_adapters::reload_conversation_readiness_document)?;
    lane::install(LanePort {
        scan_targets: super::conversation_lane::lane_target_scan,
        conversation_list: super::conversation_lane::lane_conversation_list,
        open_or_resume: super::open_or_resume,
        dispatch: dispatch_lane,
    })?;
    let vault = PlatformLlmApiKeyVault::production().map_err(|_| "gateway_vault_unavailable")?;
    vault::install(Arc::new(ProductionGatewayVault { vault }))?;
    Ok(())
}

/// Install the readiness callback alone; the client that manages a gateway
/// still applies and validates pushed readiness without dispatching lanes.
pub fn install_readiness() -> Result<(), &'static str> {
    readiness::install(super::runtime_adapters::reload_conversation_readiness_document)
}
