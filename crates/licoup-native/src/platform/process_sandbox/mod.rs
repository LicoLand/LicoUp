//! Shared macOS seatbelt process isolation for LicoUp-owned children.

mod seatbelt;
mod strategy;

pub use seatbelt::{
    CAPABILITY_COLLABORATION_LOOPBACK, CAPABILITY_LICO_AGENT_PLAN, SandboxError,
    collaboration_loopback_command, lico_agent_plan_command, seatbelt_literal,
};
pub(crate) use strategy::strategy_script_command;
