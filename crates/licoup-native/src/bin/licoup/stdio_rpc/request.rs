use super::*;
use licoup_native::contracts::conversation_protocol::{
    ConversationCommand, ConversationProtocolMethod,
};
use licoup_native::ffi::generated::client_state::{
    ClientStateCollection, ClientStateFailure, ClientStateFailureCode,
};

#[path = "request/io_policy.rs"]
mod io_policy;
pub(crate) use io_policy::{rpc_command_reads_external_stdin, rpc_command_writes_external_stdout};

pub(crate) fn parse_stdio_rpc_request(
    bytes: &[u8],
) -> std::result::Result<StdioRpcRequest, StdioRpcRequestError> {
    // Method names, envelope fields, identifier bounds, and argument bounds
    // all come from the generated conversation protocol contract
    // (schemas/conversation_protocol/, generated into
    // licoup_native::contracts::conversation_protocol). The hand-written
    // method string table is gone: this file only maps generated method
    // variants onto the process-local dispatch shape.
    let command = ConversationCommand::decode(bytes).map_err(|error| StdioRpcRequestError {
        id: error.id,
        workflow_id: error.workflow_id,
        code: error.code,
    })?;
    let request_id = &command.id;
    let request_workflow_id = &command.workflow_id;
    let portable_data_dir = command.portable_data_dir;
    let method = match command.method {
        ConversationProtocolMethod::Execute => StdioRpcMethod::Execute {
            args: command
                .args
                .expect("generated execute commands always carry validated args"),
            portable_data_dir,
        },
        ConversationProtocolMethod::CatalogStatus
        | ConversationProtocolMethod::CatalogInvalidate
        | ConversationProtocolMethod::CatalogRefresh
        | ConversationProtocolMethod::CatalogReceipt
        | ConversationProtocolMethod::CatalogPurge
        | ConversationProtocolMethod::CatalogReconnect
        | ConversationProtocolMethod::CatalogList
        | ConversationProtocolMethod::CatalogObserve => StdioRpcMethod::Catalog {
            operation: command
                .method
                .as_str()
                .strip_prefix("catalog.")
                .unwrap_or_else(|| command.method.as_str())
                .to_string(),
            params: command.params,
            portable_data_dir,
        },
        ConversationProtocolMethod::StateGet => {
            let failure = ClientStateFailure::new(ClientStateFailureCode::InvalidCollection);
            let request = serde_json::from_value(command.params).map_err(|_| {
                invalid_request_id(request_id, request_workflow_id, failure.code.as_str())
            })?;
            StdioRpcMethod::StateGet {
                request,
                portable_data_dir,
            }
        }
        ConversationProtocolMethod::StateSet => {
            let collection_failure =
                ClientStateFailure::new(ClientStateFailureCode::InvalidCollection);
            command
                .params
                .get("collection")
                .cloned()
                .and_then(|value| serde_json::from_value::<ClientStateCollection>(value).ok())
                .ok_or_else(|| {
                    invalid_request_id(
                        request_id,
                        request_workflow_id,
                        collection_failure.code.as_str(),
                    )
                })?;
            let document_failure = ClientStateFailure::new(ClientStateFailureCode::InvalidDocument);
            let request = serde_json::from_value(command.params).map_err(|_| {
                invalid_request_id(
                    request_id,
                    request_workflow_id,
                    document_failure.code.as_str(),
                )
            })?;
            StdioRpcMethod::StateSet {
                request,
                portable_data_dir,
            }
        }
        ConversationProtocolMethod::AgentConversationOpen
        | ConversationProtocolMethod::AgentConversationSend
        | ConversationProtocolMethod::AgentConversationDispatch
        | ConversationProtocolMethod::AgentConversationCancel
        | ConversationProtocolMethod::AgentConversationHistory
        | ConversationProtocolMethod::AgentConversationCleanup
        | ConversationProtocolMethod::AgentConversationSteer
        | ConversationProtocolMethod::AgentConversationCapabilities
        | ConversationProtocolMethod::AgentConversationStream
        | ConversationProtocolMethod::AgentConversationActive
        | ConversationProtocolMethod::AgentConversationAttach => StdioRpcMethod::Conversation {
            operation: command
                .method
                .as_str()
                .strip_prefix("agent.conversation.")
                .unwrap_or_else(|| command.method.as_str())
                .to_string(),
            params: command.params,
            portable_data_dir,
        },
        ConversationProtocolMethod::ClientConversationExecute => {
            StdioRpcMethod::ClientConversation {
                params: command.params,
                portable_data_dir,
            }
        }
        ConversationProtocolMethod::StrategyExecute => StdioRpcMethod::StrategyExecute {
            params: command.params,
            portable_data_dir,
        },
        // Structured private-stdin commands. The stdin JSON payload is carried
        // as structured params inside the RPC frame on the wire (never smuggled
        // through a CLI argument array); the process-local CLI admission is
        // reconstructed here inside the host boundary.
        ConversationProtocolMethod::TargetsScan => StdioRpcMethod::Execute {
            args: private_stdin_cli_args(
                &[
                    "targets",
                    "scan",
                    "--include-accessible-environments",
                    "true",
                ],
                None,
                command.params,
            ),
            portable_data_dir,
        },
        ConversationProtocolMethod::TargetsAdd => StdioRpcMethod::Execute {
            args: private_stdin_cli_args(
                &["targets", "add", "--target"],
                Some("target"),
                command.params,
            ),
            portable_data_dir,
        },
        ConversationProtocolMethod::GatewayCredentialsCreate => StdioRpcMethod::Execute {
            args: private_stdin_cli_args(
                &["llm-gateway", "credentials", "create"],
                None,
                command.params,
            ),
            portable_data_dir,
        },
        ConversationProtocolMethod::GatewayCredentialsUpdate => StdioRpcMethod::Execute {
            args: private_stdin_cli_args(
                &["llm-gateway", "credentials", "update"],
                Some("credentialId"),
                command.params,
            ),
            portable_data_dir,
        },
        ConversationProtocolMethod::Shutdown => StdioRpcMethod::Shutdown,
    };
    Ok(StdioRpcRequest {
        id: request_id.clone(),
        workflow_id: request_workflow_id.clone(),
        method,
    })
}

