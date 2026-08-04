use std::io::{self, BufRead, Write};
use std::process::{Command, Stdio};
use std::time::Duration;

#[cfg(unix)]
use std::os::unix::process::CommandExt;

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args == ["--pipe-holder"] {
        std::fs::write("fake-claude-descendant.pid", std::process::id().to_string()).unwrap();
        std::fs::write("fake-claude-descendant.pipe-open", "open").unwrap();
        if std::path::Path::new("fake-claude-io-join.enabled").exists() {
            wait_for_file("fake-claude-io-join.release");
            std::fs::write("fake-claude-descendant.pipe-closed", "closed").unwrap();
        } else {
            std::thread::sleep(Duration::from_secs(30));
        }
        return;
    }
    if args == ["--version"] {
        println!("fake-claude 1.0.0");
        return;
    }
    if args == ["--help"] {
        println!("fake Claude Code help");
        return;
    }
    let expected = [
        "--print",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--model",
        "fake-model",
        "--effort",
        "high",
        "--permission-mode",
        "plan",
    ];
    if args != expected
        || args.iter().any(|argument| {
            argument.contains("fake-claude-private-prompt")
                || argument.contains("fake-claude-session")
        })
    {
        std::process::exit(2);
    }

    let working_directory_name = std::env::current_dir()
        .ok()
        .and_then(|path| {
            path.file_name()
                .map(|value| value.to_string_lossy().into_owned())
        })
        .unwrap_or_default();
    let session_id = if working_directory_name.contains("transport-a") {
        "fake-claude-session-a".to_string()
    } else if working_directory_name.contains("transport-b") {
        "fake-claude-session-b".to_string()
    } else if let Some(index) = working_directory_name.strip_prefix("capacity-") {
        format!("fake-claude-capacity-{index}")
    } else {
        "fake-claude-session".to_string()
    };

    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    if std::path::Path::new("fake-claude-io-join.enabled").exists() {
        std::fs::write("fake-claude-root.pid", std::process::id().to_string()).unwrap();
    }
    let mut turns = 0usize;
    let mut retained_descendant = None;
    let mut lines = stdin.lock().lines();
    while let Some(line) = lines.next() {
        let line = line.unwrap();
        if line.contains(r#""type":"control_request""#) {
            continue;
        }
        turns += 1;
        let is_cancel_turn = line.contains("fake-claude-cancel-prompt");
        let is_auth_turn = line.contains("fake-claude-auth-prompt");
        let is_steer_turn = line.contains("fake-claude-steer-prompt");
        if line.contains("fake-claude-retained-pipe") {
            let mut descendant = Command::new(std::env::current_exe().unwrap());
            descendant
                .arg("--pipe-holder")
                .stdin(Stdio::null())
                .stdout(Stdio::inherit())
                .stderr(Stdio::inherit());
            #[cfg(unix)]
            if line.contains("fake-claude-orphaned-pipe") {
                descendant.process_group(0);
            }
            let child = descendant.spawn().unwrap();
            std::fs::write("fake-claude-descendant.pid", child.id().to_string()).unwrap();
            retained_descendant = Some(child);
        }
        if !is_cancel_turn
            && !is_auth_turn
            && !is_steer_turn
            && !line.contains(&format!("fake-claude-private-prompt-{turns}"))
            || line.contains("fake-claude-session")
        {
            std::process::exit(3);
        }
        if turns == 1 {
            send(
                &mut stdout,
                &format!(
                    r#"{{"type":"system","subtype":"init","session_id":"{session_id}","model":"fake-model","permissionMode":"plan"}}"#
                ),
            );
        }
        if is_cancel_turn {
            let control = lines.next().and_then(Result::ok).unwrap_or_default();
            if !control.contains(r#""type":"control_request""#)
                || !control.contains(r#""subtype":"interrupt""#)
                || control.contains("fake-claude-session")
            {
                std::process::exit(4);
            }
            send(
                &mut stdout,
                r#"{"type":"control_response","response":{"subtype":"success","request_id":"redacted"}}"#,
            );
            send(
                &mut stdout,
                &format!(
                    r#"{{"type":"result","subtype":"error_during_execution","is_error":true,"result":"interrupted","session_id":"{session_id}","permission_denials":[]}}"#
                ),
            );
            continue;
        }
        if is_auth_turn {
            send(
                &mut stdout,
                &format!(
                    r#"{{"type":"result","subtype":"authentication_required","is_error":true,"result":"synthetic private authentication detail","session_id":"{session_id}","permission_denials":[]}}"#
                ),
            );
            continue;
        }
        if is_steer_turn {
            send(
                &mut stdout,
                &format!(
                    r#"{{"type":"stream_event","session_id":"{session_id}","event":{{"type":"content_block_delta","delta":{{"type":"text_delta","text":"awaiting guidance"}}}}}}"#
                ),
            );
            let guidance = lines.next().and_then(Result::ok).unwrap_or_default();
            if !guidance.contains(r#""type":"user""#)
                || !guidance.contains("fake-claude-steer-guidance")
                || guidance.contains("fake-claude-session")
            {
                std::process::exit(5);
            }
            send(
                &mut stdout,
                &format!(
                    r#"{{"type":"result","subtype":"success","is_error":false,"result":"fake Claude guided answer","session_id":"{session_id}","uuid":"turn-{turns}","permission_denials":[]}}"#
                ),
            );
            continue;
        }
        let output = if line.contains("fake-claude-utf8-output") {
            "多字节🙂".to_string()
        } else {
            format!("fake Claude final answer {turns}")
        };
        send(
            &mut stdout,
            &format!(
                r#"{{"type":"stream_event","session_id":"{session_id}","event":{{"type":"content_block_delta","delta":{{"type":"text_delta","text":"{output}"}}}}}}"#
            ),
        );
        send(
            &mut stdout,
            &format!(
                r#"{{"type":"assistant","session_id":"{session_id}","message":{{"role":"assistant","content":[{{"type":"text","text":"draft {turns}"}}]}}}}"#
            ),
        );
        send(
            &mut stdout,
            &format!(
                r#"{{"type":"result","subtype":"success","is_error":false,"result":"{output}","session_id":"{session_id}","uuid":"turn-{turns}","permission_denials":[]}}"#
            ),
        );
    }
    if std::path::Path::new("fake-claude-io-join.enabled").exists() {
        std::fs::write("fake-claude-io-worker.waiting", "waiting").unwrap();
        wait_for_file("fake-claude-io-join.release");
        std::fs::write("fake-claude-io-source.closed", "closed").unwrap();
        if let Some(mut child) = retained_descendant.take() {
            let _ = child.wait();
        }
        std::fs::write("fake-claude-child.closed", "closed").unwrap();
    }
}

fn send(stdout: &mut impl Write, message: &str) {
    stdout.write_all(message.as_bytes()).unwrap();
    stdout.write_all(b"\n").unwrap();
    stdout.flush().unwrap();
}

fn wait_for_file(name: &str) {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !std::path::Path::new(name).exists() {
        if std::time::Instant::now() >= deadline {
            std::process::exit(7);
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}
