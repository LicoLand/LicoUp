mod active_control;
pub(in crate::platform) mod errors;
mod execution;
mod io;
pub(in crate::platform) mod model;
pub(in crate::platform) mod params;
mod probe;
mod sessions;
mod supervision;

pub(super) use active_control::{ControlDisposition, steer};
#[allow(unused_imports)]
pub(super) use errors::ProtocolFailure;
pub(super) use execution::execute;
#[allow(unused_imports)]
pub(super) use model::{CapabilityProbe, EffectiveSettings, RUNTIME_PROTOCOL, RunResult};
pub(super) use probe::probe;

#[cfg(test)]
mod tests;
