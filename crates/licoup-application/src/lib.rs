//! Protocol-neutral business entry shared by the CLI and MCP, and the single
//! authority for composition and session policy: what the client is allowed to
//! do in a session.
//!
//! This crate owns the *shape* of a business request and its outcome: typed
//! command families, a normalized result and failure model, actor claims, and
//! stable operation references. It also owns the composition decisions that
//! belong to no single endpoint: the client runtime ABI, the session reducer
//! and its interaction policy, the authority registry that names each
//! destination's owning crate, protocol-input admission, catalog convergence,
//! dispatch timeout policy and the local release receipts.
//!
//! It still owns no protocol implementation, no storage format, no scheduler,
//! no runtime and no platform access of its own. It names the layer crates that
//! do — `licoup-foundation`, `licoup-client-state`, `licoup-protocol-bindings`,
//! `licoup-endpoint-core`, `licoup-platform-bridges` and
//! `licoup-agent-adapters` — and never an endpoint crate above it; the ports
//! below stay traits the native application implements.
//!
//! Two rules keep the boundary honest:
//!
//! - A caller (CLI or MCP) translates its own wire shape into a command here and
//!   translates the result back. Business semantics live behind the ports.
//! - Nothing in this crate can observe which caller it is serving. If a
//!   decision needs that knowledge, it belongs in the caller or in the native
//!   verification the caller already performed.
//!
//! The tool surface is described by three more modules that follow the same
//! rule — they publish shapes and rules, never a second copy of the host's own
//! registry: [`extension`] for namespaced identity, capability descriptors and
//! the discovered-versus-required rules, [`invocation`] for what one call is
//! once authority is proved, and [`receipt`] for the machine receipts a tool
//! writes (and for the natural output that is not one).

mod actor;
pub mod catalog_convergence;
pub mod client_authority_registry;
pub mod client_runtime;
mod command;
pub mod dispatch_timeout_policy;
mod extension;
mod facade;
mod failure;
pub mod integration_state;
mod invocation;
mod ports;
pub mod protocol_input_admission;
mod receipt;
pub mod release_receipts;
mod result;
pub mod session_policy;

pub(crate) mod state_machines {
    include!(concat!(env!("OUT_DIR"), "/state_machines.rs"));
}

pub use actor::{ActorClaim, ActorClaimError};
pub use command::{
    ApplicationCommand, AssistantCommand, CallbackDecision, CancelRequest, CommandFamily,
    ConversationCommand, DispatchRequest, ExportRequest, ImportRequest, MAX_PROMPT_BYTES,
    MAX_QUERY_BYTES, MAX_STABLE_ID_BYTES, Operation, SearchRequest, SubagentCommand, TaskType,
};
pub use extension::{
    AUTHORITY_FIELDS, ActivationMode, AdoptedAttributes, CapabilityDescriptor,
    ContractCompatibility, ContractRange, DeclaredAttribute, DiscoveredCapabilities,
    LifecycleSupport, MAX_IMPLEMENTATION_VERSION_BYTES, MAX_NAMESPACED_NAME_BYTES, QuotaShape,
    Requirement, is_authority_field, is_namespaced, is_semver,
};
pub use facade::ApplicationFacade;
pub use failure::{
    ApplicationFailure, EffectCertainty, FailureNormalization, MAX_PRESENTATION_ARGS,
    MAX_PRESENTATION_KEY_BYTES, MAX_PRESENTATION_VALUE_BYTES, PresentationArgs, RecoveryAction,
};
pub use invocation::{
    AuthorityHandle, AuthoritySource, IdempotencyReference, InvocationScope, ToolInvocation,
};
pub use ports::{ActorPort, ApplicationPorts, AssistantPort, ConversationPort, SubagentPort};
pub use receipt::{NaturalOutput, ReceiptKind, ToolReceipt};
pub use result::{CommandOutcome, CommandResolution, OperationReference, OperationState};
