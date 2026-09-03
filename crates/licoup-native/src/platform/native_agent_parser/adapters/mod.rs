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
pub(in crate::platform) mod driver_registry;
pub(in crate::platform) mod hermes;
pub(in crate::platform) mod kilo_code;
pub(in crate::platform) mod kimi_code;
pub(in crate::platform) mod lico_agent;
pub(in crate::platform) mod openclaw;
pub(in crate::platform) mod opencode;
pub(in crate::platform) mod pi;

/// Shared byte-line ingress contract for native protocols. Implementations
/// classify vendor frames and report facts; the conversation layer remains the
/// sole authority that settles a turn.
pub(in crate::platform) trait NativeLineParser {
    type Report;
    type Error;

    fn parse_line(&mut self, line: &[u8]) -> Result<Self::Report, Self::Error>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum ProtocolSignalKind {
    ProtocolFinish,
    Eof,
    CancelConfirmed,
}

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
    pub(in crate::platform) reported_signals: [ProtocolSignalKind; 3],
    pub(in crate::platform) settles_turn: bool,
    pub(in crate::platform) has_implicit_turn_timeout: bool,
    pub(in crate::platform) emits_all_content: bool,
}

impl AdapterContract {
    pub(super) const fn new(id: &'static str, framing: &'static str) -> Self {
        Self {
            id,
            framing,
            reported_signals: [
                ProtocolSignalKind::ProtocolFinish,
                ProtocolSignalKind::Eof,
                ProtocolSignalKind::CancelConfirmed,
            ],
            settles_turn: false,
            has_implicit_turn_timeout: false,
            emits_all_content: true,
        }
    }

    #[cfg(test)]
    pub(in crate::platform) fn inventory_json(self) -> Value {
        serde_json::json!({
            "adapterId": self.id,
            "framing": self.framing,
            "settlesTurn": self.settles_turn,
            "hasImplicitTurnTimeout": self.has_implicit_turn_timeout,
            "emitsAllContent": self.emits_all_content,
        })
    }
}

#[cfg(test)]
mod compliance_tests {
    use super::*;

    const ALL: [RuntimeAdapter; 13] = [
        RuntimeAdapter::Antigravity,
        RuntimeAdapter::ClaudeCode,
        RuntimeAdapter::Codex,
        RuntimeAdapter::Copilot,
        RuntimeAdapter::Cursor,
        RuntimeAdapter::Hermes,
        RuntimeAdapter::KiloCode,
        RuntimeAdapter::KimiCode,
        RuntimeAdapter::OpenClaw,
        RuntimeAdapter::OpenCode,
        RuntimeAdapter::Pi,
        RuntimeAdapter::LicoAgent,
        RuntimeAdapter::DeepSeekHarness,
    ];

    #[test]
    fn packaged_adapters_report_l4_facts_without_settling_turns() {
        for adapter in ALL {
            let contract = contract(adapter);
            assert!(!contract.settles_turn, "{} settled a turn", contract.id);
            assert!(
                !contract.has_implicit_turn_timeout,
                "{} declared an implicit turn timeout",
                contract.id
            );
            assert!(contract.emits_all_content, "{} hid content", contract.id);
            assert_eq!(
                contract.reported_signals,
                [
                    ProtocolSignalKind::ProtocolFinish,
                    ProtocolSignalKind::Eof,
                    ProtocolSignalKind::CancelConfirmed,
                ],
                "{} did not report the complete L4 signal set",
                contract.id
            );
        }
    }
}
