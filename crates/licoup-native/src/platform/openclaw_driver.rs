//! The OpenClaw driver, composed from the OpenClaw adapter package.
//!
//! The protocol vocabulary this driver speaks — the Gateway ACP state machine,
//! the byte-line codec that classifies one frame exactly once, the allowlisted
//! update projection, the session continuity binding, the run and failure
//! vocabulary, and the request validation — belongs to OpenClaw and lives in
//! `licoup-agent-openclaw` now. It is re-exported here at its former paths so
//! the driver leaves below keep reading it, and so the client carries one copy
//! of the vocabulary rather than two.
//!
//! What is still composed by the client is the *process* half: probing the
//! selected executable's bounded capability, resolving the Gateway attach
//! endpoint, spawning the ACP bridge, reading its framed lines, supervising the
//! turn, and answering control requests. That half moves to the package next,
//! through the agent-execution port the package declares; until it does, the
//! client reads the protocol from the package and owns only the process. The
//! reviewed process sites in this half are untouched, which is why the probe and
//! supervision leaves are still the reviewed source byte for byte.

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
