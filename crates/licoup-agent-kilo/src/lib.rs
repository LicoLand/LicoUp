//! The Kilo Code adapter package.
//!
//! One Agent, one package, one program. This crate owns everything LicoUp knows
//! about Kilo Code's own protocol and program: the `serve` HTTP/SSE documents
//! its endpoint answers and the parser that classifies them exactly once below
//! the adapter port ([`parser`], [`serve`]), the endpoint contract the Agent
//! owns ([`policy`]), this Agent's own half of one turn ([`driver`]), the
//! registration composition injects into the adapter SDK ([`registration`]),
//! the recorded-transcript replay arm ([`replay`]), and the ports the host
//! answers ([`port`]).
//!
//! # The boundaries this crate keeps
//!
//! - **No client crate.** Nothing here reaches into `licoup-native` or any
//!   other composition crate. What the package needs from its host arrives
//!   through [`port`], and the host installs it.
//! - **One parse.** A raw serve document becomes this Agent's facts here and is
//!   never re-parsed above: the parser is the sole ingress, per ADR-0008.
//! - **The client owns the turn.** The parser reports a completed message, the
//!   stream's text chunks and the protocol's failures; it settles no turn,
//!   imposes no implicit timeout, and hides no content. The conversation layer
//!   remains the sole turn authority.
//! - **Fail closed without a host.** An uninstalled port emits nothing and
//!   admits nothing rather than guessing, so the protocol and the replay corpus
//!   are fully exercised with no host at all.
//!
//! # What this package does not yet do
//!
//! The package owns the Agent's half of a turn; the client still *performs*
//! one, because the serve engine it starts, the HTTP and SSE reader and the
//! turn-control registry belong to the shared local-service engine and to the
//! extension host. This crate publishes the agent-execution port that completes
//! that route ([`port::execution`]); until the host drives this package's
//! binary, Kilo Code still runs inside the client process. Removing the last
//! client-side Kilo Code execution is the named remainder on
//! `VENDOR-CODE-REMOVAL`, and this crate does not claim otherwise.

pub mod driver;
pub mod parser;
pub mod policy;
pub mod port;
pub mod registration;
pub mod replay;
pub mod serve;

#[cfg(test)]
mod tests;
