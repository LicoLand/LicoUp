//! One replay arm per registered adapter.
//!
//! Each arm is the only place that knows how to construct that adapter's real
//! parser. Two adapters keep their protocol state machine outside this module
//! tree (`acp_driver_runtime` for copilot and kimi-code, `openclaw_driver` for
//! openclaw), so those arms live next to the code they replay.

mod antigravity;
mod claude_code;
mod codex;
mod cursor;
mod deepseek_harness;
mod hermes;
mod kilo_code;
mod lico_agent;
mod opencode;
mod pi;

use super::FrameReplay;
use crate::platform::acp_driver_runtime;
use crate::platform::native_agent_parser::registry::parser_for;
use crate::platform::openclaw_driver;
use crate::platform::runtime_adapters::RuntimeAdapter;

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

/// The framing a registered adapter really speaks. A fixture whose recorded
/// channel disagrees with this is not a transcript of that adapter.
pub(super) fn contract_framing(adapter_id: &str) -> Result<&'static str, String> {
    ALL.iter()
        .map(|adapter| parser_for(*adapter))
        .find(|contract| contract.id == adapter_id)
        .map(|contract| contract.framing)
        .ok_or_else(|| format!("no registered contract for adapter {adapter_id}"))
}

/// Build the replay arm for a registered adapter id.
pub(super) fn replay_for(adapter_id: &str) -> Result<Box<dyn FrameReplay>, String> {
    Ok(match adapter_id {
        "antigravity" => Box::new(antigravity::Replay::new()?),
        "claude-code" => Box::new(claude_code::Replay::new()?),
        "codex" => Box::new(codex::Replay::new()?),
        "copilot" | "kimi-code" => Box::new(acp_driver_runtime::replay::Replay::new(adapter_id)?),
        "cursor" => Box::new(cursor::Replay::new()?),
        "deepseek-harness" => Box::new(deepseek_harness::Replay::new()?),
        "hermes" => Box::new(hermes::Replay::new()?),
        "kilo-code" => Box::new(kilo_code::Replay::new()?),
        "lico-agent" => Box::new(lico_agent::Replay::new()?),
        "openclaw" => Box::new(openclaw_driver::replay::Replay::new()?),
        "opencode" => Box::new(opencode::Replay::new()?),
        "pi" => Box::new(pi::Replay::new()?),
        other => {
            return Err(format!(
                "no replayable parser is registered for adapter {other}"
            ));
        }
    })
}
