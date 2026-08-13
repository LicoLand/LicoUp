use super::super::support::temp_cli_dir;
use super::*;
use licoup_native::domain::client_conversation::ConversationService;

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
fn ordinary_stdio_rpc_rejects_every_conversation_dispatch_entry_point() {
    let _serial = claude_process_local_test_lock::lock_claude_process_local_tests();
    let input = rpc_input(&[
        json!({
            "protocol": STDIO_RPC_PROTOCOL,
            "id": "request-1",
            "workflowId": "workflow-1",
            "method": "agent.conversation.send",
            "params": {"agent": "synthetic", "text": "private"},
        }),
        execute_request(
            "request-2",
            "workflow-1",
            &["agent", "conversation", "send"],
        ),
        execute_request(
            "request-3",
            "workflow-1",
            &[
                "agent",
                "conversation",
                "send",
                "--stdin-json",
                r#"{"invalid""#,
            ],
        ),
        execute_request(
            "request-4",
            "workflow-1",
            &["conversation", "execute", "--stdin-json", "{}"],
        ),
        execute_request(
            "request-5",
            "workflow-1",
            &["conversation", "execute", "--stdin-json", r#"{"invalid""#],
        ),
        json!({
            "protocol": STDIO_RPC_PROTOCOL,
            "id": "request-6",
            "workflowId": "workflow-1",
            "method": "client.conversation.execute",
            "params": {
                "action": "conversation.message.post",
                "mentionedMembershipIds": ["membership:agent"]
            },
        }),
    ]);
    let output = serve_stdio_rpc(input, Vec::new(), |_, _| -> anyhow::Result<_> {
        panic!("conversation dispatch must not reach ordinary stdio execution")
    })
    .unwrap();

    let frames = rpc_output(output);
    assert_eq!(frames.len(), 6);
    for frame in frames {
        assert_eq!(frame["error"]["code"], "command_failed");
        assert_eq!(frame["error"]["component"], "native_cli");
    }
}

#[test]
fn persistent_conversation_rpc_projects_admission_without_execute_fallback() {
    let _serial = claude_process_local_test_lock::lock_claude_process_local_tests();
    let portable = temp_cli_dir("persistent-conversation-admission-rpc");
    let service = ConversationService::open(&portable).unwrap();
    let runtime = PersistentConversationRuntime::new(service.store().clone());
    let input = rpc_input(&[
        execute_request(
            "request-1",
            "workflow-1",
            &[
                "agent",
                "conversation",
                "send",
                "--stdin-json",
                r#"{"invalid""#,
            ],
        ),
        execute_request(
            "request-2",
            "workflow-1",
            &[
                "agent",
                "conversation",
                "stream",
                "--stdin-json",
                r#"{"invalid""#,
            ],
        ),
        execute_request(
            "request-3",
            "workflow-1",
            &[
                "agent",
                "conversation",
                "steer",
                "--stdin-json",
                r#"{"invalid""#,
            ],
        ),
        execute_request(
            "request-4",
            "workflow-1",
            &[
                "agent",
                "conversation",
                "cancel",
                "--stdin-json",
                r#"{"invalid""#,
            ],
        ),
        execute_request(
            "request-5",
            "workflow-1",
            &["agent", "conversation", "send", "--stdin-json", "{}"],
        ),
        execute_request(
            "request-6",
            "workflow-1",
            &["conversation", "execute", "--stdin-json", r#"{"invalid""#],
        ),
        execute_request(
            "request-7",
            "workflow-1",
            &["conversation", "execute", "--stdin-json", "{}"],
        ),
    ]);
    let output = serve_stdio_rpc_with_runtime(
        input,
        Vec::new(),
        |_, _| -> anyhow::Result<_> {
            panic!("legacy execute must never dispatch persistent conversation work")
        },
        runtime,
    )
    .unwrap();

    let frames = rpc_output(output);
    assert_eq!(frames.len(), 7);
    for frame in &frames[..4] {
        assert_eq!(frame["error"]["code"], "cli_json_invalid");
        assert_eq!(frame["error"]["stage"], "cli/admission");
        assert_eq!(frame["error"]["component"], "native_cli");
    }
    assert_eq!(frames[4]["error"]["code"], "command_failed");
    assert_eq!(frames[5]["error"]["code"], "cli_json_invalid");
    assert_eq!(frames[5]["error"]["stage"], "cli/admission");
    assert_eq!(frames[5]["error"]["component"], "native_cli");
    assert_eq!(frames[6]["error"]["code"], "command_failed");
    drop(service);
    let _ = fs::remove_dir_all(portable);
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
