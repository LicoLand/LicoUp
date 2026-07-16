pub(crate) fn stdio_rpc_error_message(code: &str) -> &'static str {
    match code {
        "request_too_large" => "request exceeds the protocol limit",
        "response_too_large" => "response exceeds the protocol limit",
        "invalid_json" => "request is not valid JSON",
        "invalid_request"
        | "invalid_protocol"
        | "invalid_request_id"
        | "invalid_workflow_id"
        | "invalid_method"
        | "invalid_args"
        | "invalid_portable_data_dir"
        | "invalid_params" => "request does not match the protocol",
        "workflow_mismatch" => "request does not belong to this RPC workflow",
        "command_usage" => "command requires different arguments",
        "streaming_command_unsupported" => "command is not compatible with framed RPC output",
        "stream_protocol_failed" => "conversation event stream failed validation",
        "authorization_required" => "user authorization is required",
        "authorization_failed" => "user authorization did not complete",
        "command_panicked" => "command terminated unexpectedly",
        _ => "command failed",
    }
}

pub(crate) fn stdio_rpc_command_error_code(error: &anyhow::Error) -> &'static str {
    if error.chain().any(|cause| {
        cause
            .to_string()
            .contains("secure_mesh_authorization_required")
    }) {
        return "authorization_required";
    }
    if error.chain().any(|cause| {
        let message = cause.to_string();
        message.contains("system authentication failed closed")
            || message.contains("system authentication timed out")
    }) {
        return "authorization_failed";
    }
    "command_failed"
}
