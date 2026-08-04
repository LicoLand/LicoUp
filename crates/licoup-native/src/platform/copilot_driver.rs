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

pub(in crate::platform) fn cancel(
    session_id: &str,
) -> super::acp_driver_runtime::ControlDisposition {
    super::acp_driver_runtime::cancel_active_turn(COPILOT_DRIVER.agent_id, session_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::process::Command;
    use std::sync::mpsc;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
    fn pre_binding_session_updates_from_real_copilot_do_not_kill_the_turn() {
        let dir = std::env::temp_dir().join(format!("lico-copilot-prebind-fake-{}", timestamp()));
        fs::create_dir_all(&dir).unwrap();
        let source = dir.join("fake_prebind_agent.rs");
        let executable = dir.join(format!(
            "fake-prebind-agent{}",
            std::env::consts::EXE_SUFFIX
        ));
        fs::write(&source, FAKE_PREBIND_AGENT_SOURCE).unwrap();
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
        assert!(result.ok, "pre-bind Copilot failure: {:?}", result.error);
        assert_eq!(result.output, "copilot prebind final");
        assert_eq!(result.session_id, "copilot-prebind-session");
        assert_eq!(result.turn_status, "end_turn");
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

    #[test]
    fn active_acp_turn_accepts_cancel_before_exact_session_resume() {
        let dir = std::env::temp_dir().join(format!("lico-copilot-cancel-fake-{}", timestamp()));
        fs::create_dir_all(&dir).unwrap();
        let source = dir.join("fake_cancel_agent.rs");
        let executable = dir.join(format!("fake-cancel-agent{}", std::env::consts::EXE_SUFFIX));
        fs::write(&source, FAKE_CANCEL_AGENT_SOURCE).unwrap();
        let status = Command::new("rustc")
            .args(["--edition", "2021"])
            .arg(&source)
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap();
        assert!(status.success());

        let (bound_sender, bound_receiver) = mpsc::sync_channel(1);
        let run_dir = dir.clone();
        let run_executable = executable.clone();
        let run = std::thread::spawn(move || {
            crate::platform::turn_event_emit::install_stream_sink(Box::new(move |event| {
                if event.get("event").and_then(Value::as_str) == Some("dispatch.turn.bound") {
                    let _ = bound_sender.try_send(());
                }
            }));
            let _sink = crate::platform::turn_event_emit::StreamSinkGuard;
            execute(
                run_executable.to_string_lossy().as_ref(),
                &json!({}),
                "cancel-me",
                "",
                Some(run_dir.as_path()),
                10_000,
                1024 * 1024,
                1024,
            )
        });
        bound_receiver.recv_timeout(Duration::from_secs(3)).unwrap();
        assert_eq!(
            cancel("copilot-cancel-session"),
            super::super::acp_driver_runtime::ControlDisposition::Accepted
        );
        let result = run.join().unwrap();
        assert!(!result.ok);
        assert_eq!(result.session_id, "copilot-cancel-session");
        assert_eq!(result.turn_status, "cancelled");
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

    const FAKE_PREBIND_AGENT_SOURCE: &str = r#"
use std::io::{self, BufRead, Write};
fn id(line: &str) -> i64 {
    let marker = "\"id\":";
    let start = line.find(marker).unwrap() + marker.len();
    line[start..].chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().unwrap()
}
fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    assert_eq!(args, vec!["--acp", "--stdio", "--no-auto-update"]);
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    let first = lines.next().unwrap().unwrap();
    assert!(first.contains("\"method\":\"initialize\""));
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":true}},\"agentInfo\":{{\"name\":\"Copilot\",\"version\":\"1.0.46\"}},\"authMethods\":[]}}}}", id(&first));
    io::stdout().flush().unwrap();
    let second = lines.next().unwrap().unwrap();
    assert!(second.contains("\"method\":\"session/new\""));
    // Real Copilot 1.0.46 announces session updates for the conversation that
    // is still being created, before the session/new response arrives.
    for _ in 0..2 {
        println!("{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"copilot-prebind-session\",\"update\":{{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":[{{\"name\":\"compact\",\"description\":\"Summarize conversation history\"}}]}}}}}}");
    }
    io::stdout().flush().unwrap();
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"sessionId\":\"copilot-prebind-session\",\"models\":{{\"availableModels\":[],\"currentModelId\":\"gpt-5-mini\"}},\"modes\":{{\"availableModes\":[],\"currentModeId\":\"agent\"}},\"configOptions\":[]}}}}", id(&second));
    io::stdout().flush().unwrap();
    let third = lines.next().unwrap().unwrap();
    assert!(third.contains("private-stdin-prompt"));
    assert!(third.contains("\"method\":\"session/prompt\""));
    println!("{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"copilot-prebind-session\",\"update\":{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"text\",\"text\":\"copilot prebind final\"}}}}}}}}");
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

    const FAKE_CANCEL_AGENT_SOURCE: &str = r#"
use std::io::{self, BufRead, Write};
fn id(line: &str) -> i64 {
    let marker = "\"id\":";
    let start = line.find(marker).unwrap() + marker.len();
    line[start..].chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().unwrap()
}
fn main() {
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    let initialize = lines.next().unwrap().unwrap();
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":true}}}}}}", id(&initialize));
    io::stdout().flush().unwrap();
    let session = lines.next().unwrap().unwrap();
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"sessionId\":\"copilot-cancel-session\",\"configOptions\":[]}}}}", id(&session));
    io::stdout().flush().unwrap();
    let prompt = lines.next().unwrap().unwrap();
    assert!(prompt.contains("\"method\":\"session/prompt\""));
    let cancel = lines.next().unwrap().unwrap();
    assert!(cancel.contains("\"method\":\"session/cancel\""));
    assert!(cancel.contains("copilot-cancel-session"));
    println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"stopReason\":\"cancelled\"}}}}", id(&prompt));
    io::stdout().flush().unwrap();
    std::thread::sleep(std::time::Duration::from_secs(1));
}
"#;
}
