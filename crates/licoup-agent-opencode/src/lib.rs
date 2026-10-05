//! The OpenCode adapter package.
//!
//! One Agent, one package, one program. This crate owns everything LicoUp knows
//! about OpenCode's own `serve` protocol: the HTTP documents and SSE event
//! frames that classify one OpenCode line exactly once below the adapter port
//! ([`parser`]), the registration composition injects into the adapter SDK
//! ([`registration`]), the recorded-transcript replay arm ([`replay`]), and the
//! port the host answers ([`port`]).
//!
//! # The boundaries this crate keeps
//!
//! - **No client crate.** Nothing here reaches into `licoup-native` or any other
//!   composition crate. What the package needs from its host arrives through
//!   [`port`], and the host installs it.
//! - **One parse.** A raw `serve` document becomes this Agent's facts here and is
//!   never re-parsed above: the parser is the sole ingress, per ADR-0008.
//! - **The client owns the turn.** The parser reports a completed message, the
//!   stream's assistant text and the protocol's framing failure; it settles no
//!   turn, imposes no implicit timeout, and hides no content. The conversation
//!   layer remains the sole turn authority.
//! - **Fail closed without a host.** An uninstalled port admits nothing rather
//!   than guessing, so the protocol and the replay corpus are fully exercised
//!   with no host at all.
//!
//! # What this package does not own yet
//!
//! The `serve` *process* half — starting and supervising the endpoint, reading
//! its HTTP documents and its SSE stream, recording raw bytes for a diagnostic
//! record and admitting an active turn so force stop can reach it — is the
//! client's shared local-service engine, and the client's `opencode_serve`
//! facade and `opencode_driver` compose it today. They read this crate's
//! [`parser`] rather than keeping a copy of the protocol, and the admission
//! question they ask before a turn starts is this crate's [`port::execution`].
//! Moving that last client-side composition onto the package's own binary route
//! is the named remainder on `VENDOR-CODE-REMOVAL`, and nothing here claims
//! OpenCode already runs from this package's binary.

pub mod parser;
pub mod port;
pub mod registration;
pub mod replay;

#[cfg(test)]
mod tests;
