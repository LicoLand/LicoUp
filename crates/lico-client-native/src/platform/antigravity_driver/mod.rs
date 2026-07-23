//! Antigravity conversation adapter (argv + official Agent Hooks receipt).
//!
//! Ownership boundary: this module owns the send/resume/cancel/cleanup lane and
//! the Lico-namespaced Gemini hook bridge. Unrelated product features must not
//! hardcode Antigravity transport details; swap or detach by replacing this
//! module plus its inventory/manifest/gate config entries.

mod control;
mod errors;
mod execution;
mod hooks;
mod model;
mod probe;

pub(super) use control::{ControlDisposition, cancel, cleanup_session};
pub(super) use execution::execute;
#[cfg(test)]
pub(super) use hooks::uninstall_hook_bridge;
pub(crate) use hooks::{hook_bridge_status, install_hook_bridge, uninstall_hook_bridge_report};
pub(super) use model::{
    CapabilityProbe, DRIVER_ID, EffectiveSettings, RUNTIME_PROTOCOL, RunResult,
};
pub(super) use probe::probe;
pub(super) use probe::probe as capability_probe;

#[cfg(test)]
mod tests;
