//! Target-neutral, bounded primitives for client-owned local agent services.
//!
//! HTTP/SSE transport and detached-service lifecycle live here. ACP JSONL is
//! intentionally owned by `core::acp` and must not be coupled to this module.

mod bounds;
mod concurrency;
mod endpoint;
pub mod executable;
pub mod http;
pub mod params;
pub mod port;
pub mod process;
pub mod serve;
pub mod sse;
pub mod state;
pub mod turn_control;

pub use endpoint::ServeEndpoint;
pub use endpoint::{ServeAttachment, ServeModel, ServeModelCatalog, ServeReadiness};
pub use serve::{ServeErrorCodes, ServeSpec};

#[cfg(test)]
mod tests;
