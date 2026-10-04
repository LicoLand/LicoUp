//! The thirteen per-Agent parsers this host composes, and the parser set it
//! injects into the adapter SDK.
//!
//! `licoup-agent-adapter-sdk` owns the shared half — the byte-line ingress
//! contract, the adapter declaration, the transition vocabulary, the framing
//! and envelope helpers, the driver registry and the registry lookup. This tree
//! owns the other half: the per-Agent parsers the host still holds, and the
//! composition that names all thirteen and hands them to the SDK through
//! `AdapterParserSet`.
//!
//! Each subtree below is one Agent's protocol and moves with that Agent's crate
//! (`licoup-agent-<agent>`); the composition travels last, because it is what
//! tilts from naming thirteen parsers to naming the crates that hold them. Six
//! parsers have moved already and their subtrees are gone: the composition names
//! the package that owns each one, and no copy stays here.

pub(in crate::platform) use licoup_agent_adapter_sdk::adapters::{
    AdapterContract, NativeLineParser,
};
pub(in crate::platform) use licoup_agent_adapter_sdk::{
    LifecycleStage, Transition, TransitionReducer,
};

// The Antigravity package owns its Agent Hooks receipt, PTY parser and terminal
// classification; the driver that still supervises the vendor CLI reads them
// through this path, and the composition names the package for the registration
// and the replay arm that belong to the same parser.
pub(in crate::platform) use licoup_agent_antigravity::parser as antigravity;
// The Codex package owns the app-server vendor protocol below this port. Codex's
// parser is re-exported here because the host's Codex leaves still read it
// through this tree.
pub(in crate::platform) use licoup_agent_codex::parser as codex;
// The Cursor package owns the strict-NDJSON turn dialect and the wire vocabulary
// it reads; this composition reads them through the package's own module.
pub(in crate::platform) use licoup_agent_cursor::parser as cursor;
pub(in crate::platform) use licoup_agent_deepseek::parser as deepseek_harness;
// The Kimi Code package owns its ACP dialect and reaches this tree through its
// dialect registration in `runtime_adapters::drivers`, so the composition names
// the package's parser here for the registration it publishes.
pub(in crate::platform) use licoup_agent_kimi::parser as kimi_code;
// The Hermes package owns the persistent ACP dialect: the frame readers, the
// permission question Hermes asks and the transitions a Hermes turn reduces to.
// The composition names the package rather than keeping a second copy.
pub(in crate::platform) use licoup_agent_hermes::parser as hermes;

pub(in crate::platform) mod claude_code;
pub(in crate::platform) mod copilot;
pub(in crate::platform) mod kilo_code;
pub(in crate::platform) mod lico_agent;
pub(in crate::platform) mod openclaw;
pub(in crate::platform) mod opencode;
pub(in crate::platform) mod pi;

use licoup_agent_adapter_sdk::port::{
    AdapterParserSet, DurableIdentityRequest, ExecutionOutcome, ParserRegistration,
};

/// The fail-closed transition answer, for an Agent parser that reports its
/// transitions with its own execution result rather than through this query.
///
/// Every parser this host still holds answers that way: its driver carries the
/// `transitions` list the parser's own reducer built, so the query stays
/// declared and unanswered for it, exactly as
/// [`ParserRegistration::unanswered`] states. The six Agents whose protocol has
/// moved into its own package answer from the package's registration instead,
/// which is where each one's own transitions are worded.
fn no_transitions(_: &ExecutionOutcome<'_>) -> Vec<Transition> {
    Vec::new()
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
/// A moved Agent's entry is the package's own registration rather than a
/// constant restated here, so the declaration a package publishes and the
/// declaration this host dispatches are one value and cannot drift. Hermes'
/// entry is the package's for a second reason: Hermes reports no transition list
/// with its execution result, so its normalized transitions are the package's
/// own answer to the SDK's query — the host's Hermes normalization reads them
/// there rather than from a driver-side list. Every other entry this host still
/// holds declares its Agent's transition answer as *the parser's own execution
/// result* rather than through the query, and answers the identity query
/// fail-closed because the mesh never dispatches that Agent.
pub(in crate::platform) static REGISTRATIONS: [ParserRegistration; 13] = [
    // The Antigravity package answers both protocol-agnostic queries from its own
    // protocol facts — the identity rule is its parser's, and the transitions are
    // its own reply projection — so this entry is the package's own registration.
    licoup_agent_antigravity::registration::REGISTRATION,
    ParserRegistration::new(claude_code::CONTRACT, no_transitions, claude_code_identity),
    // The Codex package answers both protocol-agnostic queries from its own recorded
    // evidence, so this entry is the package's own registration.
    licoup_agent_codex::registration::REGISTRATION,
    ParserRegistration::unanswered(copilot::CONTRACT),
    // The Cursor package answers both queries from its own wire vocabulary — the
    // parser's own reply transitions and the session-id rule it binds with — so this
    // entry is the package's own registration rather than a second answer kept here.
    licoup_agent_cursor::registration::REGISTRATION,
    // The Hermes package owns the persistent ACP dialect and is the one Agent whose
    // normalized transitions the host reads through the query the package answers.
    licoup_agent_hermes::registration::REGISTRATION,
    ParserRegistration::unanswered(kilo_code::CONTRACT),
    // The Kimi Code package owns its dialect and reports its transitions with its
    // own execution result, so this entry is the package's own registration.
    licoup_agent_kimi::registration::REGISTRATION,
    ParserRegistration::unanswered(openclaw::CONTRACT),
    ParserRegistration::unanswered(opencode::CONTRACT),
    ParserRegistration::unanswered(pi::CONTRACT),
    ParserRegistration::unanswered(lico_agent::CONTRACT),
    // The DeepSeek Harness package answers its own registration, from the parser
    // and the session reader it owns; the mesh never dispatches this Agent, so
    // both SDK queries stay declared and unanswered exactly as before.
    licoup_agent_deepseek::registration::REGISTRATION,
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
