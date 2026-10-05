//! The host's progressive turn-event emission, as one installed port.
//!
//! One OpenClaw turn produces structured, redacted events as its Gateway frames
//! arrive: processing evidence and streamed assistant message chunks. *What* the
//! events are is this package's answer;
//! *where they go* is the host's, because the host owns the consumer — a CLI
//! `--stream-events` reader, the Flutter NDJSON transport, or no consumer at all.
//!
//! The port is one installed function set rather than a second sink, so the
//! package never keeps a thread-local the host also keeps: a process installs
//! [`install`] once, and every event this package emits reaches the same
//! consumer the host's own emitters reach. Before installation the port is
//! fail-closed and emits nothing, which is the honest answer for a package
//! running outside the client.
//!
//! The events a driver leaves in the *kernel* — `dispatch.gateway.attached`,
//! `dispatch.turn.bound` — are emitted by that kernel transport, not here; this
//! port carries only what the package's own protocol state machine produces.

use std::sync::OnceLock;

/// The host facilities one OpenClaw turn's events need.
///
/// The port carries exactly the two emissions this package's state machine
/// produces — a streamed assistant message chunk and one processing
/// observation — rather than the host's whole event vocabulary. The named
/// `dispatch.*` events a Gateway attach produces are emitted by the kernel
/// transport that performs the attach, so they are not declared here: a package
/// cannot ask for an emission it does not make.
#[derive(Clone, Copy)]
pub struct TurnEventPort {
    /// Emit one streamed assistant message chunk.
    pub emit_agent_message_chunk: fn(session_id: &str, turn_id: &str, text: &str),
    /// Emit one processing observation with its evidence kind and tool name.
    pub emit_agent_processing:
        fn(session_id: &str, turn_id: &str, evidence_kind: &str, tool_name: Option<&str>),
}

static PORT: OnceLock<TurnEventPort> = OnceLock::new();

/// Install the host's emission once per process.
///
/// A second installation with a different port is refused rather than silently
/// replacing the first: the consumer belongs to one process, and a second
/// answer would mean two consumers for one turn.
pub fn install(port: TurnEventPort) -> Result<(), &'static str> {
    PORT.set(port)
        .map_err(|_| "the turn-event port is already installed")
}

/// Whether the host has installed its emission.
pub fn installed() -> bool {
    PORT.get().is_some()
}

pub(crate) fn emit_agent_message_chunk(session_id: &str, turn_id: &str, text: &str) {
    if let Some(port) = PORT.get() {
        (port.emit_agent_message_chunk)(session_id, turn_id, text);
    }
}

pub(crate) fn emit_agent_processing(
    session_id: &str,
    turn_id: &str,
    evidence_kind: &str,
    tool_name: Option<&str>,
) {
    if let Some(port) = PORT.get() {
        (port.emit_agent_processing)(session_id, turn_id, evidence_kind, tool_name);
    }
}
