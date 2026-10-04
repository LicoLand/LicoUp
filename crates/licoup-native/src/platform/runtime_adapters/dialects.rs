//! The per-Agent frame-dialect answers this host hands the ACP transport.
//!
//! `licoup-agent-drivers` owns the ACP transport engines and declares the port
//! they read one driver's frame dialect through. This module is the composition
//! above it: every entry here names one Agent's own parser function, and the
//! moved crate names none of them. Kimi Code's and Hermes' dialects are not
//! assembled here at all: each package publishes its registration whole, so this
//! file names no Kimi or Hermes function and each package's own dialect is
//! installed by the driver table.
//!
//! What remains is the Copilot-profile dialect — the one dialect several Agents
//! share — whose members are Copilot's parser functions plus the projections
//! that exist for a measured reason:
//!
//! * [`copilot_client_request`] projects Copilot's own `ClientRequest` onto the
//!   transport's [`ProtocolClientRequest`]. The two types are field-for-field
//!   identical, and the projection exists so the transport reads one shape
//!   rather than every Agent's.
//! * [`acp_response_is_error`] answers the ACP profile's error test. Copilot's
//!   parser reports a remote error through `failure_from_response` rather than
//!   exposing a predicate, and the frame rule — a frame carrying `error` is an
//!   error — is stated once here for the profile that does not.
//! * [`no_permission_request`] is the honest answer for a dialect that has no
//!   such frame: Copilot never asks a permission question over this profile, so
//!   it never invents one.

use licoup_agent_drivers::ProtocolClientRequest;
use licoup_agent_drivers::ProtocolPermissionRequest;
use serde_json::Value;

/// Project Copilot's client request onto the transport's shape.
pub(super) fn copilot_client_request(message: &Value) -> Option<ProtocolClientRequest> {
    let request =
        crate::platform::native_agent_parser::adapters::copilot::client_request(message)?;
    Some(ProtocolClientRequest {
        id: request.id,
        method: request.method,
        session_id: request.session_id,
        allow_once_option: request.allow_once_option,
    })
}

/// The ACP profile's error test, for the parser that states no predicate.
///
/// A frame carrying `error` is the response outcome the shared ACP envelope
/// rejects; Hermes' own package states the same rule for the persistent profile.
pub(super) fn acp_response_is_error(message: &Value) -> bool {
    message.get("error").is_some()
}

/// A dialect that never asks a permission question.
pub(super) fn no_permission_request(_: &Value) -> Option<ProtocolPermissionRequest> {
    None
}
