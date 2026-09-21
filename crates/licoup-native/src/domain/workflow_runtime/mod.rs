//! Event-driven workflow runtime and native execution adapters.
//!
//! Runtime leaves are intentionally separate from [`crate::domain::workflow_store`]:
//! adapters may perform external work, while store transactions only persist
//! state, commands, and post-commit intent.
//!
//! ## Ownership boundary (V7-K0)
//!
//! The drive loop and its adapters are the runtime side; the consumer-owned
//! ports they call live in `licoup-workflow-runtime`
//! (`ports::{StatePort, AuthorityPort, NoticeSink}`). The runtime declares what
//! it needs and storage implements it, so the compile-time edge points
//! `store ──► ports ──► pure machine` while calls at run time point the other
//! way. That inversion is deliberate, not a cycle to be flattened.
//!
//! `ContinuousNodeDriver` (`driver.rs`) has no production caller: the real
//! sustained driver is `StrategyService::drive_run`. Do not extend the dormant
//! driver into a second scheduler; the single entry is what the extraction and
//! the recovery contract are written against.

pub mod adapter;
mod assistant;
pub mod authority_adapter;
pub mod control;
pub mod driver;
pub mod evolution;
pub mod evolution_adapters;
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
pub use evolution::{
    AdoptedPlanningDefaultSeam, AgentModelOptionSeam, CallbackContextFacts, CallbackCostFacts,
    CallbackEvolutionEnricher, CallbackEvolutionPayload, CallbackFacts, CallbackObservationFacts,
    CallbackSuggestions, DefaultEvolutionContextPort, DefaultEvolutionObservationPort,
    DefaultEvolutionStrategyPort, EffectRecheckContext, EffectRecheckFailure, EffectRecheckReceipt,
    EvolutionContextPort, EvolutionCostPort, EvolutionObservationPort, EvolutionStrategyPort,
    GroupBGapReport, GroupBIntegrationGaps, LedgerEvolutionCostPort, NodeObservationSummary,
    PlanningScopeSeam, StrategySourceSeam, StrategySuggestion, StrategyVersionSeam,
    recheck_before_effect,
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
