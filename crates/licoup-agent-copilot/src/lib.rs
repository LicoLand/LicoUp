//! The Copilot adapter package.
//!
//! One Agent, one package, one program. This crate owns everything LicoUp knows
//! about Copilot's own protocol and program: the ACP frames Copilot sends
//! ([`parser`]), Copilot's immutable ACP launch declaration ([`driver`]), the
//! frame dialect that projects the parser onto the shared ACP engine's port
//! ([`dialect`]), the registration composition injects into the adapter SDK
//! ([`registration`]), and the recorded-transcript replay arm that drives the
//! same parser ([`replay`]).
//!
//! # The boundaries this crate keeps
//!
//! - **No client crate.** Nothing here reaches into `licoup-native` or any other
//!   composition crate. What this package needs from the shared ACP engine
//!   arrives through `licoup-agent-drivers`' declared port, and composition
//!   installs this Agent's answer.
//! - **One parse.** A raw line becomes this Agent's effects in [`parser`] and is
//!   never re-parsed above: the parser is the sole ingress, per ADR-0008.
//! - **The shared engine stays shared.** The ACP reducer, the framing, the
//!   session semantics and the process runtime are not Copilot's protocol and do
//!   not live here. Copilot, Kimi Code and Hermes reach the same engine; what
//!   differs between them is exactly what this crate supplies.
//! - **No vendor branch above.** Composition reads [`registration::REGISTRATION`]
//!   and installs [`registration::DIALECT`]; neither names a frame rule of
//!   another Agent, and a host that composes no Copilot package links nothing of
//!   this crate.
//!
//! # What this package does not yet do
//!
//! The package ships Copilot's declaration and its protocol; it does not yet
//! *execute* Copilot. The client still launches, supervises, probes and cancels
//! a Copilot turn through the shared ACP engine in `licoup-agent-drivers`,
//! composed by `licoup-native`'s `platform::copilot_driver`, and the extension
//! host's binary route — the agent-execution port — is what moves that half
//! next. Until it does, running this package's binary describes this Agent; it
//! does not run a turn. That remainder is named for the kernel cleanup that owns
//! it, and nothing here claims otherwise.
//!
//! Because this package starts no execution, it declares no host port of its
//! own and answers no admission question: which conversation is admitted, when
//! an update may replace a running package, and where a turn's events go are the
//! host's, reached through the shared engine today and through the
//! agent-execution route when that route lands. A package that executes nothing
//! has nothing with which to bypass the host's idle update admission, and when
//! it does execute it will ask the host rather than decide.

pub mod dialect;
pub mod driver;
pub mod parser;
pub mod registration;

/// The recorded-transcript replay arm.
///
/// It drives the shared ACP reducer, so it is compiled only where that reducer's
/// replay surface is: this crate's own tests and a composing test build that
/// asks for `test-support`. A production build carries no arm.
#[cfg(any(test, feature = "test-support"))]
pub mod replay;

#[cfg(test)]
mod tests;
