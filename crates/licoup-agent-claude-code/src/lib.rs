//! The Claude Code adapter package.
//!
//! One Agent, one package, one program. This crate owns everything LicoUp knows
//! about Claude Code's own protocol and program: the CLI's `stream-json`
//! dialect and the byte-line parser that classifies those frames exactly once
//! below the adapter port ([`protocol`]), the launch and effective-setting
//! shapes that dialect reports, the registration composition injects into the
//! adapter SDK ([`registration`]), the recorded-transcript replay arm
//! ([`replay`]), and the ports the host answers ([`port`]).
//!
//! # The boundaries this crate keeps
//!
//! - **No client crate.** Nothing here reaches into `licoup-native` or any other
//!   composition crate. What the package needs from its host arrives through
//!   [`port`], and the host installs it.
//! - **One parse.** A raw CLI line becomes this Agent's effects here and is
//!   never re-parsed above: [`protocol::parser`] is the sole ingress, per
//!   ADR-0008.
//! - **The client owns the turn.** The parser reports protocol finishes, end of
//!   stream and confirmed cancellation; it settles no turn, imposes no implicit
//!   timeout, and hides no content. The conversation layer remains the sole turn
//!   authority.
//! - **The client owns the process.** Supervising the CLI, parking an approval
//!   and answering a cancel remain the host's, because dispatch, admission and
//!   cancellation belong to the conversation layer. This package owns the
//!   protocol and the launch vocabulary that process speaks; the remaining
//!   process half moves behind [`port::execution`] next.
//!
//! # What this package does not yet carry
//!
//! The Claude Code *process* half — spawning the CLI, reading its frames,
//! supervising the turn and parking an approval — is still composed by the
//! kernel, which now reads this package's protocol instead of keeping a second
//! copy of it. Until that half moves behind the agent-execution port, the
//! kernel still executes Claude Code; nothing here claims otherwise.

pub mod port;
pub mod protocol;
pub mod registration;
pub mod replay;

#[cfg(test)]
mod tests;
