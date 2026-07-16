//! Local-only agent token usage facade.

mod agent_usage_codex;
mod attribution;
mod command;
mod contract;
mod persistence;
mod window;

pub use command::{report, scan};

#[cfg(test)]
mod tests;
