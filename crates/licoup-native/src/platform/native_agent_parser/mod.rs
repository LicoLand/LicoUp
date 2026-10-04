//! The native Agent parser family: the thirteen per-Agent parsers this host
//! still holds, and the composition that injects them into the adapter SDK.
//!
//! `licoup-agent-adapter-sdk` is the single authority for what every adapter
//! program shares: the byte-line ingress contract, the adapter declaration, the
//! closed transition vocabulary and its arrival-ordered reducer, the
//! delta/cumulative text reconciliation, the process-local driver registry, the
//! registry lookup, the recorded-transcript replay harness and the parser
//! lifecycle machine. None of that is here any more, and none of it is
//! duplicated here.
//!
//! What is here is one Agent each. `adapters` holds the thirteen parser
//! entries this host composes — seven declared here and six, Antigravity,
//! Codex, Cursor, DeepSeek Harness, Kimi Code and Pi, named from the packages
//! that own their protocols — plus the `REGISTRATIONS` list that names their
//! declarations; `replay` holds the arm that drives each of them from a
//! recorded transcript and the corpus checks that belong to the family; and
//! `tests` holds the family's own claims. Each per-Agent subtree and its arm
//! move to that Agent's crate (`licoup-agent-<agent>`); this root and the
//! composition are what remain, because they are what names thirteen parsers
//! and, later, thirteen crates. Six subtrees have moved already: their parsers
//! are reached through the packages that own them and no copy stays here.
//!
//! The SDK's two protocol-agnostic `port::ParserRegistration` queries are
//! answered in `adapters::REGISTRATIONS` by the Agents whose facts a reader
//! actually reaches: Hermes answers `execution_transitions`, because it reports
//! no transition list of its own and the host's Hermes normalization reads that
//! query; the Agents the Subagent mesh dispatches — Antigravity and Claude Code
//! here, Codex and Cursor from their own packages — answer `valid_identity`
//! from their own recorded evidence; and a package entry answers both queries
//! from the package's wire vocabulary. Every other entry leaves
//! `execution_transitions` unanswered because its driver carries the parser's
//! own transition list, and the identity query stays fail-closed for an Agent
//! the mesh never dispatches. No entry inherits a neighbouring Agent's answer.

pub(in crate::platform) mod adapters;
#[cfg(test)]
pub(in crate::platform) mod replay;
#[cfg(test)]
mod tests;

/// The shared adapter vocabulary this host's parsers and drivers speak.
///
/// The SDK owns the definitions; this is the family's name for them, so a
/// caller that already reaches this module keeps one path to the vocabulary
/// while the definitions live in exactly one crate.
pub(in crate::platform) use licoup_agent_adapter_sdk::{
    LifecycleStage, Transition, TransitionReducer,
};

/// Complete packaged inventory. The registry test proves this is bijective
/// with `RuntimeAdapter`; adding an adapter requires adding its parser here.
#[cfg(test)]
const PACKAGED_ADAPTER_IDS: [&str; 13] = [
    "antigravity",
    "claude-code",
    "codex",
    "copilot",
    "cursor",
    "hermes",
    "kilo-code",
    "kimi-code",
    "openclaw",
    "opencode",
    "pi",
    "lico-agent",
    "deepseek-harness",
];


/// The parser set this host injects into the adapter SDK.
///
/// The declarations live in `adapters`, where the thirteen parsers that report
/// them live; this is the composition's name for the set, so a caller outside
/// the family never names a parser to reach the SDK.
pub(in crate::platform) const fn parser_set() -> licoup_agent_adapter_sdk::port::AdapterParserSet {
    adapters::parser_set()
}
