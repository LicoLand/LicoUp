//! Which reported failures invalidate the supervised transport.
//!
//! The failure shape is the package's; the decision that a failure means the
//! live CLI process can no longer be trusted belongs to the process half, which
//! owns that process. A failure this predicate answers `true` for releases the
//! transport and lets the next turn launch a fresh one.

use licoup_agent_claude_code::protocol::ProtocolFailure;

/// Whether one reported failure leaves the live transport unusable.
pub(in crate::platform) fn requires_transport_reset(failure: &ProtocolFailure) -> bool {
    matches!(
        failure.code,
        "claude_code_write_failed"
            | "claude_code_timeout"
            | "claude_code_invalid_json"
            | "claude_code_output_limit"
            | "claude_code_read_failed"
            | "claude_code_exited"
            | "claude_code_cleanup_requested"
            | "claude_code_session_mismatch"
            | "claude_code_session_id_invalid"
            | "claude_code_authentication_required"
    )
}
