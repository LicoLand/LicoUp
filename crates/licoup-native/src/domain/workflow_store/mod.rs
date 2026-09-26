//! Durable workflow state, command, queue, subscription, and commit contracts.
//!
//! The strategy database remains the local workflow authority.  Runtime code
//! owns adapters and execution; this module owns the short SQLite transactions
//! that make accepted state and delivery intent recoverable across a process
//! restart.
//!
//! ## Ownership boundary (V7-K0)
//!
//! This module is the storage side of the graph, and storage *implements* the
//! ports rather than defining them. The ports live in `licoup-workflow-runtime`
//! (`ports::{StatePort, AuthorityPort, NoticeSink}`) and depend only on the
//! pure machine; the direction is
//!
//! ```text
//!   store ──► licoup-workflow-runtime::ports ──► licoup-workflow (pure)
//! ```
//!
//! `crates/licoup-workflow-store/tests/dependency_direction.rs` holds that
//! direction against Cargo's own graph, so a later change cannot reverse it
//! quietly. The implementation has **not** moved yet: everything in this module
//! still runs in place, and moving it across the seam must not change effect
//! semantics, which is why it is a separate step with its own evidence.
//!
//! Deployment boundary: this module belongs to the optional Workflow package. A
//! deployment that does not install it loses graph execution, not the
//! Conversation host, and uninstalling the package must not delete or re-book
//! an effect or budget ledger that another owner already recorded.

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
