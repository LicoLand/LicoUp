//! Adaptive Flywheel strategy definitions and durable Graph execution.
//!
//! `workflow.json` is the only state-machine semantic source. Definitions are
//! immutable, reducers are pure, and every external effect is represented by
//! a durable command before an adapter is allowed to run it.

mod assistant;
#[cfg(test)]
mod conformance;
mod package;
mod service;
mod store;
mod strategy_types;

pub use assistant::{
    ASSISTANT_TEMPORARY_DEFINITION_PREFIX, AssistantPreflight, PreflightFailure, PreflightReceipt,
    preflight_assistant_graph,
};
pub use package::{PreparedPackage, StrategyPackageImporter, synthetic_fixture_package_bytes};
pub use service::{ActorTurnPort, AssistantWakePort, StrategyService};
pub use store::StrategyStore;
pub use strategy_types::{
    BindingCandidate, BindingValue, StrategyAuthorization, StrategyDefinition,
    StrategyDefinitionSummary, StrategyDiagnostic, StrategyError, StrategyErrorCode,
    StrategyProjection,
};

pub const STRATEGY_SCHEMA_VERSION: &str = "licoup.adaptive-flywheel.state.v1";
