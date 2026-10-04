//! The Lico Agent adapter package.
//!
//! One Agent, one package, one program. Lico Agent is LicoUp's own runtime
//! rather than a third-party CLI, and this crate owns the half of it that is
//! *this host's* interface to it: the `lf-jsonl-jsonrpc` stdio protocol the
//! packaged `lico-agent` program answers on ([`parser`]), classified exactly
//! once below the adapter port, the RPC session identity, transcript layout and
//! active plan layout that protocol's `--session-id`/`--resume`/`--plan-path`
//! contract defines ([`session`]), the registration composition injects into
//! the adapter SDK ([`registration`]), the recorded-transcript replay arm
//! ([`replay`]), and the ports the host answers ([`port`]).
//!
//! # The boundaries this crate keeps
//!
//! - **No client crate.** Nothing here reaches into `licoup-native` or any other
//!   composition crate. What the package needs from its host arrives through
//!   [`port`], and the host installs it.
//! - **One parse.** A raw JSONL frame becomes this Agent's effect here and is
//!   never re-parsed above: the parser is the sole ingress, per ADR-0008.
//! - **The client owns the turn.** The parser reports the handshake, streamed
//!   text, progress, the interaction control request and the terminal frames;
//!   it settles no turn, imposes no implicit timeout, and hides no content. The
//!   conversation layer remains the sole turn authority.
//! - **Fail closed without a host.** An uninstalled port admits nothing rather
//!   than guessing, so the protocol, the session layout and the replay corpus
//!   are fully exercised with no host at all.
//!
//! # What this package does not own
//!
//! Lico Agent's *agent core* — the model loop, the tool registry, the two
//! profiles, the loopback Gateway chat transport and the persisted-transcript
//! reader — belongs to `licoup-agent-targets`, which this crate does not
//! reimplement. Discovery, the scan-path inventory and the compatibility
//! projection are inventory facts and stay with `licoup-agent-targets` and
//! LicoUp packaging. What is this package's is the wire the host and the
//! packaged program speak, and the session, transcript and plan locations that
//! wire resumes by.
//!
//! # What this package does not own yet
//!
//! Lico Agent's *process* half — spawning the packaged program, supervising the
//! turn, the raw-execution observation, the workspace bound and the macOS
//! seatbelt plan-isolation command — is still composed by the client in
//! `licoup-native`'s `platform::lico_agent_driver`, which reads this package's
//! parser, request envelopes, transitions, session layout and runtime protocol
//! id. That half moves onto [`port::execution`] next, and until it does this
//! package is a protocol package: it ships its declared native entry and its
//! recorded-transcript parity, and it claims no end-to-end execution.

pub mod parser;
pub mod port;
pub mod registration;
pub mod replay;
pub mod session;

#[cfg(test)]
mod tests;
