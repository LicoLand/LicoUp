//! Durable workflow state, command, queue, subscription, and commit contracts.
//!
//! The strategy database remains the local workflow authority.  Runtime code
//! owns adapters and execution; this module owns the short SQLite transactions
//! that make accepted state and delivery intent recoverable across a process
//! restart.

mod commit;
#[cfg(test)]
mod conformance;
mod control;
mod queue;
mod store;
mod strategy_types;
mod subscriptions;

pub use commit::{CommittedTransition, TransitionDecorator, TransitionIntent, TransitionObserver};
pub use control::DurableControlledStore;
pub use queue::{DurableQueue, DurableQueueLease, DurableQueueStats, QueueReplay, QueueStoreError};
pub use store::StrategyStore;
pub(crate) use store::normalize_legacy_workflow;
pub use strategy_types::{
    BindingCandidate, BindingValue, StrategyAuthorization, StrategyDefinition,
    StrategyDefinitionSummary, StrategyDiagnostic, StrategyError, StrategyErrorCode,
    StrategyProjection,
};
pub use subscriptions::DurableSubscriptionStore;

pub const STRATEGY_SCHEMA_VERSION: &str = "licoup.adaptive-flywheel.state.v1";

/// Name the store by its domain boundary while preserving the established
/// `StrategyStore` type for callers that still use strategy terminology.
pub type WorkflowStore = StrategyStore;
