//! The Pi RPC driver, composed from the Pi adapter package.
//!
//! The protocol vocabulary this driver speaks — the failure shape, the effective
//! settings, the launch configuration and the session records a native resume
//! resolves against — belongs to Pi and lives in `licoup-agent-pi` now. It is
//! re-exported here at its former path so the driver leaves below keep reading
//! it, and so the client carries one copy of the vocabulary rather than two.
//!
//! What is still composed by the client is the *process* half: launching
//! `pi --mode rpc`, reading its JSONL lines, supervising the turn, answering
//! control requests and probing the executable. That half moves to the package
//! next, through the agent-execution port this package declares; until it does,
//! the client reads the protocol from the package and owns only the process.

mod active_control;
mod execution;
mod io;
mod probe;
mod supervision;

// This Agent's wire vocabulary, owned by the package that carries the Agent.
pub(in crate::platform) use licoup_agent_pi::driver::{errors, model, params};
// The session records a native Pi resume resolves against are the package's
// too; the driver body reaches them through the launch configuration, and the
// session checks below read the resolution directly.
#[allow(unused_imports)]
pub(in crate::platform) use licoup_agent_pi::driver::sessions;

pub(super) use active_control::{ControlDisposition, steer};
#[allow(unused_imports)]
pub(super) use errors::ProtocolFailure;
pub(super) use execution::execute;
#[allow(unused_imports)]
pub(super) use model::{CapabilityProbe, EffectiveSettings, RUNTIME_PROTOCOL, RunResult};
pub(super) use probe::probe;

#[cfg(test)]
mod tests;
