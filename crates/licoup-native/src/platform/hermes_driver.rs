//! Hermes Agent ACP adapter.
//!
//! Hermes contributes only its fixed launch/probe contract. Persistent ACP
//! process ownership, session routing, cancellation, and shared result types
//! live in the service-neutral session transport.

mod execution;
mod probe;

use super::acp_session_transport::AcpSessionDriverSpec;

pub(super) const RUNTIME_PROTOCOL: &str = "hermes-acp-stdio-jsonrpc";
pub(super) const HERMES_SESSION_DRIVER: AcpSessionDriverSpec =
    AcpSessionDriverSpec::new("hermes-acp", &["acp"]).with_runtime_id("hermes");

pub(super) use super::acp_session_transport::RunResult;
#[cfg(test)]
pub(super) use execution::execute;
pub(super) use execution::{cancel, cleanup_session, execute_with_connection};
pub(super) use probe::probe;

#[cfg(test)]
mod tests;
