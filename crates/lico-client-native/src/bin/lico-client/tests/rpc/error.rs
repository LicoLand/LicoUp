use super::*;
use lico_client_native::ffi::generated::client_error::ClientError;
use serde_json::{Value, json};

#[test]
fn typed_client_error_metadata_survives_command_and_terminal_rpc_frames() {
    let expected_errors = [
        json!({
            "code": "invalid_request",
            "stage": "request/validation",
            "component": "stdio_rpc",
            "retryable": false,
            "recovery": "correct_request",
            "presentationArgs": {"field": "method"}
        }),
        json!({
            "code": "agent_runtime_unsupported",
            "stage": "discovery/adapter",
            "component": "runtime_adapter",
            "retryable": false,
            "recovery": "select_supported_adapter",
            "presentationArgs": {"agentLabel": "Fixture Agent"}
        }),
        json!({
            "code": "native_agent_executable_unavailable",
            "stage": "process/launch",
            "component": "runtime_process",
            "retryable": true,
            "recovery": "install_or_retry_runtime",
            "presentationArgs": {"runtimeLabel": "Fixture Runtime"}
        }),
        json!({
            "code": "agent_conversation_dispatch_failed",
            "stage": "conversation/dispatch",
            "component": "conversation_runtime",
            "retryable": true,
            "recovery": "preserve_draft_and_retry",
            "presentationArgs": {"agentLabel": "Fixture Agent"}
        }),
        json!({
            "code": "stream_protocol_failed",
            "stage": "conversation/stream_receive",
            "component": "stdio_rpc",
            "retryable": true,
            "recovery": "preserve_draft_and_retry",
            "presentationArgs": {"sequence": "7"}
        }),
        json!({
            "code": "terminal_result_invalid",
            "stage": "conversation/terminal_result",
            "component": "conversation_runtime",
            "retryable": false,
            "recovery": "review_terminal_result",
            "presentationArgs": {"resultKind": "terminal"}
        }),
    ];

    for (index, expected) in expected_errors.into_iter().enumerate() {
        let error: ClientError = serde_json::from_value(expected.clone()).unwrap();
        let request_id = format!("request-{index}");

        let mut command_writer = Vec::new();
        write_stdio_rpc_error(
            &mut command_writer,
            Some(&request_id),
            Some("workflow-1"),
            &error,
        )
        .unwrap();
        let command: Value = serde_json::from_slice(&command_writer).unwrap();
        assert_eq!(command["error"], expected);

        let terminal_writer = Arc::new(Mutex::new(Vec::new()));
        write_stdio_rpc_terminal_error(&terminal_writer, &request_id, "workflow-1", 1, &error)
            .unwrap();
        let terminal: Value =
            serde_json::from_slice(&recover_stdio_rpc_writer(terminal_writer).unwrap()).unwrap();
        assert_eq!(terminal["kind"], "terminal");
        assert_eq!(terminal["sequence"], 1);
        assert_eq!(terminal["error"], expected);
    }
}
