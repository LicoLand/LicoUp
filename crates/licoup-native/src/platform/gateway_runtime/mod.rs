//! Two-layer Gateway Runtime: LLM Gateway (lower) + Communication Channel (upper).

pub mod channels;
mod serve;
pub mod service;

pub use channels::channel_layer_status;
pub use channels::telegram;
pub use serve::{GatewayServeArgs, serve_gateway_runtime};
pub use service::{
    REPORT_SCHEMA, reload_conversation_inventory, service_initialize, service_start,
    service_status, service_stop, state_directory,
};
