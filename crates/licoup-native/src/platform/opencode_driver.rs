mod continuity;
mod control;
mod probe;
mod serve_transport;

use super::acp_driver_runtime::{AcpDriverSpec, CapabilityProbe};
pub(super) const RUNTIME_PROTOCOL: &str = "opencode-serve-http-v1";
pub(super) const OPENCODE_DRIVER: AcpDriverSpec = AcpDriverSpec::new(RUNTIME_PROTOCOL, &["serve"])
    .with_identity("opencode-serve", "opencode_serve");

pub(in crate::platform) use control::cancel;
pub(super) use control::serve_capabilities;
pub(super) use probe::capability_probe;
pub(super) use serve_transport::execute;

#[cfg(test)]
mod tests;
