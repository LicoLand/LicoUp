//! The per-Agent frame-dialect answers this host hands the ACP transport.
//!
//! `licoup-agent-drivers` owns the ACP transport engines and declares the port
//! they read one driver's frame dialect through. This module is the composition
//! above it: every entry here names one Agent's own parser function, and the
//! moved crate names none of them. Kimi Code's dialect is not assembled here at
//! all: its package publishes the registration whole, so this file names no
//! Kimi function and the package's own dialect is installed by the driver table.
//!
//! An Agent whose parser has moved into its own package also moved the
//! projection onto this port, because a projection is only meaningful beside
//! the type it projects: Copilot's dialect and the request projection it needs
//! are `licoup-agent-copilot`'s, and the table in [`super::drivers`] names the
//! package's constant rather than rebuilding it.
//!
//! Hermes is the one parser that answers the port through this module, for the
//! persistent ACP dialect. The remaining member is an adapter rather than a
//! parser function, and it exists for a measured reason:
//!
//! * [`hermes_permission_request`] projects Hermes' richer `PermissionRequest`
//!   onto the transport's shape; Hermes is the only Agent whose frame carries a
//!   display summary and a requested-tool list.
//! * [`no_client_request`] is the honest answer for a dialect that never asks a
//!   client request: Hermes never asks one, so none is ever invented.

use licoup_agent_drivers::ProtocolClientRequest;
use licoup_agent_drivers::ProtocolPermissionRequest;
use serde_json::Value;

/// Project Hermes' permission request onto the transport's shape.
pub(super) fn hermes_permission_request(message: &Value) -> Option<ProtocolPermissionRequest> {
    let request =
        crate::platform::native_agent_parser::adapters::hermes::permission_request(message)?;
    Some(ProtocolPermissionRequest {
        id: request.id,
        method: request.method,
        session_id: request.session_id,
        display_summary: request.display_summary,
        option_id: request.option_id,
        requested_tools: request.requested_tools,
    })
}

/// A dialect that never asks a client request.
pub(super) fn no_client_request(_: &Value) -> Option<ProtocolClientRequest> {
    None
}
