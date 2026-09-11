//! Typed command families.
//!
//! These are the business requests both interfaces share. A CLI invocation and
//! an MCP tool call for the same operation decode into the same value here, so
//! the two interfaces cannot drift in what they ask for — only in how they
//! frame it.
//!
//! Field bounds mirror the ones the existing surfaces already enforce, so a
//! command that reaches a port has already been bounded.

use crate::failure::ApplicationFailure;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Largest stable identifier (conversation, membership, run, dispatch).
pub const MAX_STABLE_ID_BYTES: usize = 256;
/// Largest delegated prompt.
pub const MAX_PROMPT_BYTES: usize = 48 * 1024;
/// Largest conversation search query.
pub const MAX_QUERY_BYTES: usize = 512;
/// Largest working directory accepted.
pub const MAX_WORKING_DIRECTORY_BYTES: usize = 4096;
/// Largest model name accepted.
pub const MAX_MODEL_BYTES: usize = 256;
/// Largest reasoning-effort token accepted.
pub const MAX_REASONING_EFFORT_BYTES: usize = 32;

/// Which family a command belongs to. Ownership follows this, not the caller.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandFamily {
    Assistant,
    Subagent,
    Conversation,
}

/// One addressable business operation. The strings are the neutral names the
/// product already publishes on receipts (`subagent.delegate` and friends).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Operation {
    AssistantProfiles,
    WorkflowExecute,
    WorkflowInspect,
    WorkflowCancel,
    SubagentsList,
    SubagentProbe,
    SubagentDelegate,
    SubagentContinue,
    SubagentCancel,
    ConversationList,
    ConversationGet,
    ConversationSearch,
    ConversationExport,
    ConversationImport,
}

impl Operation {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AssistantProfiles => "assistant.profiles",
            Self::WorkflowExecute => "workflow.execute",
            Self::WorkflowInspect => "workflow.inspect",
            Self::WorkflowCancel => "workflow.cancel",
            Self::SubagentsList => "subagent.list",
            Self::SubagentProbe => "subagent.probe",
            Self::SubagentDelegate => "subagent.delegate",
            Self::SubagentContinue => "subagent.continue",
            Self::SubagentCancel => "subagent.cancel",
            Self::ConversationList => "conversation.list",
            Self::ConversationGet => "conversation.get",
            Self::ConversationSearch => "conversation.search",
            Self::ConversationExport => "conversation.export",
            Self::ConversationImport => "conversation.import",
        }
    }

    /// Operations that can produce an effect on a provider. These are the ones
    /// where effect certainty matters: a failure after the effect is attempted
    /// must be reconciled rather than blindly retried.
    pub const fn produces_effect(self) -> bool {
        matches!(
            self,
            Self::WorkflowExecute
                | Self::WorkflowCancel
                | Self::SubagentDelegate
                | Self::SubagentContinue
                | Self::SubagentCancel
                | Self::ConversationImport
        )
    }
}

/// The Assistant Profile listing and workflow control family.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "command", rename_all = "kebab-case")]
pub enum AssistantCommand {
    Profiles {
        conversation_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        filters: Option<Value>,
    },
    WorkflowExecute {
        conversation_id: String,
        membership_id: String,
        workflow: Value,
        #[serde(default)]
        bindings: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        input: Option<Value>,
        idempotency_key: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        decision: Option<CallbackDecision>,
    },
    WorkflowInspect {
        run_id: String,
    },
    WorkflowCancel {
        run_id: String,
    },
}

impl AssistantCommand {
    pub const fn family() -> CommandFamily {
        CommandFamily::Assistant
    }

    pub const fn operation(&self) -> Operation {
        match self {
            Self::Profiles { .. } => Operation::AssistantProfiles,
            Self::WorkflowExecute { .. } => Operation::WorkflowExecute,
            Self::WorkflowInspect { .. } => Operation::WorkflowInspect,
            Self::WorkflowCancel { .. } => Operation::WorkflowCancel,
        }
    }

    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        match self {
            Self::Profiles {
                conversation_id, ..
            } => stable_id("conversation_id", conversation_id),
            Self::WorkflowExecute {
                conversation_id,
                membership_id,
                workflow,
                idempotency_key,
                decision,
                ..
            } => {
                stable_id("conversation_id", conversation_id)?;
                stable_id("membership_id", membership_id)?;
                stable_id("idempotency_key", idempotency_key)?;
                if !workflow.is_object() {
                    return Err(ApplicationFailure::invalid_request("workflow"));
                }
                if let Some(decision) = decision {
                    decision.validate()?;
                }
                Ok(())
            }
            Self::WorkflowInspect { run_id } | Self::WorkflowCancel { run_id } => {
                stable_id("run_id", run_id)
            }
        }
    }
}

