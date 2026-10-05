//! The OpenClaw adapter package.
//!
//! One Agent, one package, one program. This crate owns everything LicoUp knows
//! about OpenClaw's own protocol and program: the Gateway ACP state machine
//! ([`parser`]), the byte-line codec that classifies one Gateway frame exactly
//! once below the adapter port, the driver vocabulary those frames are reported
//! through ([`gateway_acp`]), the endpoint an ACP attach names ([`gateway`]),
//! the registration composition injects into the adapter SDK ([`registration`]),
//! the recorded-transcript replay arm ([`replay`]), and the ports the host
//! answers ([`port`]).
//!
//! # The boundaries this crate keeps
//!
//! - **No client crate.** Nothing here reaches into `licoup-native` or any other
//!   composition crate. What the package needs from its host arrives through
//!   [`port`] or as an explicit argument to the one call that needs it, and the
//!   host installs or supplies it.
//! - **One parse.** A raw Gateway line becomes this Agent's effects here and is
//!   never re-parsed above: [`parser::protocol`] is the sole ingress, per
//!   ADR-0008.
//! - **The client owns the turn.** The state machine reports protocol finishes,
//!   end of stream and confirmed cancellation; it settles no turn, imposes no
//!   implicit timeout, and hides no content. The conversation layer remains the
//!   sole turn authority.
//! - **Fail closed without a host.** An uninstalled port emits nothing and
//!   admits nothing rather than guessing, so the protocol and the replay corpus
//!   are fully exercised with no host at all.
//!
//! # What this crate does not own yet
//!
//! The process half of the OpenClaw driver — spawning the ACP bridge, reading
//! its framed lines, bounding its output and supervising the turn — is still
//! composed by the client in `platform::openclaw_driver`, together with the
//! reviewed bounded capability probe and the Gateway lifecycle. This package
//! therefore owns the protocol and the vocabulary, and the kernel still executes
//! OpenClaw: no end-to-end execution from this package's binary is claimed here.
//! Completing that route is the VENDOR-CODE-REMOVAL remainder.

pub mod gateway;
pub mod gateway_acp;
pub mod parser;
pub mod port;
pub mod registration;
pub mod replay;

#[cfg(test)]
mod tests;
