//! Local-only provider-quota snapshot facade.
//!
//! The per-provider quota fetch approach (local agent credentials to provider
//! quota endpoints, app-server and loopback fallback lanes, adaptive refresh
//! discipline) is reimplemented from the documented behavior of CodexBar
//! (MIT, Peter Steinberger, github.com/steipete/CodexBar), which is credited
//! here as the approach reference. No CodexBar code is copied.

mod antigravity;
mod codex;
mod command;
mod contract;
mod credentials;
mod cursor;
mod http;
mod persistence;
mod redaction;
mod scheduler;

pub use command::snapshot;

#[cfg(test)]
mod tests;
