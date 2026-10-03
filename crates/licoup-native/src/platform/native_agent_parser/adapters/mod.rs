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

// One Agent's parser has moved: Codex's vendor protocol now lives in its own package
// (`licoup-agent-codex`), parsed once below this port, and this composition names the
// package rather than keeping a second copy.
pub(in crate::platform) use licoup_agent_codex::parser as codex;
// Pi's vendor protocol moved the same way, into `licoup-agent-pi`, and this
// composition names that package's parser at the path the driver leaves read.
pub(in crate::platform) use licoup_agent_pi::parser as pi;

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

use licoup_agent_adapter_sdk::port::{
    AdapterParserSet, DurableIdentityRequest, ExecutionOutcome, ParserRegistration,
};

/// The fail-closed transition answer, for an Agent parser that reports its
/// transitions with its own execution result rather than through this query.
///
/// Twelve of the thirteen parsers answer that way: their driver carries the
/// `transitions` list the parser's own reducer built, so the query stays
/// declared and unanswered for them, exactly as
/// [`ParserRegistration::unanswered`] states.
fn no_transitions(_: &ExecutionOutcome<'_>) -> Vec<Transition> {
    Vec::new()
}

/// The fail-closed identity answer, for an Agent the Subagent mesh never
/// dispatches.
///
/// The mesh reaches exact resume for four Agents; an Agent it does not dispatch
/// has no durable dispatch identity for this query to validate, so the answer
/// stays the one [`ParserRegistration::unanswered`] states.
fn no_identity(_: &DurableIdentityRequest<'_>) -> bool {
    false
}

/// Hermes' normalized transitions for one execution outcome.
///
/// Hermes reports no transition list of its own, so it is the one Agent whose
/// transitions the host reads through the shared query. The host's Hermes
/// normalization read these two builders directly before the query moved behind
/// the contract, so the answer is the same one, reached without naming Hermes
/// above the parser boundary.
fn hermes_transitions(outcome: &ExecutionOutcome<'_>) -> Vec<Transition> {
    match outcome.failure {
        Some(failure) => hermes::failed_transitions(failure.code, failure.stage, failure.message),
        None => hermes::completed_transitions(outcome.output),
    }
}

/// Whether a Cursor chat identity is one that Agent's protocol accepts.
fn cursor_identity(request: &DurableIdentityRequest<'_>) -> bool {
    cursor::safe_session_id(request.session_id)
}

/// Whether an Antigravity Agent Hooks receipt identity is one that Agent's
/// protocol accepts.
fn antigravity_identity(request: &DurableIdentityRequest<'_>) -> bool {
    antigravity::valid_session_id(request.session_id)
}

/// Whether a Claude Code session identity is one that Agent's protocol accepts.
fn claude_code_identity(request: &DurableIdentityRequest<'_>) -> bool {
    opaque_identity(request.session_id)
}

/// The shared opaque-identity rule the mesh states for the Agents whose
/// protocols record no further evidence than the identity itself.
fn opaque_identity(session_id: &str) -> bool {
    licoup_agent_drivers::runtime_adapters::subagent_mesh::valid_opaque_identity(session_id)
}

/// The adapter declarations this host's thirteen Agent parsers report, in
/// `RuntimeAdapter` order.
///
/// This is the single list of the parsers this host carries: the registry
/// lookup, the dispatch admission and the packaged-inventory check all read it,
/// so an Agent parser is one entry rather than four lists that can drift.
///
/// An entry answers the two protocol-agnostic queries when a reader reaches it:
/// Hermes answers its normalized transitions, and the four Agents the Subagent
/// mesh dispatches answer whether a durable identity is theirs. Every other
/// entry declares its Agent's transition answer as *the parser's own execution
/// result* rather than through the query, and answers the identity query
/// fail-closed because the mesh never dispatches that Agent.
pub(in crate::platform) static REGISTRATIONS: [ParserRegistration; 13] = [
    ParserRegistration::new(
        antigravity::CONTRACT,
        no_transitions,
        antigravity_identity,
    ),
    ParserRegistration::new(
        claude_code::CONTRACT,
        no_transitions,
        claude_code_identity,
    ),
    // The Codex package answers both protocol-agnostic queries from its own recorded
    // evidence, so this entry is the package's own registration.
    licoup_agent_codex::registration::REGISTRATION,
    ParserRegistration::unanswered(copilot::CONTRACT),
    ParserRegistration::new(cursor::CONTRACT, no_transitions, cursor_identity),
    ParserRegistration::new(hermes::CONTRACT, hermes_transitions, no_identity),
    ParserRegistration::unanswered(kilo_code::CONTRACT),
    ParserRegistration::unanswered(kimi_code::CONTRACT),
    ParserRegistration::unanswered(openclaw::CONTRACT),
    ParserRegistration::unanswered(opencode::CONTRACT),
    // Pi's driver carries the parser's own transition list and the Subagent mesh
    // never dispatches it, so the package declares both queries unanswered.
    licoup_agent_pi::registration::REGISTRATION,
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