fn invalid_request_id(
    id: &String,
    workflow_id: &String,
    code: &'static str,
) -> StdioRpcRequestError {
    StdioRpcRequestError {
        id: Some(id.clone()),
        workflow_id: Some(workflow_id.clone()),
        code,
    }
}

/// Rebuild the process-local CLI argv for a private-stdin structured command.
///
/// `argv` is the invariant leading CLI tokens, `positional` is the structured
/// param that must appear as the single positional-value token before the
/// `--stdin-json` JSON payload, and `params` becomes the trailing stdin JSON.
/// This keeps the JSON payload out of the CLI argument array across the RPC
/// wire while preserving the exact command shape the one-shot CLI path uses.
fn private_stdin_cli_args(argv: &[&str], positional: Option<&str>, params: Value) -> Vec<String> {
    let mut args: Vec<String> = argv.iter().map(|value| (*value).to_string()).collect();
    if let Some(positional_param) = positional {
        let value = params
            .get(positional_param)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or_default();
        args.push(value.to_string());
    }
    args.push("--stdin-json".to_string());
    args.push(serde_json::to_string(&params).expect("validated structured params serialize"));
    args
}

// The bin-level frame limits must stay congruent with the schema-derived
// conversation protocol contract. Keeping the compile-time comparison here
// makes a config drift a build error instead of a silent wire-format change.
const _: () = assert!(
    STDIO_RPC_MAX_ARGS
        == licoup_native::contracts::conversation_protocol::CONVERSATION_PROTOCOL_MAX_ARGS
);
const _: () = assert!(
    STDIO_RPC_MAX_ID_BYTES
        == licoup_native::contracts::conversation_protocol::CONVERSATION_PROTOCOL_MAX_ID_BYTES
);
