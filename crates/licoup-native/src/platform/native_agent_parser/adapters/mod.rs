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

pub(in crate::platform) mod antigravity;
pub(in crate::platform) mod claude_code;
pub(in crate::platform) mod codex;
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
/// entry names its Agent's declaration and leaves the two protocol-agnostic
/// queries unanswered — see `native_agent_parser`'s authority statement for
/// which Node composes those answers.
pub(in crate::platform) static REGISTRATIONS: [ParserRegistration; 13] = [
    ParserRegistration::new(
        antigravity::CONTRACT,
        unanswered_transitions,
        antigravity_identity,
    ),
    ParserRegistration::new(
        claude_code::CONTRACT,
        unanswered_transitions,
        claude_code_identity,
    ),
    ParserRegistration::new(codex::CONTRACT, codex_transitions, codex_identity),
    ParserRegistration::unanswered(copilot::CONTRACT),
    ParserRegistration::new(cursor::CONTRACT, cursor_transitions, cursor_identity),
    ParserRegistration::new(hermes::CONTRACT, hermes_transitions, unanswered_identity),
    ParserRegistration::unanswered(kilo_code::CONTRACT),
    ParserRegistration::unanswered(kimi_code::CONTRACT),
    ParserRegistration::unanswered(openclaw::CONTRACT),
    ParserRegistration::new(
        opencode::CONTRACT,
        opencode_transitions,
        unanswered_identity,
    ),
    ParserRegistration::unanswered(pi::CONTRACT),
    ParserRegistration::unanswered(lico_agent::CONTRACT),
    ParserRegistration::unanswered(deepseek_harness::CONTRACT),
];

/// The failure half of one execution outcome, in the four places that read it.
///
/// Each Agent's transition builder takes the failure's facts as separate
/// arguments, so this projects the shared outcome onto them once rather than
/// four times.
fn failure_of<'a>(
    outcome: &'a licoup_agent_adapter_sdk::port::ExecutionOutcome<'a>,
) -> (&'a str, &'a str, &'a str) {
    match outcome.failure {
        Some(failure) => (failure.code, failure.stage, failure.message),
        None => ("", "", ""),
    }
}

/// An Agent that does not yet answer the transition query. Fail-closed: no
/// transition is invented on its behalf, and no production reader reads one.
///
/// The host reads these through the SDK's protocol-agnostic query, so an Agent
/// whose builders are named below answers for itself and the host stops naming
/// it. An Agent answered here composes nothing that a call site needs yet.
fn unanswered_transitions(
    _outcome: &licoup_agent_adapter_sdk::port::ExecutionOutcome<'_>,
) -> Vec<Transition> {
    Vec::new()
}

/// An Agent that does not answer the identity query. Fail-closed.
fn unanswered_identity(
    _request: &licoup_agent_adapter_sdk::port::DurableIdentityRequest<'_>,
) -> bool {
    false
}

fn hermes_transitions(
    outcome: &licoup_agent_adapter_sdk::port::ExecutionOutcome<'_>,
) -> Vec<Transition> {
    match outcome.failure {
        Some(failure) => {
            hermes::failed_transitions(failure.code, failure.stage, failure.message)
        }
        None => hermes::completed_transitions(outcome.output),
    }
}

fn codex_transitions(
    outcome: &licoup_agent_adapter_sdk::port::ExecutionOutcome<'_>,
) -> Vec<Transition> {
    match outcome.failure {
        Some(_) => {
            let (code, stage, message) = failure_of(outcome);
            codex::failure_transitions(code, stage, message)
        }
        None => codex::completed_transitions(outcome.output),
    }
}

fn cursor_transitions(
    outcome: &licoup_agent_adapter_sdk::port::ExecutionOutcome<'_>,
) -> Vec<Transition> {
    match outcome.failure {
        Some(_) => {
            let (code, stage, message) = failure_of(outcome);
            cursor::failure_transitions(code, stage, message)
        }
        None => cursor::completed_transitions(outcome.output),
    }
}

fn opencode_transitions(
    outcome: &licoup_agent_adapter_sdk::port::ExecutionOutcome<'_>,
) -> Vec<Transition> {
    match outcome.failure {
        Some(_) => {
            let (code, stage, message) = failure_of(outcome);
            opencode::failure_transitions(code, stage, message)
        }
        None => opencode::completed_transitions(outcome.output),
    }
}

/// Codex's durable identity: the recorded rollout record when the binding
/// carries a native location, the opaque identity otherwise.
fn codex_identity(request: &licoup_agent_adapter_sdk::port::DurableIdentityRequest<'_>) -> bool {
    match request.location {
        Some(location) => codex::session::rollout_record_identity(location)
            .is_ok_and(|recorded| recorded == request.session_id),
        None => opaque_identity(request.session_id),
    }
}

/// Cursor's durable identity: its own chat-id shape.
fn cursor_identity(request: &licoup_agent_adapter_sdk::port::DurableIdentityRequest<'_>) -> bool {
    cursor::safe_session_id(request.session_id)
}

/// Antigravity's durable identity: its own receipt-id shape.
fn antigravity_identity(
    request: &licoup_agent_adapter_sdk::port::DurableIdentityRequest<'_>,
) -> bool {
    antigravity::valid_session_id(request.session_id)
}

/// Claude Code's durable identity: a bounded opaque identifier.
fn claude_code_identity(
    request: &licoup_agent_adapter_sdk::port::DurableIdentityRequest<'_>,
) -> bool {
    opaque_identity(request.session_id)
}

/// The shared opaque-identity rule. It is the host's own bound on an identity it
/// did not mint, kept in one place so the Agents that use it cannot drift.
fn opaque_identity(session_id: &str) -> bool {
    crate::platform::runtime_adapters::subagent_mesh::valid_opaque_identity(session_id)
}

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
