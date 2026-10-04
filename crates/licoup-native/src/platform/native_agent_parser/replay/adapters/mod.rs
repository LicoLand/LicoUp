//! One replay arm per Agent parser this host composes.
//!
//! Each arm is the only place that knows how to construct that Agent's real
//! parser. An Agent whose parser has moved into its own package also moved the
//! arm that drives it, because an arm is only meaningful beside the parser it
//! constructs; this composition reaches it through the SDK's parser-set port.
//! Six Agents have moved that way — Antigravity, Codex, Cursor, DeepSeek
//! Harness, Kimi Code and Lico Agent — so their arms are built by the packages
//! that own their parsers.
//!
//! Two Agents keep their protocol state machine outside this module tree
//! (`acp_driver_runtime` for copilot and `openclaw_driver` for openclaw), so
//! those arms live next to the code they replay. The remaining five hold their
//! parser in this tree and their arm beside it.
//!
//! The arms are `pub(in crate::platform)` to this module's parent — it is the
//! only reader, and it hands them to the SDK's harness through the parser set.

mod claude_code;
mod hermes;
mod kilo_code;
mod opencode;
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
    // turn cannot replace the dialect that turn is reading. The moved ACP Agent
    // needs no installation: its package owns the dialect and hands it to the
    // shared reducer directly, so the arm cannot drift from the dialect.
    if matches!(adapter_id, "copilot") {
        crate::platform::runtime_adapters::install();
    }
    Ok(match adapter_id {
        // The arms that moved with their parsers into the adapter packages, so a
        // regression in one of those parsers fails the package's own corpus as
        // well as this composition's.
        "antigravity" => licoup_agent_antigravity::replay::replay_arm(adapter_id)?,
        "codex" => licoup_agent_codex::replay::replay_arm(adapter_id)?,
        "cursor" => licoup_agent_cursor::replay::replay_arm(adapter_id)?,
        "deepseek-harness" => licoup_agent_deepseek::replay::replay_arm(adapter_id)?,
        "kimi-code" => licoup_agent_kimi::replay::replay_arm(adapter_id)?,
        "lico-agent" => licoup_agent_lico_agent::replay::replay_arm(adapter_id)?,
        // The arms whose parser is still in this tree or beside its state
        // machine.
        "claude-code" => Box::new(claude_code::Replay::new()?),
        "copilot" => Box::new(acp_driver_runtime::replay::Replay::new(
            adapter_id,
            "copilot-acp",
        )?),
        "hermes" => Box::new(hermes::Replay::new()?),
        "kilo-code" => Box::new(kilo_code::Replay::new()?),
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
