use super::super::support::temp_cli_dir;
use super::*;

fn rpc_input(requests: &[Value]) -> Cursor<Vec<u8>> {
    let mut bytes = Vec::new();
    for request in requests {
        serde_json::to_writer(&mut bytes, request).unwrap();
        bytes.push(b'\n');
    }
    Cursor::new(bytes)
}

fn rpc_output(bytes: Vec<u8>) -> Vec<Value> {
    String::from_utf8(bytes)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn execute_request(id: &str, workflow_id: &str, args: &[&str]) -> Value {
    json!({
        "protocol": STDIO_RPC_PROTOCOL,
        "id": id,
        "workflowId": workflow_id,
        "method": "execute",
        "args": args,
    })
}

#[test]
fn stdio_rpc_frames_results_errors_and_shutdown() {
    let _serial = claude_process_local_test_lock::lock_claude_process_local_tests();
    let input = rpc_input(&[
        execute_request("request-1", "workflow-1", &["ok"]),
        execute_request("request-2", "workflow-1", &["fail"]),
        json!({
            "protocol": STDIO_RPC_PROTOCOL,
            "id": "request-3",
            "workflowId": "workflow-1",
            "method": "shutdown",
        }),
    ]);
    let output = serve_stdio_rpc(input, Vec::new(), |args, _| match args[0].as_str() {
        "ok" => Ok(licoup_native::ffi::commands::CliExecution::Json(
            json!({"status": "ok"}),
        )),
        _ => Err(anyhow::anyhow!("sensitive internal failure")),
    })
    .unwrap();

    let frames = rpc_output(output);
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[0]["result"]["status"], "ok");
    assert_eq!(frames[1]["error"]["code"], "command_failed");
    assert!(!frames[1].to_string().contains("sensitive internal failure"));
    assert_eq!(frames[2]["result"]["status"], "shutdown");
}

#[test]
fn stdio_rpc_rejects_cross_workflow_requests_and_continues() {
    let _serial = claude_process_local_test_lock::lock_claude_process_local_tests();
    let input = rpc_input(&[
        execute_request("request-1", "workflow-1", &["ok"]),
        execute_request("request-2", "workflow-2", &["ok"]),
        json!({
            "protocol": STDIO_RPC_PROTOCOL,
            "id": "request-3",
            "workflowId": "workflow-1",
            "method": "shutdown",
        }),
    ]);
    let output = serve_stdio_rpc(input, Vec::new(), |_, _| {
        Ok(licoup_native::ffi::commands::CliExecution::Json(
            json!({"status": "ok"}),
        ))
    })
    .unwrap();

    let frames = rpc_output(output);
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[1]["workflowId"], "workflow-2");
    assert_eq!(frames[1]["error"]["code"], "workflow_mismatch");
    assert_eq!(frames[2]["ok"], true);
}

#[test]
fn stdio_rpc_rejects_streaming_execute_without_invoking_the_command() {
    let _serial = claude_process_local_test_lock::lock_claude_process_local_tests();
    let input = rpc_input(&[execute_request(
        "request-1",
        "workflow-1",
        &["conversations", "stream"],
    )]);
    let output = serve_stdio_rpc(input, Vec::new(), |_, _| -> anyhow::Result<_> {
        panic!("streaming execute must not reach the command closure")
    })
    .unwrap();

    let frames = rpc_output(output);
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0]["error"]["code"], "streaming_command_unsupported");
}

#[test]
fn stdio_rpc_conversation_send_rejects_missing_agent_before_dispatch() {
    let _serial = claude_process_local_test_lock::lock_claude_process_local_tests();
    let input = rpc_input(&[json!({
        "protocol": STDIO_RPC_PROTOCOL,
        "id": "request-1",
        "workflowId": "workflow-1",
        "method": "agent.conversation.send",
        "params": {},
    })]);
    let output = serve_stdio_rpc(input, Vec::new(), |_, _| {
        Ok(licoup_native::ffi::commands::CliExecution::Usage)
    })
    .unwrap();

    let frames = rpc_output(output);
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0]["kind"], "terminal");
    assert_eq!(frames[0]["ok"], false);
    assert_eq!(frames[0]["error"]["code"], "agent_identifier_missing");
}

#[test]
fn stdio_rpc_executes_client_conversation_actions_on_the_bound_portable_root() {
    let _serial = claude_process_local_test_lock::lock_claude_process_local_tests();
    let portable = temp_cli_dir("client-conversation-rpc");
    let input = rpc_input(&[
        json!({
            "protocol": STDIO_RPC_PROTOCOL,
            "id": "request-1",
            "workflowId": "workflow-1",
            "method": "client.conversation.execute",
            "params": {"action": "conversation.list", "includeArchived": false},
            "portableDataDir": portable,
        }),
        json!({
            "protocol": STDIO_RPC_PROTOCOL,
            "id": "request-2",
            "workflowId": "workflow-1",
            "method": "shutdown",
        }),
    ]);
    let output = serve_stdio_rpc(input, Vec::new(), |_, _| {
        panic!("structured client conversation must not reach execute")
    })
    .unwrap();

    let frames = rpc_output(output);
    assert_eq!(frames[0]["ok"], true);
    assert_eq!(frames[0]["result"]["ok"], true);
    assert_eq!(frames[0]["result"]["result"], json!([]));
    let _ = fs::remove_dir_all(portable);
}
