mod codec;
mod continuity;
mod errors;
mod events;
mod execution;
mod io;
mod model;
mod params;
mod probe;
mod protocol;
mod supervision;

#[allow(unused_imports)]
pub(super) use errors::ProtocolFailure;
pub(super) use execution::execute;
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
