#[path = "native_agent_parser/adapters/openclaw/codec.rs"]
mod codec;
mod continuity;
mod errors;
#[path = "native_agent_parser/adapters/openclaw/events.rs"]
mod events;
mod execution;
mod io;
mod model;
mod params;
mod probe;
#[path = "native_agent_parser/adapters/openclaw/protocol.rs"]
mod protocol;
mod supervision;

#[allow(unused_imports)]
pub(super) use errors::ProtocolFailure;
pub(super) use execution::execute_with_connection;
#[allow(unused_imports)]
pub(super) use model::{CapabilityProbe, EffectiveSettings, RUNTIME_PROTOCOL, RunResult};
pub(super) use probe::probe;

pub(in crate::platform) fn cancel(
    session_id: &str,
) -> super::acp_driver_runtime::ControlDisposition {
    super::acp_driver_runtime::cancel_active_turn("openclaw-acp", session_id)
}

#[cfg(test)]
mod tests;
