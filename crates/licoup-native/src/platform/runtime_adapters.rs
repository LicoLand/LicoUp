//! This host's composition of the adapter registry and adapter execution.
//!
//! `licoup-agent-drivers` owns the host side of Agent execution — the adapter
//! registry, the declarations as data, the dispatch admission, the execution
//! normalization, the Subagent MCP mesh and the work-context seam — and
//! declares the ports it reads every Agent and its own lanes through. This
//! module is the composition above it: it answers those ports with the
//! implementations this host has today, and it keeps every former
//! `platform::runtime_adapters` path reachable through the re-exports below.
//!
//! What it answers, and where each answer travels next:
//!
//! * the thirteen per-Agent driver halves — probe, execution and normalization
//!   — in [`drivers`], which move to `licoup-agent-<agent>` when those crates
//!   exist, exactly as `platform::work_context_ports`' two halves do;
//! * this host's own conversation lane, its generic CLI fallback lane, its
//!   Subagent caller manager and its cleanup entry point, in [`host_lane`],
//!   none of which is any Agent's protocol;
//! * the endpoint layer's client-error projection, in [`client_error`], which
//!   travels with the endpoint crate when `ffi/` extracts.
//!
//! Nothing here restores a vendor branch to the moved crate: it names no Agent,
//! and every per-Agent fact is reached through the port.

pub mod client_error;
pub(crate) mod dialects;
pub(crate) mod drivers;
mod host_lane;

// The host's own suites for the adapter registry and adapter execution. They
// exercise the *composed* host — the thirteen per-Agent arms this file
// answers the moved crate's port with — so they live with the composition
// while the arms do, and they return to `licoup-agent-drivers` when the arms
// move to the `licoup-agent-<agent>` crates at NODEs 038-040.
#[cfg(test)]
mod tests;

use std::path::Path;
use std::sync::OnceLock;

use licoup_agent_targets::port::AgentTargetPort;
use serde_json::Value;

// Every former path of the host's adapter registry and adapter execution stays
// reachable here, at the visibility this host exposed before the tree moved.
pub use licoup_agent_drivers::runtime_adapters::{
    GeneratedInstructionDelivery, MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE,
    MAX_IMAGE_ATTACHMENT_BYTES_TOTAL, MAX_IMAGE_ATTACHMENTS, PACKAGED_RUNTIME_ADAPTER_IDS,
    RUNTIME_SCHEMA_VERSION, RuntimeAdapter, RuntimeAdapterError, RuntimeLane, adapter,
    adapter_for_agent_public,
    adapter_management_catalog, artifact, attachment_media_type_supported,
    compose_generated_instruction_delivery, dispatch, error, has_runtime_lane,
    inventory_capability_matrix, live_status, model, native_capabilities_for_agent, normalization,
    params, port, probe, production_subagent_registry, registry,
    reload_conversation_readiness_document, reload_conversation_readiness_from_path, root_cause,
    runtime_driver_profile, runtime_lane_for_agent, subagent_mesh, text_param_public,
};
pub use licoup_agent_drivers::runtime_adapters::subagent_mesh::{
    apply_mcp_runtime_root, apply_subagent_caller_context,
};
pub use licoup_agent_drivers::runtime_adapters::send_message as dispatch_send_message;
#[cfg(any(test, feature = "test-support"))]
pub use licoup_agent_drivers::runtime_adapters::protocol_selector;
pub use licoup_agent_drivers::runtime_adapters::probe::probe_runtime_driver as probe_through_port;

/// Install this host's composition into the moved crate, once.
///
/// The moved crate reads every Agent, its own lane, its parser set and its
/// fallback lane through the port, so the installation happens at this host's
/// own entry points rather than at each caller. It is idempotent: the first
/// installation wins, so a running turn cannot have the answers under it
/// replaced.
pub(crate) fn install() {
    static INSTALLED: OnceLock<bool> = OnceLock::new();
    INSTALLED.get_or_init(|| {
        // The ACP frame dialects the transport engines read Agents through.
        // They are installed here rather than declared in the moved crate,
        // because naming which Agent speaks which dialect is this composition's
        // job and the moved crate names no Agent.
        licoup_agent_drivers::acp_driver_runtime::parser_port::install(drivers::acp_dialects().to_vec());
        port::install(port::HostComposition {
            target_port: || Some(crate::target_port::agent_target_port()),
            parser_set: crate::platform::native_agent_parser::parser_set,
            drivers: drivers::registrations(),
            conversation_host: host_lane::conversation_host(),
            generic_cli: host_lane::generic_cli(),
            collaboration_mcp: host_lane::collaboration_mcp(),
            caller_manager: host_lane::caller_manager(),
            caller_config: host_lane::caller_config(),
            dispatch_timeout: crate::domain::dispatch_timeout_policy::resolve_dispatch_timeout,
            declared_capability_flag:
                crate::platform::conversation_lane::declared_capability_flag,
            codex_plugin_installation_state: host_lane::codex_plugin_installation_state,
            cleanup_conversation: host_lane::cleanup_conversation,
        })
    });
}

/// Dispatch one Agent turn, exactly as this host dispatched it before the tree
/// moved.
pub fn send_message(port: &AgentTargetPort, params: &Value) -> Result<Value, RuntimeAdapterError> {
    install();
    dispatch_send_message(port, params)
}

/// Probe one Agent's executable, exactly as this host probed it before the tree
/// moved.
pub fn probe_runtime_driver(target: &str, executable: &Path, cwd: &Path) -> Value {
    install();
    probe_through_port(target, executable, cwd)
}

/// The parser registration one Agent reports, for the composition's own use.
pub(crate) fn registrations_parser(
    agent_id: &str,
) -> licoup_agent_adapter_sdk::port::ParserRegistration {
    install();
    drivers::parser_for_agent(agent_id)
}

/// This host's conversation-lane control entry point, as the Subagent mesh
/// reaches it.
pub fn cleanup_conversation(params: &Value) -> Result<Value, String> {
    install();
    host_lane::cleanup_conversation(params)
}
