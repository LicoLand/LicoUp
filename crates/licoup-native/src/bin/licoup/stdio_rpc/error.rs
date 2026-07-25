use licoup_native::ffi::generated::client_error::{ClientError, ClientErrorCode};
use licoup_native::ffi::generated::client_state::ClientStateFailure;

#[path = "error/metadata.rs"]
mod metadata;

pub(crate) fn stdio_rpc_client_error(code: &str) -> ClientError {
    let code = serde_json::from_value(serde_json::Value::String(code.to_owned()))
        .unwrap_or(ClientErrorCode::CommandFailed);
    let (stage, component, retryable, recovery) = metadata::for_code(&code);
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
