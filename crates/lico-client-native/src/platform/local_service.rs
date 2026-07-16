//! Target-neutral, bounded primitives for client-owned local agent services.
//!
//! HTTP/SSE transport and detached-service lifecycle live here. ACP JSONL is
//! intentionally owned by `core::acp` and must not be coupled to this module.

mod bounds;
mod concurrency;
mod endpoint;
pub(super) mod executable;
pub(super) mod http;
pub(super) mod params;
pub(super) mod port;
pub(super) mod process;
pub(super) mod serve;
pub(super) mod sse;
pub(super) mod state;

pub use endpoint::ServeEndpoint;
pub(super) use serve::{ServeErrorCodes, ServeSpec};

#[cfg(test)]
mod tests;
