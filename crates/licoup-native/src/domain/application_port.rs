//! Native ports behind the shared `licoup_application` facade.
//!
//! The typed CLI surface (`licoup conversation list|get`) does not talk to a
//! concrete service. It decodes its argv into a [`licoup_application`] command,
//! hands it to [`ApplicationFacade`], and prints the facade's resolution. This
//! module is the backend the facade runs against for this slice.
//!
//! Two properties are load-bearing:
//!
//! - Durable work reaches the *already running* conversation host through
//!   [`crate::platform::subagent_mcp_host_client::execute_existing`]. With no
//!   host running the call fails closed with
//!   `persistent_conversation_transport_required`. This adapter never opens a
//!   process-local `ConversationService`, so a one-shot CLI process cannot
//!   silently serve a private store.
//! - The actor is the in-process local admin. [`LocalAdminActor`] verifies that
//!   natively — this process *is* the local owner — and refuses an agent
//!   membership claim, which only an authenticated transport may make.
//!
//! The assistant and subagent families are not part of this slice. Their ports
//! fail closed with a typed `application_family_unsupported` failure so the
//! facade assembly stays total without inventing behaviour.

use crate::contracts::conversation_protocol::ConversationProtocolMethod;
use licoup_application::{
    ActorClaim, ActorPort, ApplicationCommand, ApplicationFacade, ApplicationFailure,
    ApplicationPorts, AssistantCommand, AssistantPort, CommandOutcome, CommandResolution,
    ConversationCommand, ConversationPort, Operation, OperationReference, OperationState,
    RecoveryAction, SubagentCommand, SubagentPort,
};
use serde_json::{Value, json};

/// The owner membership the in-process CLI acts as.
///
/// The business contract's own fixtures name their local admin this way
/// (`crates/licoup-application/tests/command_contract.rs`). This slice verifies
/// the claim by process ownership rather than by a store lookup, so naming it
/// needs no store access.
pub const LOCAL_ADMIN_OWNER_MEMBERSHIP_ID: &str = "membership:owner";

/// Where a durable-host transport failure happened.
const CONVERSATION_TRANSPORT_STAGE: &str = "conversation/transport";

/// The durable host method both reads travel over.
///
/// This is one of the frozen 29 RPC methods; the typed surface reuses it rather
/// than adding a wire method of its own.
const CONVERSATION_HOST_METHOD: &str =
    ConversationProtocolMethod::ClientConversationExecute.as_str();

/// Run one typed command as the local admin and report its resolution.
pub fn execute(command: &ApplicationCommand) -> CommandResolution {
    match application_facade().execute(&local_admin_claim(), command) {
        Ok(outcome) => CommandResolution::Resolved(outcome),
        Err(failure) => CommandResolution::Failed(failure),
    }
}

/// The local-admin claim the in-process CLI acts as.
pub fn local_admin_claim() -> ActorClaim {
    ActorClaim::local_admin(LOCAL_ADMIN_OWNER_MEMBERSHIP_ID)
}

/// The single facade the typed surface runs through.
fn application_facade() -> ApplicationFacade {
    ApplicationFacade::new(ApplicationPorts::new(
        std::sync::Arc::new(LocalAdminActor),
        std::sync::Arc::new(UnsupportedFamily),
        std::sync::Arc::new(UnsupportedFamily),
        std::sync::Arc::new(DurableConversationHost),
    ))
}

/// Verify the in-process caller.
struct LocalAdminActor;

impl ActorPort for LocalAdminActor {
    fn verify(&self, claim: &ActorClaim) -> Result<(), ApplicationFailure> {
        if claim.is_local_admin() {
            return Ok(());
        }
        // An agent claim is only authentic through an authenticated transport;
        // an in-process CLI has no transport and must not speak for one.
        Err(ApplicationFailure::permanent(
            "actor_authenticated_transport_required",
            "actor/verify",
        ))
    }
}

/// The two Canonical Conversation reads, over the durable host.
struct DurableConversationHost;

