mod acp_driver_runtime;
mod acp_session_transport;
pub(crate) mod antigravity_driver;
// Linux keeps the fail-closed adapter surface without a native record backend.
#[cfg_attr(target_os = "linux", allow(dead_code))]
pub mod authorized_secure_record;
mod claude_code_driver;
mod codex_app_server;
mod conversation_lane;
mod copilot_driver;
mod cursor_driver;
mod hermes_driver;
mod kilo_code_driver;
mod kilo_code_serve;
mod kimi_code_driver;
mod local_service;
pub(crate) mod mcp_approval_plan_store;
pub(crate) mod mcp_streamable_http;
mod openclaw_driver;
mod opencode_driver;
pub mod orchestrator_control_plane;
pub mod orchestrator_ipc;
pub mod orchestrator_service;
mod pi_driver;
mod process_supervisor;
pub(crate) mod secure_mesh_mls_store;
mod skill_invocation_projection;
mod turn_event_emit;
pub(crate) mod user_presence;

pub mod catalog_cache_store;
pub mod client_state;
pub mod file_security;
pub mod openclaw_gateway;
pub mod opencode_serve;
pub mod paths;
pub mod runtime_adapters;
pub mod secure_client_relay;
pub mod secure_mesh_capability_probe;
pub mod secure_mesh_secret_store;
pub mod url_security;

pub use conversation_lane::{
    cancel_turn, cleanup_conversation, dispatch_lane_operation, lane_capabilities, open_or_resume,
    shutdown_all_conversations,
};
pub use hermes_driver::resolve_parked_permission as hermes_resolve_parked_permission;
pub use turn_event_emit::{
    StreamSinkGuard, clear_stream_sink, emit_agent_message_chunk, emit_agent_message_completed,
    emit_turn_event, install_stdout_ndjson_sink, install_stream_sink,
};

pub(crate) use process_supervisor::run_bounded_command_output;
