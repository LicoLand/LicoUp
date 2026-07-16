mod continuity;
mod probe;
mod serve_transport;

use super::acp_driver_runtime::{AcpDriverSpec, CapabilityProbe};
pub(super) const RUNTIME_PROTOCOL: &str = "opencode-serve-http-v1";
pub(super) const OPENCODE_DRIVER: AcpDriverSpec = AcpDriverSpec::new(RUNTIME_PROTOCOL, &["serve"])
    .with_identity("opencode-serve", "opencode_serve");

pub(super) use probe::capability_probe;
pub(super) use serve_transport::execute;

pub(super) fn serve_capabilities() -> CapabilityProbe {
    CapabilityProbe {
        protocol_version: Some(u64::from(crate::core::acp::PROTOCOL_VERSION)),
        load_session: true,
        resume_session: true,
        close_session: true,
        list_sessions: true,
        delete_session: false,
        additional_directories: false,
        image_prompts: false,
        audio_prompts: false,
        embedded_context: false,
    }
}

#[cfg(test)]
mod tests;
