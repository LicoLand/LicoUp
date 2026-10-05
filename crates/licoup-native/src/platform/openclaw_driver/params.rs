//! One validated OpenClaw request, answered for the client's MCP registration.
//!
//! Which parameters this Agent accepts, which it refuses with a typed failure,
//! and how a private prompt stays out of launch arguments are OpenClaw's facts,
//! so the validation lives in `licoup-agent-openclaw` now and is re-exported
//! here at its former path.
//!
//! What stays here is the one fact the package may not reach: *which* MCP
//! servers this client registers for an OpenClaw turn. That is read from the
//! user's collaboration-plugin configuration and the installed package store,
//! so this module supplies it to the package's validation — as a lazy answer,
//! exactly as before, so a request the package refuses never consults the
//! client's plugin configuration.

use super::errors::ProtocolFailure;
use serde_json::Value;
use std::path::Path;

#[allow(unused_imports)]
pub(in crate::platform) use licoup_agent_openclaw::gateway_acp::params::{
    ProtocolConfig, normalize_agent_id, text_param,
};

/// Validate one OpenClaw request, answering the client's MCP registration.
///
/// This is the client's entry point, and it keeps the order the driver has
/// always used: the package validates every request field first and asks for
/// the registration only once the request has been accepted.
pub(in crate::platform) fn from_params(
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
) -> Result<ProtocolConfig, ProtocolFailure> {
    ProtocolConfig::from_params(params, prompt, session_id, cwd, || {
        crate::domain::collaboration_plugin::acp_servers_for_runtime("openclaw").map_err(|_| {
            ProtocolFailure::new(
                "openclaw_acp_mcp_registration_invalid",
                "The optional MCP registration could not be validated safely.",
                "session/mcp",
            )
        })
    })
}
