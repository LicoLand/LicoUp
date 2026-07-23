use super::*;

pub(super) fn compile_rpc_fake_claude(prefix: &str) -> (std::path::PathBuf, std::path::PathBuf) {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let directory = std::env::temp_dir().join(format!("{prefix}-{nonce}"));
    std::fs::create_dir_all(&directory).unwrap();
    let fixture =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_claude_code.rs");
    let executable = directory.join(format!("fake-claude{}", std::env::consts::EXE_SUFFIX));
    let status =
        std::process::Command::new(std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string()))
            .arg("--edition=2024")
            .arg(fixture)
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap();
    assert!(status.success());
    (directory, executable)
}

#[cfg(unix)]
pub(super) fn rpc_process_exists(pid: u32) -> bool {
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

#[cfg(not(unix))]
pub(super) fn rpc_process_exists(_pid: u32) -> bool {
    false
}

pub(super) fn conversation_request(id: &str, operation: &str, params: Value) -> Value {
    json!({
        "protocol": STDIO_RPC_PROTOCOL,
        "id": id,
        "workflowId": "workflow-process-local",
        "method": format!("agent.conversation.{operation}"),
        "params": params,
    })
}

pub(super) fn claude_params(
    executable: &std::path::Path,
    working_directory: &std::path::Path,
    text: Option<&str>,
    session_id: Option<&str>,
) -> Value {
    let mut value = json!({
        "agent": "claude-code",
        "binaryPath": executable,
        "workingDirectory": working_directory,
        "model": "fake-model",
        "reasoningEffort": "high",
        "permissionMode": "plan",
        "timeoutMs": 10_000,
        "maxStdoutBytes": 1024 * 1024,
        "maxStderrBytes": 1024,
    });
    if let Some(text) = text {
        value["text"] = Value::String(text.to_string());
    }
    if let Some(session_id) = session_id {
        value["sessionId"] = Value::String(session_id.to_string());
    }
    value
}

pub(super) fn rpc_input(requests: &[Value]) -> Cursor<Vec<u8>> {
    let mut bytes = Vec::new();
    for request in requests {
        serde_json::to_writer(&mut bytes, request).unwrap();
        bytes.push(b'\n');
    }
    Cursor::new(bytes)
}

pub(super) fn rpc_output(bytes: Vec<u8>) -> Vec<Value> {
    String::from_utf8(bytes)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}
