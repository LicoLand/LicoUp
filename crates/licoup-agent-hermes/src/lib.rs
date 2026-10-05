//! The Hermes adapter package.
//!
//! One Agent, one package, one program. This crate owns everything LicoUp knows
//! about Hermes' own protocol: the persistent ACP frame dialect Hermes answers
//! with ([`dialect`]), the byte-line parser that classifies those frames exactly
//! once below the adapter port and words Hermes' normalized transitions
//! ([`parser`]), the registration composition injects into the adapter SDK
//! ([`registration`]), and the recorded-transcript replay arm ([`replay`]).
//!
//! # The boundaries this crate keeps
//!
//! - **No client crate.** Nothing here reaches into `licoup-native` or any other
//!   composition crate. Composition names this package; the package names none of
//!   the client's own types.
//! - **One parse.** A raw ACP line becomes a frame here and is never re-parsed
//!   above: the parser is the sole ingress, per ADR-0008. The shared ACP
//!   transport reads it through
//!   `licoup_agent_drivers::acp_driver_runtime::parser_port`, keyed by the driver
//!   identity this package declares.
//! - **The engine stays shared.** The ACP transport engines — bounded process
//!   I/O, capability negotiation, session lifecycle, the reducers, the persistent
//!   session pool and the control plane — stay in `licoup-agent-drivers`, because
//!   the persistent ACP profile is a published contract and not one Agent's
//!   protocol. What is Hermes' is the frame dialect, the permission question it
//!   asks, and the transition vocabulary its turns reduce to.
//! - **The normalized transitions are Hermes' answer.** Hermes reports no
//!   transition list with its execution result, so it is the one Agent whose
//!   transitions the host reads through the SDK's protocol-agnostic query:
//!   [`registration::execution_transitions`] answers it from
//!   [`parser::completed_transitions`] and [`parser::failed_transitions`], and the
//!   durable-identity query stays fail-closed because the Subagent mesh never
//!   dispatches Hermes.
//!
//! # What this package does not own yet
//!
//! Hermes' *process* half — launching the Hermes CLI, its PTY and gateway
//! transports, the approval wait and the conversation lane — is still composed by
//! the client (`licoup-native`'s `platform::hermes_driver` and
//! `platform::hermes_tui_gateway`), on the shared transport this package's
//! dialect is installed into. This is a protocol package: it ships its declared
//! native entry, its registration, its dialect and its recorded-transcript
//! parity, and it claims no end-to-end execution. It declares no host-answered
//! port, because the half that would need one is not this package's yet.

pub mod dialect;
pub mod parser;
pub mod registration;

#[cfg(any(test, feature = "test-support"))]
pub mod replay;

#[cfg(test)]
mod tests;
