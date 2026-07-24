use licoup_native::ffi::generated::client_error::{
    ClientError, ClientErrorCode, ClientErrorComponent, ClientErrorRecovery, ClientErrorStage,
};
use licoup_native::ffi::generated::client_state::ClientStateFailure;

pub(crate) fn stdio_rpc_client_error(code: &str) -> ClientError {
    let code = serde_json::from_value(serde_json::Value::String(code.to_owned()))
        .unwrap_or(ClientErrorCode::CommandFailed);
    let (stage, component, retryable, recovery) = match code {
        ClientErrorCode::InvalidRequest
        | ClientErrorCode::RequestTooLarge
        | ClientErrorCode::InvalidJson
        | ClientErrorCode::InvalidProtocol
        | ClientErrorCode::InvalidRequestId
        | ClientErrorCode::InvalidWorkflowId
        | ClientErrorCode::InvalidMethod
        | ClientErrorCode::InvalidArgs
        | ClientErrorCode::InvalidPortableDataDir
        | ClientErrorCode::InvalidParams
        | ClientErrorCode::InvalidCollection
        | ClientErrorCode::InvalidDocument
        | ClientErrorCode::WorkflowMismatch => (
            ClientErrorStage::RequestValidation,
            ClientErrorComponent::StdioRpc,
            false,
            ClientErrorRecovery::CorrectRequest,
        ),
        ClientErrorCode::StreamProtocolFailed => (
            ClientErrorStage::ConversationStreamReceive,
            ClientErrorComponent::StdioRpc,
            true,
            ClientErrorRecovery::PreserveDraftAndRetry,
        ),
        ClientErrorCode::CliCommandMissing
        | ClientErrorCode::CliCommandUnknown
        | ClientErrorCode::CliOperationUnsupported
        | ClientErrorCode::CliRequiredArgumentMissing
        | ClientErrorCode::CliArgumentUnexpected
        | ClientErrorCode::CliOptionUnknown
        | ClientErrorCode::CliRequiredOptionMissing
        | ClientErrorCode::CliOptionValueMissing
        | ClientErrorCode::CliOptionDuplicate
        | ClientErrorCode::CliOptionConstraintViolation
        | ClientErrorCode::CliJsonInvalid
        | ClientErrorCode::CliArgumentCountExceeded
        | ClientErrorCode::CliArgumentBytesExceeded => (
            ClientErrorStage::RequestValidation,
            ClientErrorComponent::NativeCli,
            false,
            ClientErrorRecovery::CorrectRequest,
        ),
        _ => (
            ClientErrorStage::StdioRpcResponse,
            ClientErrorComponent::NativeCli,
            false,
            ClientErrorRecovery::RetryOrReviewRequest,
        ),
    };
    ClientError::new(code, stage, component, retryable, recovery)
}

pub(crate) fn stdio_rpc_state_failure(error: ClientStateFailure) -> ClientError {
    stdio_rpc_client_error(error.code.as_str())
}

pub(crate) fn stdio_rpc_command_error(error: &anyhow::Error) -> ClientError {
    if error.chain().any(|cause| {
        cause
            .to_string()
            .contains("secure_mesh_authorization_required")
    }) {
        return stdio_rpc_client_error("authorization_required");
    }
    if error.chain().any(|cause| {
        let message = cause.to_string();
        message.contains("system authentication failed closed")
            || message.contains("system authentication timed out")
    }) {
        return stdio_rpc_client_error("authorization_failed");
    }
    if let Some(error) = error.downcast_ref::<licoup_native::ffi::commands::CliCommandError>() {
        return stdio_rpc_client_error(error.code());
    }
    stdio_rpc_client_error("command_failed")
}
