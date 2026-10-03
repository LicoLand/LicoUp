// The ACP engines and the local-service control plane live in
// `licoup-agent-drivers`; these paths stay reachable at the visibility this
// host exposed before they moved.
pub(crate) use licoup_agent_drivers::{acp_driver_runtime, acp_session_transport};
// The bounded-workspace selection is a foundation primitive; this path stays
// reachable at the visibility this host exposed before it moved.
pub use licoup_foundation::platform::agent_workspace;
// The turn-event bus, the raw-execution observer and the native interaction
// registry are foundation primitives; these paths stay reachable at the
// visibility this host exposed before they moved.
pub use licoup_foundation::platform::native_agent_interaction;
pub use licoup_foundation::platform::raw_execution;
pub use licoup_foundation::platform::turn_event_emit;
pub(crate) mod antigravity_driver;
#[cfg_attr(target_os = "linux", allow(dead_code))]
pub mod authorized_secure_record;
pub(crate) mod badtower_station;
mod claude_code_driver;
pub(crate) mod conversation_lane;
mod copilot_driver;
mod cursor_driver;
mod deepseek_harness_driver;
pub mod extension_host;
pub mod extension_packages;
pub(crate) mod generic_cli_driver;
mod hermes_driver;
pub(crate) mod hermes_tui_gateway;
mod hermes_tui_gateway_driver;
mod kilo_code_driver;
mod kilo_code_serve;
mod kimi_code_driver;
mod lico_agent_driver;
pub(crate) use licoup_agent_drivers::local_service;
pub(crate) mod mcp_approval_plan_store;
pub(crate) mod mcp_streamable_http;
mod native_agent_parser;
mod openclaw_driver;
mod opencode_driver;
mod pi_driver;
pub mod process_sandbox;
pub(crate) mod provider_mcp_registration;
#[cfg(unix)]
mod pty_transport;
pub(crate) mod remote_acp_history;
pub(crate) mod remote_hermes_gateway_history;
pub(crate) mod secure_mesh_mls_store;
pub mod stop_control;
pub(crate) mod strategy_runtime;
pub(crate) mod user_presence;
pub mod user_shell_environment;
pub(crate) mod virtual_machine;
pub mod work_context_ports;

pub mod antigravity_subagent_mcp_manager;
pub mod catalog_cache_store;
pub mod claude_code_subagent_mcp_manager;
pub mod client_autostart;
pub mod client_state;
pub mod conversation_host_client;
pub mod conversation_host_transport;
pub mod cursor_subagent_mcp_manager;
pub mod data_home_relocation;
pub mod gateway_composition;
pub mod gateway_runtime;
pub mod llm_api_key_vault;
pub mod llm_gateway_autostart;
pub mod llm_gateway_service;
pub mod mcp_service_process;
pub mod openclaw_gateway;
pub mod opencode_serve;
pub mod runtime_adapters;
pub mod secure_mesh_capability_probe;
pub mod secure_mesh_secret_store;
pub mod subagent_mcp_ensure;

pub use acp_session_transport::resolve_interaction_approval as resolve_native_agent_interaction_approval;
pub use conversation_lane::{
    cancel_turn, cleanup_conversation, dispatch_lane_operation, lane_capabilities, open_or_resume,
};
pub use native_agent_interaction::resolve as resolve_native_agent_interaction;
pub use native_agent_interaction::resolve_scoped as resolve_scoped_native_agent_interaction;
pub use turn_event_emit::{
    StreamSinkGuard, clear_stream_sink, emit_agent_message_chunk, emit_agent_message_completed,
    emit_agent_processing, emit_turn_event, install_stdout_ndjson_sink, install_stream_sink,
};

/// This host's answer for the Codex adapter package's turn-event port.
///
/// The package owns *what* one Codex turn emits; this host owns *where* it goes,
/// because the host owns the consumer. The answer is this host's own emitter
/// rather than a second sink, so a Codex event and a Cursor event reach the same
/// reader through the same path.
pub(crate) fn codex_turn_event_port() -> licoup_agent_codex::port::turn_event::TurnEventPort {
    licoup_agent_codex::port::turn_event::TurnEventPort {
        emit: emit_turn_event,
    }
}

/// The environment one Codex app-server child is launched with.
///
/// The user's own login shell is the default command authority (ADR 0007), so
/// the child is cleared to exactly that snapshot rather than inheriting this
/// process's environment. The package applies the set; this host owns where it
/// came from.
pub(crate) fn codex_app_server_environment() -> Vec<(String, String)> {
    user_shell_environment::snapshot()
        .iter()
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

// The bounded process owner moved to `licoup-foundation`. It is re-exported at
// its former path and former visibility, because the driver engines, the
// sandboxed execution helpers and the Agent inventory all supervise the same
// child processes and one implementation serves them all.
pub(crate) use licoup_foundation::platform::process_supervisor;
pub(crate) use licoup_foundation::platform::process_supervisor::{
    configure_untrusted_agent_command, run_bounded_command_input, run_bounded_command_output,
    run_bounded_untrusted_agent_output,
};
