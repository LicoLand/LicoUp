//! The thirteen per-Agent parsers this host composes, and the parser set it
//! injects into the adapter SDK.
//!
//! `licoup-agent-adapter-sdk` owns the shared half — the byte-line ingress
//! contract, the adapter declaration, the transition vocabulary, the framing
//! and envelope helpers, the driver registry and the registry lookup. This tree
//! owns the other half: the composition that names all thirteen and hands them
//! to the SDK through `AdapterParserSet`.
//!
//! Every one of the thirteen has moved into the crate that owns it
//! (`licoup-agent-<agent>`), so no parser subtree stays here any more: the
//! composition names the package that holds each one, and no copy stays.

pub(in crate::platform) use licoup_agent_adapter_sdk::adapters::{
    AdapterContract, NativeLineParser,
};
pub(in crate::platform) use licoup_agent_adapter_sdk::{
    LifecycleStage, Transition, TransitionReducer,
};

// Antigravity's Agent Hooks receipt, PTY parser and terminal classification live
// in `licoup-agent-antigravity`. The driver that still supervises the vendor CLI
// reads them through this path, and the composition names the package for the
// registration and the replay arm that belong to the same parser.
pub(in crate::platform) use licoup_agent_antigravity::parser as antigravity;
// Cursor's vendor protocol has moved the same way, into `licoup-agent-cursor`: its
// strict-NDJSON turn dialect and the wire vocabulary it reads are the package's,
// and this composition reads them through the package's own module.
pub(in crate::platform) use licoup_agent_cursor::parser as cursor;
// Claude Code's, Codex's, Copilot's, the DeepSeek Harness SDK's, Hermes', Kilo
// Code's, Kimi Code's, Lico Agent's, OpenClaw's, OpenCode's and Pi's parsers
// moved into their own packages (`licoup-agent-claude-code`,
// `licoup-agent-codex`, `licoup-agent-copilot`, `licoup-agent-deepseek`,
// `licoup-agent-hermes`, `licoup-agent-kilo`, `licoup-agent-kimi`,
// `licoup-agent-lico-agent`, `licoup-agent-openclaw`, `licoup-agent-opencode`,
// `licoup-agent-pi`) as well, and this composition keeps no parser path for
// them: no alias is declared here and nothing under this parser tree re-exports
// one, so host code that still reads one of those parsers — as
// `deepseek_harness_driver` reads `licoup-agent-deepseek`'s, and Claude Code's
// driver reads `licoup-agent-claude-code`'s protocol module — names the package's
// own module instead. An alias nothing reads is a forwarding shell the compiler
// reports as an unused import, and each package answers its own registration
// below. Hermes' dialect reaches the shared ACP transport through the package's
// own registration in `runtime_adapters::drivers` rather than through this tree.
// OpenCode is the one parser this tree still re-exports: the host's
// `opencode_serve` facade and its `opencode_driver` leaves read `serve` frames
// through the `opencode` name, so the composition names the package's parser for
// them rather than rewriting every reader to the crate path. Pi is not: the
// whole Pi driver, its parser included, is `licoup-agent-pi`'s, and the host
// declares no Pi reader of its own to name it for.
pub(in crate::platform) use licoup_agent_opencode::parser as opencode;

use licoup_agent_adapter_sdk::port::{
    AdapterParserSet, DurableIdentityRequest, ExecutionOutcome, ParserRegistration,
};

/// The fail-closed transition answer, for an Agent parser that reports its
/// transitions with its own execution result rather than through this query.
///
/// A parser that reports its transitions that way carries the `transitions`
/// list its own reducer built, so the query stays declared and unanswered for
/// it, exactly as [`ParserRegistration::unanswered`] states. Every parser whose
/// protocol has moved into its own package answers from the package's
/// registration instead, which is where each one's own transitions are worded —
/// including
/// Hermes, whose normalized transitions the host reads through that query.
fn no_transitions(_: &ExecutionOutcome<'_>) -> Vec<Transition> {
    Vec::new()
}

/// Whether a Cursor chat identity is one that Agent's protocol accepts.
fn cursor_identity(request: &DurableIdentityRequest<'_>) -> bool {
    cursor::safe_session_id(request.session_id)
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
/// the Agents the Subagent mesh dispatches answer whether a durable identity is
/// theirs, and every Agent's protocol has moved into its own package, so every
/// entry is the package's own registration — which answers both queries from
/// that Agent's wire evidence. Hermes' entry is the package's for a second
/// reason: Hermes reports no transition list with its execution result, so its
/// normalized transitions are the package's own answer to the SDK's query — the
/// host's Hermes normalization reads them there rather than from a driver-side
/// list. Every other entry declares its Agent's transition answer as *the
/// parser's own execution result* rather than through the query, and answers the
/// identity query fail-closed because the mesh never dispatches that Agent.
///
/// Thirteen entries are the moved packages' own registrations rather than constants
/// restated here, so the declaration a package publishes and the declaration
/// this host dispatches are one value and cannot drift.
pub(in crate::platform) static REGISTRATIONS: [ParserRegistration; 13] = [
    // The Antigravity package answers both protocol-agnostic queries from its own
    // protocol facts — the identity rule is its parser's, and the transitions are
    // its own reply projection — so this entry is the package's own registration.
    licoup_agent_antigravity::registration::REGISTRATION,
    // The Claude Code package answers both queries from its own recorded evidence,
    // so this entry is the package's own registration rather than a second copy.
    licoup_agent_claude_code::registration::REGISTRATION,
    // The Codex package answers both protocol-agnostic queries from its own recorded
    // evidence, so this entry is the package's own registration.
    licoup_agent_codex::registration::REGISTRATION,
    // The Copilot package answers those two queries fail-closed — its driver
    // carries its own transition list and the Subagent mesh never dispatches it —
    // so this entry is the package's own registration, reached without a second
    // declaration here.
    licoup_agent_copilot::registration::REGISTRATION,
    // The Cursor package answers both queries from its own wire vocabulary — the
    // parser's own reply transitions and the session-id rule it binds with — so this
    // entry is the package's own registration rather than a second answer kept here.
    licoup_agent_cursor::registration::REGISTRATION,
    // The Hermes package owns the persistent ACP dialect and is the one Agent whose
    // normalized transitions the host reads through the query the package answers.
    licoup_agent_hermes::registration::REGISTRATION,
    // The Kilo Code package answers both protocol-agnostic queries from its own
    // parser, so this entry is the package's own registration rather than a
    // fail-closed placeholder.
    licoup_agent_kilo::registration::REGISTRATION,
    // The Kimi Code package owns its dialect and reports its transitions with its
    // own execution result, so this entry is the package's own registration.
    licoup_agent_kimi::registration::REGISTRATION,
    // The OpenClaw package answers its own registration, from the parser it owns;
    // both protocol-agnostic queries stay declared and fail-closed exactly as the
    // host answered them before the parser moved.
    licoup_agent_openclaw::registration::REGISTRATION,
    // The OpenCode package owns the `serve` protocol and reports its transitions
    // with its own execution result, so this entry is the package's own
    // registration.
    licoup_agent_opencode::registration::REGISTRATION,
    // Pi's driver carries the parser's own transition list and the Subagent mesh
    // never dispatches it, so the package declares both queries unanswered.
    licoup_agent_pi::registration::REGISTRATION,
    // The Lico Agent package owns its stdio RPC protocol and reports its
    // transitions with its own execution result, and the mesh never dispatches
    // this Agent, so this entry is the package's own registration.
    licoup_agent_lico_agent::registration::REGISTRATION,
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
