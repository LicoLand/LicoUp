//! One replay arm per Agent parser this host composes.
//!
//! Each arm is the only place that knows how to construct that Agent's real
//! parser. An Agent whose parser has moved into its own package also moved the
//! arm that drives it, because an arm is only meaningful beside the parser it
//! constructs; this composition reaches it through the SDK's parser-set port.
//! Antigravity, Codex, Cursor, the DeepSeek Harness, Kimi Code and OpenCode have
//! all moved, so their arms are built by the packages that own their parsers.
//! Copilot keeps its protocol state machine outside this module tree
//! (`acp_driver_runtime`) and openclaw keeps its own (`openclaw_driver`), so
//! those two arms live next to the code they replay.
//!
//! The arms are `pub(in crate::platform)` to this module's parent — it is the
//! only reader, and it hands them to the SDK's harness through the parser set.

mod claude_code;
mod hermes;
mod kilo_code;
mod lico_agent;
mod pi;

use super::FrameReplay;
use crate::platform::acp_driver_runtime;
use crate::platform::openclaw_driver;

/// Build the replay arm for one Agent parser this host composes.
///
/// An adapter this host composes no arm for is refused rather than defaulted,
/// so a fixture can never pass against a parser that was never constructed.
pub(in crate::platform) fn replay_arm(adapter_id: &str) -> Result<Box<dyn FrameReplay>, String> {
    // The remaining shared ACP arm reads its Agent's frame dialect through the
    // same installed port the production transport reads, so the host's
    // composition installs it here exactly as a production entry point does.
    // Installation is idempotent and first-wins, so an arm built after a running
    // turn cannot replace the dialects that turn is reading.
    if matches!(adapter_id, "copilot") {
        crate::platform::runtime_adapters::install();
    }
    Ok(match adapter_id {
        // The arm moved with the parser into the Antigravity adapter package, so a
        // regression in that parser fails the package's own corpus as well as this
        // composition's.
        "antigravity" => licoup_agent_antigravity::replay::replay_arm(adapter_id)?,
        "claude-code" => Box::new(claude_code::Replay::new()?),
        "codex" => licoup_agent_codex::replay::replay_arm(adapter_id)?,
        "copilot" => Box::new(acp_driver_runtime::replay::Replay::new(adapter_id, "copilot-acp")?),
        "cursor" => licoup_agent_cursor::replay::replay_arm(adapter_id)?,
        "deepseek-harness" => licoup_agent_deepseek::replay::replay_arm(adapter_id)?,
        "hermes" => Box::new(hermes::Replay::new()?),
        "kilo-code" => Box::new(kilo_code::Replay::new()?),
        "kimi-code" => licoup_agent_kimi::replay::replay_arm(adapter_id)?,
        "lico-agent" => Box::new(lico_agent::Replay::new()?),
        "openclaw" => Box::new(openclaw_driver::replay::Replay::new()?),
        // The arm moved with the parser into the OpenCode adapter package, so a
        // regression in that protocol fails the package's own corpus as well as
        // this composition's.
        "opencode" => licoup_agent_opencode::replay::replay_arm(adapter_id)?,
        "pi" => Box::new(pi::Replay::new()?),
        other => {
            return Err(format!(
                "no replayable parser is registered for adapter {other}"
            ));
        }
    })
}
