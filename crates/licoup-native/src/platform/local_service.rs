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
pub(super) mod turn_control;

pub use endpoint::ServeEndpoint;
pub(super) use endpoint::{ServeAttachment, ServeModel, ServeModelCatalog, ServeReadiness};
pub(super) use serve::{ServeErrorCodes, ServeSpec};

pub(in crate::platform) fn service_paths(state_dir: &str) -> anyhow::Result<state::ServicePaths> {
    state::ServicePaths::resolve(state_dir, "serve.pid")
}

pub(in crate::platform) fn read_service_state(
    paths: &state::ServicePaths,
) -> anyhow::Result<serde_json::Value> {
    state::read_json(&paths.state_path, "local_service_state_invalid")
}

pub(in crate::platform) fn service_pid(paths: &state::ServicePaths) -> anyhow::Result<Option<u32>> {
    state::read_pid(&paths.pid_path)
}

pub(in crate::platform) fn process_alive(pid: u32) -> bool {
    process::alive(Some(pid))
}

/// The in-flight turns one local service endpoint is currently running. The
/// confirmation dialog names these tasks; force stop never guesses them.
pub(in crate::platform) fn active_endpoint_turns(attach_url: &str) -> Vec<(String, String)> {
    turn_control::active_turns_for_endpoint(attach_url)
}

#[cfg(test)]
mod tests;
