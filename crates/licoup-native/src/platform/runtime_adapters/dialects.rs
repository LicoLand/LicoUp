//! The per-Agent frame-dialect answers this host hands the ACP transport.
//!
//! `licoup-agent-drivers` owns the ACP transport engines and declares the port
//! they read one driver's frame dialect through. This module is the composition
//! above it: every entry here names one Agent's own parser function, and the
//! moved crate names none of them.
//!
//! An Agent whose parser has moved into its own package also moved the
//! projection onto this port, because a projection is only meaningful beside
//! the type it projects: Copilot's dialect and the request projection it needs
//! are `licoup-agent-copilot`'s, and the table in [`super::drivers`] names the
//! package's constant rather than rebuilding it.
//!
//! Two parsers answer the port through this module — Kimi Code's for the ACP
//! profile, Hermes' for the persistent ACP dialect. The remaining members are
//! adapters rather than parser functions, and each exists for a measured
//! reason:
//!
//! * [`kimi_code_client_request`] projects that Agent's own `ClientRequest` onto
//!   the transport's [`ProtocolClientRequest`]. The two types are
//!   field-for-field identical, and the projection exists so the transport reads
//!   one shape rather than every Agent's.
//! * [`hermes_permission_request`] does the same for Hermes' richer
//!   `PermissionRequest`, which is the only one of the two that carries a
//!   display summary and a requested-tool list.
//! * [`acp_response_is_error`] answers that dialect's error test. Kimi Code's
//!   parser reports a remote error through `failure_from_response` rather than
//!   exposing a predicate, and the frame rule it follows — a frame carrying
//!   `error` is an error — is the same rule Hermes' parser states, so it is
//!   stated once here for the one that does not.
//! * [`no_permission_request`] and [`no_client_request`] are the honest answer
//!   for a dialect that has no such frame: Kimi Code never asks a permission
//!   question over this profile, and Hermes never asks a client request, so
//!   neither ever invents one.

use licoup_agent_drivers::ProtocolClientRequest;
use licoup_agent_drivers::ProtocolPermissionRequest;
use serde_json::Value;

/// Project Kimi Code's client request onto the transport's shape.
pub(super) fn kimi_code_client_request(message: &Value) -> Option<ProtocolClientRequest> {
    let request =
        crate::platform::native_agent_parser::adapters::kimi_code::client_request(message)?;
    Some(ProtocolClientRequest {
        id: request.id,
        method: request.method,
        session_id: request.session_id,
        allow_once_option: request.allow_once_option,
    })
}

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

/// The ACP profile's error test, for the two parsers that state no predicate.
///
/// A frame carrying `error` is the response outcome the shared ACP envelope
/// rejects; this is the same rule Hermes' parser applies in
/// `adapters::hermes::response_is_error`.
pub(super) fn acp_response_is_error(message: &Value) -> bool {
    message.get("error").is_some()
}

/// A dialect that never asks a permission question.
pub(super) fn no_permission_request(_: &Value) -> Option<ProtocolPermissionRequest> {
    None
}

/// A dialect that never asks a client request.
pub(super) fn no_client_request(_: &Value) -> Option<ProtocolClientRequest> {
    None
}
