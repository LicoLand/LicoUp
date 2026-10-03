//! The Codex app-server driver, composed from the Codex adapter package.
//!
//! The protocol vocabulary this driver speaks — the request identifiers, the
//! handshake phases, the effects a parsed frame produces, the failure shape, the
//! launch configuration, the effective settings and the reserve-model projection
//! — belongs to Codex and lives in `licoup-agent-codex` now. It is re-exported
//! here at its former path so the driver leaves below keep reading it, and so
//! the client carries one copy of the vocabulary rather than two.
//!
//! What is still composed by the client is the *process* half: launching an
//! app-server, reading its framed lines, supervising the turn, and answering
//! control requests. That half moves to the package next, through the
//! agent-execution port this package declares; until it does, the client reads
//! the protocol from the package and owns only the process.

pub(in crate::platform) mod active_control;
mod io;
mod launch;
mod model_catalog;
mod supervision;
mod transport;

// This Agent's wire vocabulary and its failure constructors, owned by the
// package that carries the Agent. The constructors are inherent methods on the
// package's own types, so only the modules are named here.
pub(in crate::platform) use licoup_agent_codex::app_server::{config, limits, model, reserve};

pub(super) use licoup_agent_codex::app_server::contract::RUNTIME_PROTOCOL;
#[cfg(test)]
pub(super) use licoup_agent_codex::app_server::model::EffectiveSettings;
pub(super) use licoup_agent_codex::app_server::model::RunResult;
pub(crate) use model_catalog::list_models;
pub(super) use transport::execute;

#[cfg(test)]
mod tests;
