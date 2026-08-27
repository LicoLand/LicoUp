pub(in crate::platform) mod approval;
pub(in crate::platform) mod command;
mod control;
pub(in crate::platform) mod errors;
mod execution;
mod io;
pub(in crate::platform) mod model;
pub(in crate::platform) mod params;
mod probe;
mod supervision;
mod transport;
#[cfg(test)]
pub(super) use super::conversation_lane;
pub(super) use control::ControlDisposition;
#[allow(unused_imports)]
pub(super) use errors::ProtocolFailure;
pub(super) use execution::execute;
#[allow(unused_imports)]
pub(super) use model::{
    CapabilityProbe, CompleteTranscript, EffectiveSettings, RUNTIME_PROTOCOL, RunResult,
    TransportLifecycle,
};
pub(super) use probe::probe;
pub(super) use supervision::{cancel, cleanup_session, history, steer};
#[cfg(test)]
mod tests;