impl ConversationPort for DurableConversationHost {
    fn execute(
        &self,
        _claim: &ActorClaim,
        command: &ConversationCommand,
    ) -> Result<CommandOutcome, ApplicationFailure> {
        match command {
            ConversationCommand::List { include_archived } => {
                let payload = host_read(json!({
                    "action": "conversation.list",
                    "includeArchived": include_archived,
                }))?;
                Ok(read_outcome(Operation::ConversationList, payload))
            }
            ConversationCommand::Get { conversation_id } => {
                let payload = host_read(json!({
                    "action": "conversation.get",
                    "conversationId": conversation_id,
                }))?;
                Ok(read_outcome(Operation::ConversationGet, payload))
            }
            _ => Err(ApplicationFailure::permanent(
                "conversation_operation_unsupported",
                "conversation/execute",
            )),
        }
    }
}

/// Families this slice does not serve yet.
struct UnsupportedFamily;

impl AssistantPort for UnsupportedFamily {
    fn execute(
        &self,
        _claim: &ActorClaim,
        _command: &AssistantCommand,
    ) -> Result<CommandOutcome, ApplicationFailure> {
        Err(unsupported_family())
    }
}

impl SubagentPort for UnsupportedFamily {
    fn execute(
        &self,
        _claim: &ActorClaim,
        _command: &SubagentCommand,
    ) -> Result<CommandOutcome, ApplicationFailure> {
        Err(unsupported_family())
    }
}

fn unsupported_family() -> ApplicationFailure {
    ApplicationFailure::permanent("application_family_unsupported", "application/execute")
}

/// A read outcome: no live identity to follow, just the operation's own body.
fn read_outcome(operation: Operation, payload: Value) -> CommandOutcome {
    CommandOutcome::new(OperationReference::new(
        operation,
        "",
        OperationState::Completed,
    ))
    .with_payload(payload)
}

/// One durable read through the already-running conversation host.
///
/// The transport answers inside its own envelope, so the operation's own body
/// is the nested `result`. Publishing the envelope verbatim would leak the
/// transport into a versioned payload.
fn host_read(params: Value) -> Result<Value, ApplicationFailure> {
    let response = crate::platform::subagent_mcp_host_client::execute_existing(
        CONVERSATION_HOST_METHOD,
        &params,
    )
    .map_err(|error| host_failure(&error))?;
    operation_payload(response)
}

/// The operation's own body out of one host reply.
fn operation_payload(response: Value) -> Result<Value, ApplicationFailure> {
    response.get("result").cloned().ok_or_else(|| {
        ApplicationFailure::retryable(
            "conversation_state_unavailable",
            CONVERSATION_TRANSPORT_STAGE,
        )
    })
}

/// Map a host failure onto the normalized failure model.
///
/// A missing host is retryable *and* needs the runtime installed or restarted,
/// so its recovery is projected accordingly. A missing conversation and a
/// rejected request are permanent, so a caller is not told to retry them.
fn host_failure(error: &anyhow::Error) -> ApplicationFailure {
    let message = error.to_string();
    let code = message.split(':').next().unwrap_or_default().trim();
    match code {
        "persistent_conversation_transport_required" => {
            ApplicationFailure::retryable(code, CONVERSATION_TRANSPORT_STAGE)
                .with_recovery(RecoveryAction::InstallOrRetryRuntime)
        }
        "conversation_not_found" | "invalid_request" => {
            ApplicationFailure::permanent(code, CONVERSATION_TRANSPORT_STAGE)
        }
        "" => ApplicationFailure::retryable(
            "conversation_transport_failed",
            CONVERSATION_TRANSPORT_STAGE,
        ),
        other => ApplicationFailure::retryable(other, CONVERSATION_TRANSPORT_STAGE),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_read_publishes_the_operation_body_not_the_transport_envelope() {
        let payload = operation_payload(json!({
            "ok": true,
            "result": [{"id": "lico-group-default"}],
        }))
        .expect("a completed reply carries a body");
        assert_eq!(payload, json!([{"id": "lico-group-default"}]));
    }

    #[test]
    fn a_reply_without_a_body_is_retryable_rather_than_published() {
        let failure = operation_payload(json!({"ok": false})).expect_err("no body to publish");
        assert_eq!(failure.code, "conversation_state_unavailable");
        assert_eq!(failure.stage, CONVERSATION_TRANSPORT_STAGE);
        assert!(failure.retryable);
    }
}
