//! Gateway Runtime: the LLM Gateway (lower) and Communication Channels (upper).
//!
//! The runtime reaches conversations, credential custody and verified readiness
//! only through the ports of `licoup-gateway-core`; the composing host installs
//! them once per process.

pub mod channels;
pub mod http;
pub mod runtime;

pub use runtime::{GatewayServeArgs, serve_gateway_runtime};
