//! Persistent ACP session transport shared by vendor adapters.
//!
//! The pool is keyed by driver identity, executable, and workspace. Session
//! control is likewise driver-scoped so native identifiers from different ACP
//! implementations can never alias each other in shared process state.

mod approval_store;
mod approval_wait;
mod capabilities;
mod command;
mod continuity;
mod errors;
mod events;
mod execution;
mod io;
mod protocol;
mod supervision;

pub(in crate::platform) use approval_store::resolve_parked_permission;
pub(in crate::platform) use capabilities::{AcpSessionDriverSpec, CapabilityProbe, RunResult};
pub(in crate::platform) use continuity::{ControlDisposition, cancel, cleanup_session};
pub(in crate::platform) use errors::ProtocolFailure;
pub(in crate::platform) use execution::execute;
pub(in crate::platform) use io::{drain_bounded, read_bounded};

#[cfg(test)]
pub(in crate::platform) use capabilities::{
    APPROVAL_POLL_INTERVAL, APPROVAL_WAIT_TIMEOUT, CONTROL_QUEUE_CAPACITY, MAX_PARKED_PERMISSIONS,
    MAX_POOLED_TRANSPORTS, MAX_TRACKED_SESSIONS, PROCESS_POLL_INTERVAL,
};
#[cfg(test)]
pub(in crate::platform) use command::{LaunchSpec, ProtocolConfig};
#[cfg(test)]
pub(in crate::platform) use io::drain_stderr;
#[cfg(test)]
pub(in crate::platform) use protocol::{
    INITIALIZE_REQUEST_ID, MODEL_REQUEST_ID, PROMPT_REQUEST_ID, ProtocolEffect, ProtocolPhase,
    SESSION_REQUEST_ID, SessionProtocol,
};

#[cfg(test)]
mod tests;
