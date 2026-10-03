//! Replay arm for the `copilot` adapter.
//!
//! The arm drives the *shared* ACP reducer — the same `AcpProtocol` a live
//! Copilot turn drives — and the reducer reads Copilot's frame policy through
//! the installed dialect port, exactly as the production transport does. So a
//! projection here is the shared engine's real report over this Agent's real
//! parser, never a re-derivation of the payload, and the arm can only fail when
//! this Agent's dialect or the shared reducer regresses.
//!
//! The arm travels with the dialect. A composing test build reaches it through
//! [`crate::registration::parser_set`]; the host's own corpus reaches it the
//! same way.
//!
//! The reducer's dialect is resolved from the engine's installed set, so the
//! arm installs this Agent's dialect first. Installation is first-wins and
//! idempotent: a build whose composition already installed a wider table —
//! Copilot, Kimi Code and Hermes together — keeps that table, and this Agent's
//! entry in it is the same value.

use licoup_agent_adapter_sdk::replay::FrameReplay;
use licoup_agent_drivers::acp_driver_runtime::{parser_port, replay};

use crate::registration::{ADAPTER_ID, DIALECT};

/// Build the replay arm of this package's parser.
///
/// An adapter this package does not carry is refused rather than defaulted, so a
/// fixture can never pass against a parser that was never constructed.
pub fn replay_arm(adapter_id: &str) -> Result<Box<dyn FrameReplay>, String> {
    if adapter_id != ADAPTER_ID {
        return Err(format!(
            "no replayable parser is registered for adapter {adapter_id}"
        ));
    }
    // First-wins: a build whose composition installed a wider table keeps it,
    // and this Agent's entry in that table is the same value.
    let _ = parser_port::install(vec![DIALECT]);
    if parser_port::parser_for(crate::driver::DRIVER_ID)
        .driver_id
        .is_empty()
    {
        return Err(format!(
            "no ACP frame dialect is installed for adapter {adapter_id}"
        ));
    }
    Ok(Box::new(replay::Replay::new(adapter_id)?))
}
