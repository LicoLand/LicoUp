use super::*;

pub(super) fn absolute_test_cwd() -> PathBuf {
    std::env::current_dir().expect("test working directory")
}

pub(super) fn resume_config(
    prompt: &str,
    session_id: &str,
    session_path: PathBuf,
) -> ProtocolConfig {
    ProtocolConfig {
        prompt: prompt.to_string(),
        requested_session_id: session_id.to_string(),
        resume_session_path: Some(session_path),
        cwd: absolute_test_cwd().to_string_lossy().to_string(),
        model: None,
        model_provider: None,
        model_id: None,
        thinking_level: None,
        turn_id: "test-turn".to_string(),
    }
}

pub(super) fn temporary_directory(prefix: &str) -> PathBuf {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let path = std::env::temp_dir().join(format!("{prefix}-{nonce}"));
    fs::create_dir_all(&path).unwrap();
    path
}

pub(super) fn compile_fake_pi(prefix: &str) -> (PathBuf, PathBuf) {
    let directory = temporary_directory(prefix);
    let source = directory.join("fake_pi.rs");
    let executable = directory.join(format!("fake-pi{}", std::env::consts::EXE_SUFFIX));
    fs::write(&source, FAKE_PI_SOURCE).unwrap();
    let status = std::process::Command::new("rustc")
        .args(["--edition", "2021"])
        .arg(&source)
        .arg("-o")
        .arg(&executable)
        .status()
        .unwrap();
    assert!(status.success());
    (directory, executable)
}

pub(super) const FAKE_PI_SOURCE: &str = r#"
use std::io::{self, BufRead, Write};

fn request_id(line: &str) -> &str {
    let marker = "\"id\":\"";
    let start = line.find(marker).unwrap() + marker.len();
    let tail = &line[start..];
    &tail[..tail.find('\"').unwrap()]
}

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    assert_eq!(args, vec!["--mode", "rpc", "--offline"]);
    assert!(!args.iter().any(|arg| arg.contains("private") || arg.contains("session")));
    std::thread::spawn(|| {
        let mut stderr = io::stderr();
        let _ = stderr.write_all(&vec![b'x'; 128 * 1024]);
    });

    let mut state_requests = 0usize;
    let mut stream = false;
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        let id = request_id(&line);
        if line.contains("\"type\":\"get_state\"") {
            state_requests += 1;
            println!("{{\"id\":\"{}\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{{\"sessionId\":\"pi-native-1\"}}}}", id);
            io::stdout().flush().unwrap();
            if state_requests > 1 {
                std::thread::sleep(std::time::Duration::from_secs(5));
            }
        } else if line.contains("\"type\":\"prompt\"") {
            if line.contains("timeout-case") {
                std::thread::sleep(std::time::Duration::from_secs(5));
                continue;
            }
            stream = line.contains("\"message\":\"stream\"");
            println!("{{\"id\":\"{}\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}}", id);
            if stream {
                println!("{{\"type\":\"message_update\",\"assistantMessageEvent\":{{\"type\":\"text_delta\",\"delta\":\"one\"}}}}");
                println!("{{\"type\":\"message_update\",\"assistantMessageEvent\":{{\"type\":\"text_delta\",\"delta\":\"-two\"}}}}");
            } else {
                println!("{{\"type\":\"message_update\",\"assistantMessageEvent\":{{\"type\":\"text_delta\",\"delta\":\"pi-ok\"}}}}");
            }
            println!("{{\"type\":\"agent_settled\"}}");
            io::stdout().flush().unwrap();
        } else if line.contains("\"type\":\"get_last_assistant_text\"") {
            let text = if stream { "one-two" } else { "pi-ok" };
            println!("{{\"id\":\"{}\",\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{{\"text\":\"{}\"}}}}", id, text);
            io::stdout().flush().unwrap();
        }
    }
}
"#;