/// The answer a parked callback wait accepts. Kept as its own type so the three
/// accepted decisions cannot be invented at a call site.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CallbackDecision {
    Advance { state_id: String, state_visit: u64 },
    Return { state_id: String, state_visit: u64 },
    Terminate,
}

impl CallbackDecision {
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Advance { .. } => "advance",
            Self::Return { .. } => "return",
            Self::Terminate => "terminate",
        }
    }

    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        match self {
            Self::Advance {
                state_id,
                state_visit,
            }
            | Self::Return {
                state_id,
                state_visit,
            } => {
                stable_id("callback_state_id", state_id)?;
                if *state_visit == 0 {
                    return Err(ApplicationFailure::invalid_request("callback_state_visit"));
                }
                Ok(())
            }
            Self::Terminate => Ok(()),
        }
    }
}

/// The delegated-work family.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "command", rename_all = "kebab-case")]
pub enum SubagentCommand {
    List,
    Probe { agent_id: String },
    Delegate(DispatchRequest),
    Continue(DispatchRequest),
    Cancel(CancelRequest),
}

impl SubagentCommand {
    pub const fn family() -> CommandFamily {
        CommandFamily::Subagent
    }

    pub const fn operation(&self) -> Operation {
        match self {
            Self::List => Operation::SubagentsList,
            Self::Probe { .. } => Operation::SubagentProbe,
            Self::Delegate(_) => Operation::SubagentDelegate,
            Self::Continue(_) => Operation::SubagentContinue,
            Self::Cancel(_) => Operation::SubagentCancel,
        }
    }

    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        match self {
            Self::List => Ok(()),
            Self::Probe { agent_id } => provider("agent_id", agent_id),
            Self::Delegate(request) | Self::Continue(request) => request.validate(),
            Self::Cancel(request) => request.validate(),
        }
    }
}

/// One bounded unit of work handed to another Membership.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DispatchRequest {
    /// Exactly one of `membership_id` or `agent_id` addresses the target.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub membership_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_type: Option<TaskType>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub timeout_unbounded: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_stdout_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_stderr_bytes: Option<u64>,
}

impl DispatchRequest {
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if self.membership_id.is_none() && self.agent_id.is_none() {
            return Err(ApplicationFailure::invalid_request("target"));
        }
        if let Some(membership_id) = &self.membership_id {
            stable_id("membership_id", membership_id)?;
        }
        if let Some(agent_id) = &self.agent_id {
            provider("agent_id", agent_id)?;
        }
        bounded_non_empty("prompt", &self.prompt, MAX_PROMPT_BYTES)?;
        if let Some(model) = &self.model {
            bounded_non_empty("model", model, MAX_MODEL_BYTES)?;
        }
        if let Some(effort) = &self.reasoning_effort {
            bounded_non_empty("reasoning_effort", effort, MAX_REASONING_EFFORT_BYTES)?;
        }
        if let Some(directory) = &self.working_directory {
            bounded_non_empty("working_directory", directory, MAX_WORKING_DIRECTORY_BYTES)?;
            if !directory.starts_with('/') {
                return Err(ApplicationFailure::invalid_request("working_directory"));
            }
        }
        Ok(())
    }
}

/// Which lane the delegated work belongs to. Providers use it to pick a model
/// when the caller did not name one.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum TaskType {
    Frontend,
    Backend,
    Retrieval,
    Text,
}

/// Stop the active dispatch of one target.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CancelRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub membership_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
}

impl CancelRequest {
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if self.membership_id.is_none() && self.agent_id.is_none() {
            return Err(ApplicationFailure::invalid_request("target"));
        }
        Ok(())
    }
}

/// The Canonical Conversation family.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "command", rename_all = "kebab-case")]
pub enum ConversationCommand {
    List {
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        include_archived: bool,
    },
    Get {
        conversation_id: String,
    },
    Search(SearchRequest),
    Export(ExportRequest),
    Import(ImportRequest),
}

impl ConversationCommand {
    pub const fn family() -> CommandFamily {
        CommandFamily::Conversation
    }

