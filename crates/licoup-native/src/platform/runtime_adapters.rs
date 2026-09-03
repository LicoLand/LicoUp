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
pub(crate) mod protocol_selector {
    pub use licoup_agent_runtime::protocol_selector::*;
}
mod registry;
mod subagent_mesh;

// Public host-neutral L4/L5 contracts. Concrete drivers remain composed in
// this native host until their individually owned modules can move without
// crossing concurrent ownership boundaries.
pub use licoup_agent_runtime::{PersistentTurnRuntime, RuntimeDriver, RuntimeDriverRegistry};

const RUNTIME_SCHEMA_VERSION: u32 = 3;
const MIN_TIMEOUT_MS: u64 = 1_000;
const MAX_TIMEOUT_MS: u64 = 30 * 60 * 1_000;
const DEFAULT_MAX_STDERR_BYTES: usize = 512 * 1024;
// Keep the native dispatch clamp identical to the public subagent MCP bound.
// A lower hidden clamp turns an accepted budget into a misleading early
// output-limit failure and prevents exact native-session continuation.
const MAX_OUTPUT_BYTES: usize = 64 * 1024 * 1024;

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
    "deepseek-harness",
];

pub(crate) use adapter::{RuntimeAdapter, adapter_for_agent_public, text_param_public};
pub use dispatch::send_message;
pub use error::RuntimeAdapterError;
pub(crate) use params::{
    MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE, MAX_IMAGE_ATTACHMENT_BYTES_TOTAL, MAX_IMAGE_ATTACHMENTS,
    attachment_media_type_supported,
};
pub(crate) use probe::probe_runtime_driver;
pub(crate) use registry::{
    adapter_management_catalog, inventory_capability_matrix, native_capabilities_for_agent,
    runtime_driver_profile,
};
pub use registry::{
    reload_conversation_readiness_document, reload_conversation_readiness_from_path,
};
pub(crate) use subagent_mesh::{
    apply_mcp_runtime_root, apply_subagent_caller_context, production_subagent_registry,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GeneratedInstructionDelivery {
    pub text: String,
    pub field: Option<&'static str>,
    pub guidance: Option<String>,
}

/// Compose generated guidance for one explicitly declared adapter policy.
/// The canonical Event text is supplied separately and remains unchanged.
pub fn compose_generated_instruction_delivery(
    agent_id: &str,
    user_text: &str,
    guidance: Option<&str>,
) -> Result<GeneratedInstructionDelivery, &'static str> {
    let Some(guidance) = guidance else {
        return Ok(GeneratedInstructionDelivery {
            text: user_text.to_owned(),
            field: None,
            guidance: None,
        });
    };
    let Some(adapter) = adapter_for_agent_public(agent_id) else {
        #[cfg(test)]
        {
            return Ok(GeneratedInstructionDelivery {
                text: format!("{guidance}\n\n{user_text}"),
                field: None,
                guidance: None,
            });
        }
        #[cfg(not(test))]
        return Err("runtime_instruction_policy_undeclared");
    };
    let policy = match adapter {
        RuntimeAdapter::Codex => {
            licoup_agent_runtime::InstructionPolicy::NativeDeveloperInstructions
        }
        RuntimeAdapter::Cursor | RuntimeAdapter::Antigravity => {
            licoup_agent_runtime::InstructionPolicy::OrdinaryWirePrefix
        }
        RuntimeAdapter::ClaudeCode
        | RuntimeAdapter::Copilot
        | RuntimeAdapter::Hermes
        | RuntimeAdapter::KiloCode
        | RuntimeAdapter::KimiCode
        | RuntimeAdapter::OpenClaw
        | RuntimeAdapter::OpenCode => {
            licoup_agent_runtime::InstructionPolicy::NativePrivateInstructions
        }
        RuntimeAdapter::Pi | RuntimeAdapter::LicoAgent | RuntimeAdapter::DeepSeekHarness => {
            return Err("runtime_instruction_policy_unavailable");
        }
    };
    Ok(match policy {
        licoup_agent_runtime::InstructionPolicy::NativeDeveloperInstructions => {
            GeneratedInstructionDelivery {
                text: user_text.to_owned(),
                field: Some("developerInstructions"),
                guidance: Some(guidance.to_owned()),
            }
        }
        licoup_agent_runtime::InstructionPolicy::NativePrivateInstructions => {
            GeneratedInstructionDelivery {
                text: user_text.to_owned(),
                field: Some("privateInstructions"),
                guidance: Some(guidance.to_owned()),
            }
        }
        licoup_agent_runtime::InstructionPolicy::OrdinaryWirePrefix => {
            GeneratedInstructionDelivery {
                text: format!("{guidance}\n\n{user_text}"),
                field: None,
                guidance: None,
            }
        }
    })
}

#[cfg(test)]
mod tests;
