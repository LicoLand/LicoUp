//! Event-driven workflow runtime and native execution adapters.
//!
//! Runtime leaves are intentionally separate from [`crate::domain::workflow_store`]:
//! adapters may perform external work, while store transactions only persist
//! state, commands, and post-commit intent.

pub mod adapter;
mod assistant;
pub mod control;
pub mod driver;
pub mod node;
mod package;
pub mod routing;
mod service;

pub use adapter::{
    AdapterError, AdapterExecutionStatus, CancelOutcome, CooperativeDrainAdapter,
    NodeCapabilityAdapter, NodeInvocation, PauseOutcome, ResumeOutcome,
    SingleWriterSessionRegistry, SteerOutcome, SyntheticCapabilityAdapter,
};
pub use assistant::{
    ASSISTANT_TEMPORARY_DEFINITION_PREFIX, AssistantPreflight, PreflightFailure, PreflightReceipt,
    preflight_assistant_graph,
};
pub use control::{
    AdmissionConflict, AdmissionReceipt, AdmissionRequest, ControlOperation, ControlScope,
    ControlledStore, InMemoryControlledStore, InterventionProxy, OperationGrant, VerifiedPrincipal,
};
pub use driver::{
    ContinuousNodeDriver, DispatchedEffectReport, DriverError, DriverStepOutcome, GraphPauseReport,
    GraphStopReport, PerNodePauseOutcome, PerNodeStopOutcome, ResultReentry,
};
pub use node::{
    CancellationFacts, InvocationRecord, NodeExecutionError, NodeExecutionOutcome,
    NodeExecutionReceipt, NodeFacade, NodeObservation, PauseResult, ResumeResult, SteerResult,
    StopResult,
};
pub use package::{PreparedPackage, StrategyPackageImporter, synthetic_fixture_package_bytes};
pub use routing::{
    ActivationRule, ChannelKind, DeliveryMode, FairDispatchQueue, FrozenTargetRecipient,
    FrozenTargets, NodeCapability, NodeFeatureIndex, NodeLifecycleState, NodeMetadata, QueueBounds,
    QueueCapacityExceeded, QueuedItem, RecipientEffectStatus, Subscription, SubscriptionPredicate,
    SubscriptionRegistry, SubscriptionScope, TargetSelector,
};
pub use service::{ActorTurnPort, AssistantWakePort, StrategyService};

pub use crate::domain::workflow_store::{
    BindingCandidate, BindingValue, STRATEGY_SCHEMA_VERSION, StrategyAuthorization,
    StrategyDefinition, StrategyDefinitionSummary, StrategyDiagnostic, StrategyError,
    StrategyErrorCode, StrategyProjection, StrategyStore, WorkflowStore,
};
