//! The sole boundary between native-agent returned frames and conversation state.
//!
//! Transports own bytes and process/HTTP lifecycle.  Parser adapters own vendor
//! framing and convert it into this closed transition vocabulary.  No caller
//! outside this module receives or persists a vendor frame.

pub(in crate::platform) mod adapters;
mod lifecycle;
mod reconciliation;
mod registry;

pub(in crate::platform) use lifecycle::{LifecycleStage, Transition, TransitionReducer};
pub(in crate::platform) use reconciliation::{TextForm, TextReconciler};
#[cfg(test)]
use registry::parser_for;

pub(in crate::platform) fn require_registered(
    adapter: crate::platform::runtime_adapters::RuntimeAdapter,
) {
    let _ = registry::parser_for(adapter);
}

#[cfg(test)]
mod tests;

/// Complete packaged inventory. The registry test proves this is bijective
/// with `RuntimeAdapter`; adding an adapter requires adding its parser here.
#[cfg(test)]
const PACKAGED_ADAPTER_IDS: [&str; 13] = [
    "antigravity",
    "claude-code",
    "codex",
    "copilot",
    "cursor",
    "hermes",
    "kilo-code",
    "kimi-code",
    "openclaw",
    "opencode",
    "pi",
    "lico-agent",
    "deepseek-harness",
];
