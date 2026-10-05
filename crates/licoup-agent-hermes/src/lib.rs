//! The Hermes adapter package.
//!
//! One Agent, one package, one program. This crate owns everything LicoUp knows
//! about Hermes' own protocol and the process half that speaks it: the persistent
//! ACP frame dialect Hermes answers with ([`dialect`]), the byte-line parser that
//! classifies those frames exactly once below the adapter port and words Hermes'
//! normalized transitions ([`parser`]), the launch and probe contract the shared
//! session transport runs and one bounded turn over it ([`driver`]), the
//! registration composition injects into the adapter SDK ([`registration`]), and
//! the recorded-transcript replay arm ([`replay`]).
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
//!   asks, the launch and probe commands, and the transition vocabulary its turns
//!   reduce to.
//! - **The normalized transitions are Hermes' answer.** Hermes reports no
//!   transition list with its execution result, so it is the one Agent whose
//!   transitions the host reads through the SDK's protocol-agnostic query:
//!   [`registration::execution_transitions`] answers it from
//!   [`parser::completed_transitions`] and [`parser::failed_transitions`], and the
//!   durable-identity query stays fail-closed because the Subagent mesh never
//!   dispatches Hermes.
//!
//! # Who executes Hermes
//!
//! The package runs Hermes' local ACP turn: `licoup-native`'s composition names
//! [`driver`] and keeps no Hermes ACP module of its own, so one Hermes turn is
//! described in exactly one place. Two halves stay the host's and are named here
//! so neither is claimed: the conversation lane that decides whether a turn may
//! run, and the Hermes TUI gateway transport — a host lane the composition picks
//! where the runtime connection is in view. The package declares no host-answered
//! port, because the shared transport, the launch environment and the target
//! contracts it reads are lower crates and it asks its host for nothing.

pub mod dialect;
pub mod driver;
pub mod parser;
pub mod registration;

#[cfg(any(test, feature = "test-support"))]
pub mod replay;

#[cfg(test)]
mod tests;
