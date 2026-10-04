//! The Cursor adapter package.
//!
//! One Agent, one package, one program. This crate owns everything LicoUp knows
//! about Cursor's own protocol and program: the strict-NDJSON turn dialect of
//! the Cursor Agent CLI ([`parser`]), classified exactly once below the adapter
//! port, the wire vocabulary that dialect reads and reports ([`model`],
//! [`errors`]), the registration composition injects into the adapter SDK
//! ([`registration`]), the recorded-transcript replay arm ([`replay`]), and the
//! ports the host answers ([`port`]).
//!
//! # The boundaries this crate keeps
//!
//! - **No client crate.** Nothing here reaches into `licoup-native` or any other
//!   composition crate. What the package needs from its host arrives through
//!   [`port`], and the host installs it.
//! - **One parse.** A raw strict-NDJSON line becomes this Agent's effects here
//!   and is never re-parsed above: the parser is the sole ingress, per ADR-0008.
//! - **The client owns the turn.** The parser reports delivery acknowledgement,
//!   streamed text, structured tool calls, application tool errors and protocol
//!   finishes; it settles no turn, imposes no implicit timeout, and hides no
//!   content. The conversation layer remains the sole turn authority.
//! - **Fail closed without a host.** An uninstalled port emits nothing and
//!   admits nothing rather than guessing, so the protocol and the replay corpus
//!   are fully exercised with no host at all.
//!
//! # What the package does not own yet
//!
//! Cursor's *process* half — launching `cursor-agent`, the PTY transport, the
//! update watcher, the hosted usage reader and the local Subagent MCP caller
//! registration — is still composed by the client. It moves onto
//! [`port::execution`] next, and until it does this package is a protocol
//! package: it ships its declared native entry and its recorded-transcript
//! parity, and it claims no end-to-end execution.

pub mod errors;
pub mod model;
pub mod parser;
pub mod port;
pub mod registration;
pub mod replay;

#[cfg(test)]
mod tests;
