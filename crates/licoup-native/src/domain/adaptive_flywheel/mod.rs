//! Adaptive Flywheel strategy definitions and durable Graph execution.
//!
//! `workflow.json` is the only state-machine semantic source. Definitions are
//! immutable, reducers are pure, and every external effect is represented by
//! a durable command before an adapter is allowed to run it.

mod definition;
mod graph;
mod package;
mod reducer;
mod service;
mod store;

pub use definition::{
    ActorSlot, BindingCandidate, BindingKind, BindingValue, FailureClass, FallbackReceipt,
    GraphState, GraphStateKind, GuardExpression, RetryPolicy, RuntimeKind, RuntimeRequirement,
    SessionPolicy, SlotFallbackPolicy, StrategyAuthorization, StrategyDefinition,
    StrategyDefinitionSummary, StrategyDiagnostic, StrategyError, StrategyErrorCode,
    StrategyProjection, StrategyRunStatus, Transition, WorkflowDefinition, WorkflowLimits,
    WorkflowMetadata, WorksetTemplate,
};
pub use graph::{CompiledWorkflow, compile_workflow};
pub use package::{PreparedPackage, StrategyPackageImporter, synthetic_fixture_package_bytes};
pub use reducer::{
    CommandKind, CommandStatus, ReducerEvent, ReducerOutput, RunCommand, RunSnapshot, reduce,
};
pub use service::StrategyService;
pub use store::StrategyStore;

pub const WORKFLOW_SCHEMA_VERSION: &str = "licoup.adaptive-flywheel.workflow.v1";
pub const STRATEGY_SCHEMA_VERSION: &str = "licoup.adaptive-flywheel.state.v1";
pub const MAX_ACTIVE_EFFECTS: usize = 8;
pub const MAX_GRAPH_STATES: usize = 512;
pub const MAX_GRAPH_TRANSITIONS: usize = 2_048;
pub const MAX_BINDING_SLOTS: usize = 64;
pub const MAX_RUNTIME_REQUIREMENTS: usize = 16;
pub const MAX_WORKSET_ITEMS: usize = 256;
pub const MAX_RETRY_ATTEMPTS: u8 = 8;
