//! Grouped backend ports.
//!
//! Each port is one family of business work, implemented by the native
//! application. The ports exist so both interfaces reach the *same*
//! implementation: a CLI call and an MCP call for one operation arrive at one
//! trait method, which is what makes identical authority and a single effect
//! structural rather than a promise.
//!
//! Verification stays native. [`ActorPort::verify`] is the one place that
//! decides whether a structurally valid claim is true, and the facade calls it
//! once before any family port runs.

use crate::actor::ActorClaim;
use crate::command::{AssistantCommand, ConversationCommand, SubagentCommand};
use crate::failure::ApplicationFailure;
use crate::result::CommandOutcome;

/// Decide whether a structurally valid claim is true.
///
/// Implementations own the real check: the local owner membership must exist
/// and be active, and an agent membership must be active in the conversation and
/// owned by that provider. The facade runs this once per command, so no family
/// port has to repeat it.
pub trait ActorPort: Send + Sync {
    fn verify(&self, claim: &ActorClaim) -> Result<(), ApplicationFailure>;
}

/// Assistant profiles and workflow control.
pub trait AssistantPort: Send + Sync {
    fn execute(
        &self,
        claim: &ActorClaim,
        command: &AssistantCommand,
    ) -> Result<CommandOutcome, ApplicationFailure>;
}

/// Delegated work: listing targets, probing readiness, and the dispatch
/// lifecycle.
pub trait SubagentPort: Send + Sync {
    fn execute(
        &self,
        claim: &ActorClaim,
        command: &SubagentCommand,
    ) -> Result<CommandOutcome, ApplicationFailure>;
}

/// Canonical Conversation reads and transfer.
pub trait ConversationPort: Send + Sync {
    fn execute(
        &self,
        claim: &ActorClaim,
        command: &ConversationCommand,
    ) -> Result<CommandOutcome, ApplicationFailure>;
}

/// Tell the designated Assistant that work it started has settled.
///
/// Kept separate from the family ports because it is not a response to a
/// request: it fires when durable work reaches a state, and it must never fail
/// the work that triggered it.
pub trait NotificationPort: Send + Sync {
    fn work_settled(
        &self,
        conversation_id: &str,
        membership_id: &str,
        notice: &serde_json::Value,
    ) -> Result<(), ApplicationFailure>;
}

/// The complete backend behind the facade.
#[derive(Clone)]
pub struct ApplicationPorts {
    pub actors: std::sync::Arc<dyn ActorPort>,
    pub assistant: std::sync::Arc<dyn AssistantPort>,
    pub subagent: std::sync::Arc<dyn SubagentPort>,
    pub conversation: std::sync::Arc<dyn ConversationPort>,
    /// Optional: a deployment that never runs the workflow graph has nothing to
    /// notify, and the facade treats that as no work to report — not a failure.
    pub notification: Option<std::sync::Arc<dyn NotificationPort>>,
}

impl ApplicationPorts {
    pub fn new(
        actors: std::sync::Arc<dyn ActorPort>,
        assistant: std::sync::Arc<dyn AssistantPort>,
        subagent: std::sync::Arc<dyn SubagentPort>,
        conversation: std::sync::Arc<dyn ConversationPort>,
    ) -> Self {
        Self {
            actors,
            assistant,
            subagent,
            conversation,
            notification: None,
        }
    }

    pub fn with_notification(mut self, notification: std::sync::Arc<dyn NotificationPort>) -> Self {
        self.notification = Some(notification);
        self
    }
}