    pub const fn operation(&self) -> Operation {
        match self {
            Self::List { .. } => Operation::ConversationList,
            Self::Get { .. } => Operation::ConversationGet,
            Self::Search(_) => Operation::ConversationSearch,
            Self::Export(_) => Operation::ConversationExport,
            Self::Import(_) => Operation::ConversationImport,
        }
    }

    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        match self {
            Self::List { .. } => Ok(()),
            Self::Get { conversation_id } => stable_id("conversation_id", conversation_id),
            Self::Search(request) => request.validate(),
            Self::Export(request) => request.validate(),
            Self::Import(request) => request.validate(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRequest {
    pub query: String,
    pub limit: u32,
}

impl SearchRequest {
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        bounded_non_empty("query", &self.query, MAX_QUERY_BYTES)?;
        if self.limit == 0 {
            return Err(ApplicationFailure::invalid_request("limit"));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportRequest {
    pub path: String,
    pub conversation_ids: Vec<String>,
}

impl ExportRequest {
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if self.path.trim().is_empty() || self.path.contains('\0') {
            return Err(ApplicationFailure::invalid_request("path"));
        }
        if self.conversation_ids.is_empty() {
            return Err(ApplicationFailure::invalid_request("conversation_ids"));
        }
        for conversation_id in &self.conversation_ids {
            stable_id("conversation_id", conversation_id)?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportRequest {
    pub path: String,
}

impl ImportRequest {
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if self.path.trim().is_empty() || self.path.contains('\0') {
            return Err(ApplicationFailure::invalid_request("path"));
        }
        Ok(())
    }
}

/// Any command either interface can issue.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "family", rename_all = "kebab-case")]
pub enum ApplicationCommand {
    Assistant(AssistantCommand),
    Subagent(SubagentCommand),
    Conversation(ConversationCommand),
}

impl ApplicationCommand {
    pub const fn family(&self) -> CommandFamily {
        match self {
            Self::Assistant(_) => CommandFamily::Assistant,
            Self::Subagent(_) => CommandFamily::Subagent,
            Self::Conversation(_) => CommandFamily::Conversation,
        }
    }

    pub const fn operation(&self) -> Operation {
        match self {
            Self::Assistant(command) => command.operation(),
            Self::Subagent(command) => command.operation(),
            Self::Conversation(command) => command.operation(),
        }
    }

    /// Decode error codes keep the existing `invalid_request` vocabulary, with
    /// the offending field named through `presentationArgs` on the caller side.
    pub fn decode(value: &Value) -> Result<Self, ApplicationFailure> {
        serde_json::from_value(value.clone())
            .map_err(|_| ApplicationFailure::invalid_request("command"))
    }

    pub fn encode(&self) -> Result<Value, ApplicationFailure> {
        serde_json::to_value(self).map_err(|_| ApplicationFailure::invalid_request("command"))
    }

    /// Structural validation. Runs before any port is reached, so a malformed
    /// command can never produce an effect.
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        match self {
            Self::Assistant(command) => command.validate(),
            Self::Subagent(command) => command.validate(),
            Self::Conversation(command) => command.validate(),
        }
    }

    /// The conversation this command addresses, when it addresses exactly one.
    ///
    /// A membership claim admits exactly one conversation, so the facade uses
    /// this to reject a claim that is bound elsewhere. Commands that are not
    /// conversation-scoped (a listing, a run-scoped inspect) return `None` and
    /// leave binding to native verification.
    pub fn conversation_id(&self) -> Option<&str> {
        match self {
            Self::Assistant(command) => match command {
                AssistantCommand::Profiles {
                    conversation_id, ..
                }
                | AssistantCommand::WorkflowExecute {
                    conversation_id, ..
                } => Some(conversation_id.as_str()),
                AssistantCommand::WorkflowInspect { .. }
                | AssistantCommand::WorkflowCancel { .. } => None,
            },
            // A dispatch names its target, not its conversation: the target is
            // resolved *inside* the caller's own conversation, which is what
            // makes cross-conversation work impossible. The claim supplies the
            // conversation, so there is nothing to bind here.
            Self::Subagent(
                SubagentCommand::List
                | SubagentCommand::Probe { .. }
                | SubagentCommand::Delegate(_)
                | SubagentCommand::Continue(_)
                | SubagentCommand::Cancel(_),
            ) => None,
            Self::Conversation(command) => match command {
                ConversationCommand::Get { conversation_id } => Some(conversation_id.as_str()),
                ConversationCommand::List { .. }
                | ConversationCommand::Search(_)
                | ConversationCommand::Export(_)
                | ConversationCommand::Import(_) => None,
            },
        }
    }
}

fn stable_id(field: &'static str, value: &str) -> Result<(), ApplicationFailure> {
    bounded_non_empty(field, value, MAX_STABLE_ID_BYTES)
}

fn provider(field: &'static str, value: &str) -> Result<(), ApplicationFailure> {
    if value.is_empty()
        || value.len() > crate::actor::MAX_PROVIDER_ID_BYTES
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        return Err(ApplicationFailure::invalid_request(field));
    }
    Ok(())
}

fn bounded_non_empty(
    field: &'static str,
    value: &str,
    max: usize,
) -> Result<(), ApplicationFailure> {
    if value.trim().is_empty() || value.len() > max || value.contains('\0') {
        return Err(ApplicationFailure::invalid_request(field));
    }
    Ok(())
}
