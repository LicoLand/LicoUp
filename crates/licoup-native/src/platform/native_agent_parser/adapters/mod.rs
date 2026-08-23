pub(in crate::platform) use super::{LifecycleStage, Transition, TransitionReducer};
use crate::platform::runtime_adapters::RuntimeAdapter;
#[cfg(test)]
use serde_json::Value;

pub(in crate::platform) mod antigravity;
pub(in crate::platform) mod claude_code;
pub(in crate::platform) mod codex;
pub(in crate::platform) mod copilot;
pub(in crate::platform) mod cursor;
pub(in crate::platform) mod deepseek_harness;
pub(in crate::platform) mod hermes;
pub(in crate::platform) mod kilo_code;
pub(in crate::platform) mod kimi_code;
pub(in crate::platform) mod lico_agent;
pub(in crate::platform) mod openclaw;
pub(in crate::platform) mod opencode;
pub(in crate::platform) mod pi;

pub(super) fn contract(adapter: RuntimeAdapter) -> AdapterContract {
    match adapter {
        RuntimeAdapter::Antigravity => antigravity::CONTRACT,
        RuntimeAdapter::ClaudeCode => claude_code::CONTRACT,
        RuntimeAdapter::Codex => codex::CONTRACT,
        RuntimeAdapter::Copilot => copilot::CONTRACT,
        RuntimeAdapter::Cursor => cursor::CONTRACT,
        RuntimeAdapter::Hermes => hermes::CONTRACT,
        RuntimeAdapter::KiloCode => kilo_code::CONTRACT,
        RuntimeAdapter::KimiCode => kimi_code::CONTRACT,
        RuntimeAdapter::OpenClaw => openclaw::CONTRACT,
        RuntimeAdapter::OpenCode => opencode::CONTRACT,
        RuntimeAdapter::Pi => pi::CONTRACT,
        RuntimeAdapter::LicoAgent => lico_agent::CONTRACT,
        RuntimeAdapter::DeepSeekHarness => deepseek_harness::CONTRACT,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) struct AdapterContract {
    pub(in crate::platform) id: &'static str,
    pub(in crate::platform) framing: &'static str,
}

impl AdapterContract {
    pub(super) const fn new(id: &'static str, framing: &'static str) -> Self {
        Self { id, framing }
    }

    #[cfg(test)]
    pub(in crate::platform) fn inventory_json(self) -> Value {
        serde_json::json!({"adapterId": self.id, "framing": self.framing})
    }
}
