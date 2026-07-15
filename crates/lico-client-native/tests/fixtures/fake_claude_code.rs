use std::io::{self, BufRead, Write};

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
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
        "--include-partial-messages",
        "--no-session-persistence",
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

    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    let mut turns = 0usize;
    let mut lines = stdin.lock().lines();
    while let Some(line) = lines.next() {
        let line = line.unwrap();
        if line.contains(r#""type":"control_request""#) {
            continue;
        }
        turns += 1;
        let is_cancel_turn = line.contains("fake-claude-cancel-prompt");
        if !is_cancel_turn && !line.contains(&format!("fake-claude-private-prompt-{turns}"))
            || line.contains("fake-claude-session")
        {
            std::process::exit(3);
        }
        if turns == 1 {
            send(
                &mut stdout,
                r#"{"type":"system","subtype":"init","session_id":"fake-claude-session","model":"fake-model","permissionMode":"plan"}"#,
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
                r#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"interrupted","session_id":"fake-claude-session","permission_denials":[]}"#,
            );
            continue;
        }
        send(
            &mut stdout,
            &format!(
                r#"{{"type":"stream_event","session_id":"fake-claude-session","event":{{"type":"content_block_delta","delta":{{"type":"text_delta","text":"chunk {turns}"}}}}}}"#
            ),
        );
        send(
            &mut stdout,
            &format!(
                r#"{{"type":"assistant","session_id":"fake-claude-session","message":{{"role":"assistant","content":[{{"type":"text","text":"draft {turns}"}}]}}}}"#
            ),
        );
        send(
            &mut stdout,
            &format!(
                r#"{{"type":"result","subtype":"success","is_error":false,"result":"fake Claude final answer {turns}","session_id":"fake-claude-session","uuid":"turn-{turns}","permission_denials":[]}}"#
            ),
        );
    }
}

fn send(stdout: &mut impl Write, message: &str) {
    stdout.write_all(message.as_bytes()).unwrap();
    stdout.write_all(b"\n").unwrap();
    stdout.flush().unwrap();
}
