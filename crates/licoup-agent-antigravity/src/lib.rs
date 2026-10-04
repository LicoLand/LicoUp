//! The Antigravity adapter package.
//!
//! One Agent, one package, one program. This crate owns everything LicoUp knows
//! about Antigravity's own protocol and program: the official Agent Hooks
//! receipt and the PTY lane's terminal classification ([`parser`]), the native
//! receipt writer the Agent Hooks configuration starts ([`hook`]), the
//! registration composition injects into the adapter SDK ([`registration`]),
//! the recorded-transcript replay arm ([`replay`]), and the ports the host
//! answers ([`port`]).
//!
//! # The boundaries this crate keeps
//!
//! - **No client crate.** Nothing here reaches into `licoup-native` or any other
//!   composition crate. What the package needs from its host arrives through
//!   [`port`], and the host installs it.
//! - **One parse.** A vendor receipt, a PTY byte chunk and a terminal process
//!   outcome become this Agent's effects here and are never re-classified above,
//!   per ADR-0008.
//! - **The client owns the turn.** The parser reports the native conversation
//!   identity, the redacted output and the lifecycle transitions; it settles no
//!   turn, imposes no implicit timeout, and hides no content. The conversation
//!   layer remains the sole turn authority.
//! - **Fail closed without a host.** An uninstalled port emits nothing and
//!   admits nothing rather than guessing, so the protocol and the replay corpus
//!   are fully exercised with no host at all.
//!
//! # The ports this package declares
//!
//! [`port::turn_event`] is the host's progressive turn-event emission, which the
//! client owns because the client owns the consumer. [`port::execution`] is the
//! agent-execution port the extension host answers when it starts this package's
//! binary: dispatch, admission and the Subagent caller context belong to the
//! host, and one Antigravity execution belongs here. Until that side is
//! installed the execution port is fail-closed.
//!
//! # What is not here yet
//!
//! The *process* half of the Antigravity driver — launching the vendor CLI under
//! a PTY, supervising it, harvesting the Stop-hook receipt file and answering
//! cancellation — is still composed by the client in
//! `licoup-native::platform::antigravity_driver`. It reads this crate's protocol
//! through the paths it always read, so the client carries one copy of the
//! vendor vocabulary rather than two. Moving that half here is the remaining
//! `VENDOR-CODE-REMOVAL` work; until it lands, this package is linked for its
//! parser and its ports and no claim is made that the client executes
//! Antigravity from this package's binary.

pub mod contract;
pub mod hook;
pub mod parser;
pub mod port;
pub mod registration;
pub mod replay;

#[cfg(test)]
mod tests;
