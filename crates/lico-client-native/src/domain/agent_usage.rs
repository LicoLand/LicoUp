//! Local-only agent token usage facade.

mod agent_usage_codex;
mod agent_usage_native;
mod attribution;
mod command;
mod contract;
mod persistence;
mod window;

pub use command::{report, scan};

#[cfg(test)]
mod tests;
