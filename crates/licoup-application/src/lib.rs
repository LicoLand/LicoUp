//! Protocol-neutral business entry shared by the CLI and MCP.
//!
//! This crate owns the *shape* of a business request and its outcome: typed
//! command families, a normalized result and failure model, actor claims, and
//! stable operation references. It owns no protocol, no storage, no scheduler,
//! no runtime, and no platform access — the ports below are traits the native
//! application implements.
//!
//! Two rules keep the boundary honest:
//!
//! - A caller (CLI or MCP) translates its own wire shape into a command here and
//!   translates the result back. Business semantics live behind the ports.
//! - Nothing in this crate can observe which caller it is serving. If a
//!   decision needs that knowledge, it belongs in the caller or in the native
//!   verification the caller already performed.

mod actor;
mod command;
mod facade;
mod failure;
mod ports;
mod result;

pub use actor::{ActorClaim, ActorClaimError};
pub use command::{
    ApplicationCommand, AssistantCommand, CallbackDecision, CancelRequest, CommandFamily,
    ConversationCommand, DispatchRequest, ExportRequest, ImportRequest, MAX_PROMPT_BYTES,
    MAX_QUERY_BYTES, MAX_STABLE_ID_BYTES, Operation, SearchRequest, SubagentCommand, TaskType,
};
pub use facade::ApplicationFacade;
pub use failure::{ApplicationFailure, EffectCertainty, FailureNormalization, RecoveryAction};
pub use ports::{
    ActorPort, ApplicationPorts, AssistantPort, ConversationPort, NotificationPort, SubagentPort,
};
pub use result::{CommandOutcome, CommandResolution, OperationReference, OperationState};
