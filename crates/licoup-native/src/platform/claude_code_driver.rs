//! The Claude Code adapter, composed from the Claude Code adapter package.
//!
//! The protocol vocabulary this driver speaks — the `lf-ndjson` framing, the
//! launch identity and its argv, the effective settings the CLI reports, the
//! failure shape, the control request, and the byte-line parser that classifies
//! one frame — belongs to Claude Code and lives in `licoup-agent-claude-code`
//! now. It is re-exported here at its former path so the driver leaves below
//! keep reading it, and so the client carries one copy of the vocabulary rather
//! than two.
//!
//! What is still composed by the client is the *process* half: supervising the
//! streaming-input CLI, binding the conversation, reading its framed lines,
//! parking an approval and answering a cancel. That half moves to the package
//! next, through the agent-execution port the package declares; until it does,
//! the client reads the protocol from the package and owns only the process.
//!
//! The Subagent MCP caller registration is the other half still named by the
//! host: it is composed from the host's own provider-config registry, which the
//! host owns for every provider at once.

// This Agent's protocol, owned by the package that carries the Agent.
pub use licoup_agent_claude_code::protocol::parser::events;
pub use licoup_agent_claude_code::protocol::parser::{
    ClaudeCodeParser, ClaudeEffect, ProtocolFinishReport, encode_message, failure_transitions,
    interrupt_request, permission_response, steer_message, user_message,
};
pub use licoup_agent_claude_code::protocol::{
    CapabilityProbe, DriverConfig, EffectiveSettings, LaunchIdentity, ProtocolFailure,
};
// The recorded-transcript arm belongs beside the parser it drives.
pub use licoup_agent_claude_code::replay::replay_arm;

pub(in crate::platform) mod approval;
pub(in crate::platform) mod launch;
mod control;
mod execution;
mod io;
pub(in crate::platform) mod failure;
pub(in crate::platform) mod model;
mod probe;
mod reset;
mod supervision;
mod transport;
#[cfg(test)]
pub(super) use super::conversation_lane;
pub(super) use control::ControlDisposition;
#[allow(unused_imports)]
pub(super) use reset::requires_transport_reset;
pub(super) use execution::execute;
#[allow(unused_imports)]
pub(super) use model::{CompleteTranscript, RUNTIME_PROTOCOL, RunResult, TransportLifecycle};
pub(super) use probe::probe;
pub(super) use supervision::{cancel, cleanup_session, history, steer};
#[cfg(test)]
mod tests;
