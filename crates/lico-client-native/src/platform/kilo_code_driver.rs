//! Kilo Code `serve` adapter.
//!
//! The adapter owns only Kilo's fixed endpoint contract. Configuration,
//! capability probing, execution/HTTP transport, and result projection are
//! separate leaves so each can be changed and accepted independently.

mod config;
mod execution;
mod probe;
mod projection;
mod transport;

use super::acp_driver_runtime::AcpDriverSpec;

pub(super) const RUNTIME_PROTOCOL: &str = "kilo-code-serve-http-v1";
pub(super) const KILO_CODE_DRIVER: AcpDriverSpec = AcpDriverSpec::new(RUNTIME_PROTOCOL, &["serve"])
    .with_identity("kilo-code-serve", "kilo_code_serve");

pub(super) use execution::execute;
pub(super) use probe::capability_probe;

#[cfg(test)]
mod tests;
