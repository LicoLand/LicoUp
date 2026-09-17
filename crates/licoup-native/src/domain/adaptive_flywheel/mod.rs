//! Adaptive Flywheel strategy definitions and durable Graph execution.
//!
//! `workflow.json` is the only state-machine semantic source. Definitions are
//! immutable, reducers are pure, and every external effect is represented by
//! a durable command before an adapter is allowed to run it.

mod assistant;
#[cfg(test)]
mod conformance;
pub mod control;
mod package;
pub mod routing;
mod service;
mod store;
mod strategy_types;

pub use assistant::{
    ASSISTANT_TEMPORARY_DEFINITION_PREFIX, AssistantPreflight, PreflightFailure, PreflightReceipt,
    preflight_assistant_graph,
};
pub use control::{
    AdmissionConflict, AdmissionReceipt, AdmissionRequest, ControlOperation, ControlScope,
    ControlledStore, InMemoryControlledStore, InterventionProxy, OperationGrant, VerifiedPrincipal,
};
pub use package::{PreparedPackage, StrategyPackageImporter, synthetic_fixture_package_bytes};
pub use routing::{
    ActivationRule, ChannelKind, DeliveryMode, FairDispatchQueue, FrozenTargetRecipient,
    FrozenTargets, NodeCapability, NodeFeatureIndex, NodeLifecycleState, NodeMetadata, QueueBounds,
    QueueCapacityExceeded, QueuedItem, RecipientEffectStatus, Subscription, SubscriptionPredicate,
    SubscriptionRegistry, SubscriptionScope, TargetSelector,
};
pub use service::{ActorTurnPort, AssistantWakePort, StrategyService};
pub use store::StrategyStore;
pub use strategy_types::{
    BindingCandidate, BindingValue, StrategyAuthorization, StrategyDefinition,
    StrategyDefinitionSummary, StrategyDiagnostic, StrategyError, StrategyErrorCode,
    StrategyProjection,
};

pub const STRATEGY_SCHEMA_VERSION: &str = "licoup.adaptive-flywheel.state.v1";
