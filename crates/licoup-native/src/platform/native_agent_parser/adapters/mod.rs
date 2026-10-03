//! The thirteen per-Agent parsers this host composes, and the parser set it
//! injects into the adapter SDK.
//!
//! `licoup-agent-adapter-sdk` owns the shared half — the byte-line ingress
//! contract, the adapter declaration, the transition vocabulary, the framing
//! and envelope helpers, the driver registry and the registry lookup. This tree
//! owns the other half: one parser per Agent, and the composition that names
//! them and hands them to the SDK through `AdapterParserSet`.
//!
//! Each subtree below is one Agent's protocol and moves with that Agent's crate
//! (`licoup-agent-<agent>`); the composition travels last, because it is what
//! tilts from naming thirteen parsers to naming the crates that hold them.

pub(in crate::platform) use licoup_agent_adapter_sdk::adapters::{
    AdapterContract, NativeLineParser,
};
pub(in crate::platform) use licoup_agent_adapter_sdk::{
    LifecycleStage, Transition, TransitionReducer,
};

// One Agent's parser has moved: Codex's vendor protocol now lives in its own
// package (`licoup-agent-codex`), parsed once below this port, and this
// composition names the package rather than keeping a second copy. The
// remaining twelve move the same way, one package each.
pub(in crate::platform) use licoup_agent_codex::parser as codex;

pub(in crate::platform) mod antigravity;
pub(in crate::platform) mod claude_code;
pub(in crate::platform) mod copilot;
pub(in crate::platform) mod cursor;
pub(in crate::platform) mod deepseek_harness;
pub(in crate::platform) mod hermes;
pub(in crate::platform) mod kilo_code;
pub(in crate::platform) mod kimi_code;
pub(in crate::platform) mod lico_agent;
pub(in crate::platform) mod openclaw;
pub(in crate::platform) mod opencode;
pub(in crate::platform) mod pi;

use licoup_agent_adapter_sdk::port::{AdapterParserSet, ParserRegistration};

/// The adapter declarations this host's thirteen Agent parsers report, in
/// `RuntimeAdapter` order.
///
/// This is the single list of the parsers this host carries: the registry
/// lookup, the dispatch admission and the packaged-inventory check all read it,
/// so an Agent parser is one entry rather than four lists that can drift. Each
/// entry names its Agent's declaration and answers fail-closed on the two
/// protocol-agnostic queries — see `native_agent_parser`'s authority statement
/// for which Node composes those answers.
pub(in crate::platform) static REGISTRATIONS: [ParserRegistration; 13] = [
    ParserRegistration::unanswered(antigravity::CONTRACT),
    ParserRegistration::unanswered(claude_code::CONTRACT),
    // The Codex package answers both protocol-agnostic queries from its own
    // recorded evidence, so this entry is the package's own registration rather
    // than a fail-closed placeholder.
    licoup_agent_codex::registration::REGISTRATION,
    ParserRegistration::unanswered(copilot::CONTRACT),
    ParserRegistration::unanswered(cursor::CONTRACT),
    ParserRegistration::unanswered(hermes::CONTRACT),
    ParserRegistration::unanswered(kilo_code::CONTRACT),
    ParserRegistration::unanswered(kimi_code::CONTRACT),
    ParserRegistration::unanswered(openclaw::CONTRACT),
    ParserRegistration::unanswered(opencode::CONTRACT),
    ParserRegistration::unanswered(pi::CONTRACT),
    ParserRegistration::unanswered(lico_agent::CONTRACT),
    ParserRegistration::unanswered(deepseek_harness::CONTRACT),
];

/// The parser registrations this host injects into the adapter SDK.
pub(in crate::platform) fn registrations() -> &'static [ParserRegistration] {
    &REGISTRATIONS
}

/// The parser set this host composes for production: every per-Agent parser it
/// holds, and no replay arm.
///
/// The replay harness is a test surface, so the arms are compiled only for the
/// test build (see `replay::replay_parser_set`), and a production reader of
/// `AdapterParserSet::replay_for` gets the fail-closed answer rather than an
/// arm this build does not carry.
pub(in crate::platform) const fn parser_set() -> AdapterParserSet {
    AdapterParserSet {
        registrations,
        ..AdapterParserSet::unavailable()
    }
}

/// The adapter declaration one composed parser reports, by dispatch id.
///
/// The replay arms read it so a frame recorded under another channel cannot
/// pass, and it is test-only for the same reason the arms are.
#[cfg(test)]
pub(in crate::platform) fn contract_for(
    adapter: crate::platform::runtime_adapters::RuntimeAdapter,
) -> AdapterContract {
    licoup_agent_adapter_sdk::registry::parser_for(&parser_set(), adapter.id())
        .expect("the dispatch enum and the composed parser set are one set")
}
