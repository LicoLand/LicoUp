use serde_json::Value;
use std::path::Path;

use super::acp_driver_runtime::{AcpDriverSpec, execute_acp, probe_acp};
pub(super) use super::acp_driver_runtime::{CapabilityProbe, ProtocolFailure, RunResult};

pub(super) const RUNTIME_PROTOCOL: &str = "copilot-acp-v1-stdio-ndjson";
const COPILOT_DRIVER: AcpDriverSpec =
    AcpDriverSpec::new(RUNTIME_PROTOCOL, &["--acp", "--stdio", "--no-auto-update"])
        .with_identity("copilot-acp", "copilot_acp");

pub(super) fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    probe_acp(
        COPILOT_DRIVER,
        executable,
        cwd,
        timeout_ms,
        max_stdout,
        max_stderr,
    )
}

pub(super) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> RunResult {
    execute_acp(
        COPILOT_DRIVER,
        executable,
        params,
        prompt,
        session_id,
        cwd,
        timeout_ms,
        max_stdout,
        max_stderr,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn copilot_launch_arguments_are_fixed_and_private_values_use_acp_stdin() {
        assert_eq!(
            COPILOT_DRIVER.launch_args,
            &["--acp", "--stdio", "--no-auto-update"]
        );
        assert!(
            !COPILOT_DRIVER.launch_args.iter().any(
                |arg| *arg == "private-prompt" || *arg == concat!("/", "private", "/workspace")
            )
        );
    }

    #[test]
    fn fake_child_transport_proves_native_session_and_final_message() {
        let dir = std::env::temp_dir().join(format!("lico-copilot-acp-fake-{}", timestamp()));
        fs::create_dir_all(&dir).unwrap();
        let source = dir.join("fake_agent.rs");
        let executable = dir.join(format!("fake-agent{}", std::env::consts::EXE_SUFFIX));
        fs::write(&source, FAKE_AGENT_SOURCE).unwrap();
        let status = Command::new("rustc")
            .args(["--edition", "2021"])
            .arg(&source)
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap();
        assert!(status.success());
        let result = execute(
            executable.to_string_lossy().as_ref(),
            &json!({}),
            "private-stdin-prompt",
            "",
            Some(dir.as_path()),
            10_000,
            1024 * 1024,
            1024,
        );
        assert!(result.ok, "fake Copilot ACP failure: {:?}", result.error);
        assert_eq!(result.output, "copilot final");
        assert_eq!(result.session_id, "copilot-native-session");
        assert_eq!(result.turn_status, "end_turn");
        assert_eq!(result.runtime_protocol, RUNTIME_PROTOCOL);
        assert_eq!(result.driver_id, "copilot-acp");
        assert!(result.stderr_truncated);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn capability_probe_uses_the_same_canonical_acp_entrypoint() {
        let dir = std::env::temp_dir().join(format!("lico-copilot-probe-fake-{}", timestamp()));
        fs::create_dir_all(&dir).unwrap();
        let source = dir.join("fake_probe.rs");
        let executable = dir.join(format!("fake-probe{}", std::env::consts::EXE_SUFFIX));
        fs::write(&source, FAKE_PROBE_SOURCE).unwrap();
        let status = Command::new("rustc")
            .args(["--edition", "2021"])
            .arg(&source)
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap();
        assert!(status.success());
        let probe = capability_probe(
            executable.to_string_lossy().as_ref(),
            dir.as_path(),
            5_000,
            64 * 1024,
            1024,
        )
        .unwrap();
        assert_eq!(probe.protocol_version, Some(1));
        assert!(probe.load_session);
        assert!(!probe.resume_session);
        let _ = fs::remove_dir_all(dir);
    }

    fn timestamp() -> u128 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    }

    const FAKE_AGENT_SOURCE: &str = r#"
use std::io::{self, BufRead, Write};
fn id(line: &str) -> i64 {
    let marker = "\"id\":";
    let start = line.find(marker).unwrap() + marker.len();
    line[start..].chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().unwrap()
}
fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    assert_eq!(args, vec!["--acp", "--stdio", "--no-auto-update"]);
    std::thread::spawn(|| { let mut e=io::stderr(); let _=e.write_all(&vec![b'x'; 128*1024]); });
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    let first = lines.next().unwrap().unwrap();
    assert!(first.contains("\"method\":\"initialize\""));
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":true}}}}}}", id(&first));
    io::stdout().flush().unwrap();
    let second = lines.next().unwrap().unwrap();
    assert!(second.contains("\"method\":\"session/new\""));
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"sessionId\":\"copilot-native-session\",\"configOptions\":[]}}}}", id(&second));
    io::stdout().flush().unwrap();
    let third = lines.next().unwrap().unwrap();
    assert!(third.contains("private-stdin-prompt"));
    assert!(third.contains("\"method\":\"session/prompt\""));
    println!("{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"copilot-native-session\",\"update\":{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"text\",\"text\":\"copilot final\"}}}}}}}}");
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"stopReason\":\"end_turn\"}}}}", id(&third));
    io::stdout().flush().unwrap();
    std::thread::sleep(std::time::Duration::from_secs(1));
}
"#;

    const FAKE_PROBE_SOURCE: &str = r#"
use std::io::{self, BufRead, Write};
fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    assert_eq!(args, vec!["--acp", "--stdio", "--no-auto-update"]);
    let stdin = io::stdin();
    let first = stdin.lock().lines().next().unwrap().unwrap();
    assert!(first.contains("\"method\":\"initialize\""));
    println!("{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":true}}}}}}");
    io::stdout().flush().unwrap();
    std::thread::sleep(std::time::Duration::from_secs(1));
}
"#;
}
