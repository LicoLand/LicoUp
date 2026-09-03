mod acp_driver_runtime;
pub(in crate::platform) mod acp_session_transport;
pub(crate) mod agent_workspace;
pub(crate) mod antigravity_driver;
pub(crate) mod badtower_station;
// Linux keeps the fail-closed adapter surface without a native record backend.
#[cfg_attr(target_os = "linux", allow(dead_code))]
pub mod authorized_secure_record;
mod claude_code_driver;
mod codex_app_server;
pub(crate) mod codex_runtime_observation;
mod conversation_lane;
mod copilot_driver;
mod cursor_driver;
mod deepseek_harness_driver;
mod hermes_driver;
pub(crate) mod hermes_tui_gateway;
mod hermes_tui_gateway_driver;
mod kilo_code_driver;
mod kilo_code_serve;
mod kimi_code_driver;
mod lico_agent_driver;
mod local_service;
pub(crate) mod mcp_approval_plan_store;
pub(crate) mod mcp_streamable_http;
mod native_agent_interaction;
mod native_agent_parser;
mod openclaw_driver;
mod opencode_driver;
mod pi_driver;
pub mod process_sandbox;
mod process_supervisor;
pub(crate) mod provider_mcp_registration;
#[cfg(unix)]
mod pty_transport;
pub(crate) mod remote_acp_history;
pub(crate) mod remote_hermes_gateway_history;
pub(crate) mod secure_mesh_mls_store;
pub(crate) mod skill_invocation_projection;
pub(crate) mod strategy_runtime;
mod turn_event_emit;
pub(crate) mod user_presence;
pub(crate) mod virtual_machine;

pub mod antigravity_subagent_mcp_manager;
pub mod catalog_cache_store;
pub mod client_autostart;
pub mod client_state;
pub mod codex_plugin_manager;
pub mod conversation_host_transport;
pub mod cursor_subagent_mcp_manager;
pub mod file_security;
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
pub mod paths;
pub mod runtime_adapters;
pub mod secure_mesh_capability_probe;
pub mod secure_mesh_secret_store;
pub mod subagent_mcp_ensure;
pub(crate) mod subagent_mcp_host_client;
pub mod subagent_mcp_supervisor;
pub mod url_security;

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
