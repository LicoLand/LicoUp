// Process, IO, path, network-boundary, user-presence, record and archive
// primitives now live in `licoup-foundation`. The modules whose former paths
// this crate still reads keep a re-export here; `url_security`,
// `user_presence` and `authorized_secure_record` are named at their foundation
// path by the callers in this crate.
#[cfg(unix)]
pub(in crate::platform) use licoup_foundation::platform::pty_transport;
pub(in crate::platform) use licoup_foundation::platform::{
    native_agent_interaction, process_supervisor, turn_event_emit,
};
pub(crate) use licoup_foundation::platform::{agent_workspace, ansi_stripper};
pub use licoup_foundation::platform::{
    diagnostics, file_security, paths, process_sandbox, raw_execution, user_shell_environment,
};

// The untrusted BadTower station adapter lives in `licoup-relay` with the relay
// transport it carries. Its only former reader in this crate was the relay
// family test prelude, which moved to that crate, so no re-export is kept here.

// The ACP process runtime, the ACP session transport and the local service
// control plane moved to `licoup-agent-drivers`, which is now the single
// authority for ACP session transport. The former module paths stay reachable
// here at the visibility this host exposed before the trees moved, so no
// per-Agent driver in this host has to name the new crate.
pub(crate) use licoup_agent_drivers::acp_driver_runtime;
pub(crate) use licoup_agent_drivers::acp_session_transport;
pub(crate) use licoup_agent_drivers::local_service;
pub(crate) mod antigravity_driver;
mod claude_code_driver;
mod codex_app_server;
pub(crate) mod codex_runtime_observation;
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
mod native_agent_parser;
mod openclaw_driver;
mod opencode_driver;
mod pi_driver;
pub(crate) mod remote_acp_history;
pub(crate) mod remote_hermes_gateway_history;
pub(crate) mod strategy_runtime;
pub(crate) mod virtual_machine;
pub mod work_context_ports;

pub mod catalog_cache_store;
pub mod client_autostart;
pub mod client_state;
pub mod codex_plugin_manager;
pub mod conversation_host_client;
pub mod conversation_host_transport;
pub mod gateway_runtime;
pub mod llm_api_key_vault;
pub mod llm_gateway_autostart;
pub mod llm_gateway_client_auth;
pub mod llm_gateway_credentials_control;
pub mod llm_gateway_inventory_control;
pub mod llm_gateway_server;
pub mod llm_gateway_service;
pub mod llm_gateway_transport;
pub mod llm_gateway_usage;
pub mod openclaw_gateway;
pub mod opencode_serve;
pub mod runtime_adapters;
pub mod subagent_mcp_ensure;

// The endpoint capability probe moved to `licoup-secure-mesh`; the former path
// stays reachable through this re-export for the composition that reports it.
pub use licoup_secure_mesh::platform::secure_mesh_capability_probe;

// The secret store and the group (MLS) durable-store composition moved to
// `licoup-secure-mesh` with the code and the state machine they own. The former
// paths stay reachable at the module visibility this crate exposed before the
// move, so the callers that are extracted by later Nodes keep compiling without
// naming the new crate.
pub use licoup_secure_mesh::platform::secure_mesh_secret_store;

// The MCP registry, transport and approval modules moved to `licoup-mcp`. The
// former paths stay reachable through this re-export, so the Agent-layer modules
// that are extracted later keep compiling without naming the new crate; the
// module visibility this crate exposed before the move is preserved.
pub(crate) use licoup_mcp::{mcp_approval_plan_store, mcp_streamable_http, provider_mcp_registration};
pub use licoup_mcp::{
    antigravity_subagent_mcp_manager, claude_code_subagent_mcp_manager,
    cursor_subagent_mcp_manager, mcp_service_process,
};

pub use acp_session_transport::resolve_interaction_approval as resolve_native_agent_interaction_approval;
pub(crate) use codex_app_server::list_models as codex_app_server_model_catalog;
pub use conversation_lane::{
    cancel_turn, cleanup_conversation, dispatch_lane_operation, lane_capabilities, open_or_resume,
};
pub use native_agent_interaction::resolve as resolve_native_agent_interaction;
pub use native_agent_interaction::resolve_scoped as resolve_scoped_native_agent_interaction;
pub use turn_event_emit::{
    StreamSinkGuard, clear_stream_sink, emit_agent_message_chunk, emit_agent_message_completed,
    emit_agent_processing, emit_turn_event, install_stdout_ndjson_sink, install_stream_sink,
};

pub(crate) use process_supervisor::{
    configure_untrusted_agent_command, run_bounded_command_input, run_bounded_command_output,
    run_bounded_untrusted_agent_output,
};
