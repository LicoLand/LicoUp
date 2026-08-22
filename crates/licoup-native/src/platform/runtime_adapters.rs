mod adapter;
mod artifact;
mod dispatch;
pub mod error;
mod live_status;
mod model;
mod normalization;
mod params;
mod probe;
#[cfg(test)]
pub(crate) mod protocol_selector;
mod registry;

const RUNTIME_SCHEMA_VERSION: u32 = 3;
const DEFAULT_TIMEOUT_MS: u64 = 120_000;
const MIN_TIMEOUT_MS: u64 = 1_000;
const MAX_TIMEOUT_MS: u64 = 30 * 60 * 1_000;
const DEFAULT_MAX_STDERR_BYTES: usize = 512 * 1024;
// Keep the native dispatch clamp identical to the public subagent MCP bound.
// A lower hidden clamp turns an accepted budget into a misleading early
// output-limit failure and prevents exact native-session continuation.
const MAX_OUTPUT_BYTES: usize = 64 * 1024 * 1024;
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;

/// Dispatch implementations must stay in one-to-one correspondence with the
/// canonical target-adapters packaging registry. This is implementation
/// dispatch, not a readiness claim; release readiness is reduced separately.
pub(crate) const PACKAGED_RUNTIME_ADAPTER_IDS: &[&str] = &[
    "openclaw",
    "claude-code",
    "codex",
    "antigravity",
    "opencode",
    "copilot",
    "kilo-code",
    "cursor",
    "hermes",
    "kimi-code",
    "pi",
    "lico-agent",
];

pub(crate) use adapter::{RuntimeAdapter, adapter_for_agent_public, text_param_public};
pub use dispatch::send_message;
pub use error::RuntimeAdapterError;
pub(crate) use probe::probe_runtime_driver;
pub(crate) use registry::{
    adapter_management_catalog, inventory_capability_matrix, native_capabilities_for_agent,
    runtime_driver_profile,
};
pub use registry::{
    reload_conversation_readiness_document, reload_conversation_readiness_from_path,
};

#[cfg(test)]
mod tests;
