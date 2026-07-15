use std::fs;
use std::io::{self, BufRead, Write};

const EXPECTED_PROMPT: &str = "fake-child-private-prompt";

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args != ["app-server", "--stdio"] {
        std::process::exit(2);
    }
    let configured_output = std::env::current_exe().ok().and_then(|mut path| {
        path.set_extension("result.json");
        fs::read_to_string(path).ok()
    });

    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else {
            std::process::exit(3);
        };
        if line.contains("\"method\":\"initialize\"") {
            send(
                &mut stdout,
                r#"{"id":1,"result":{"codexHome":"/redacted","platformFamily":"test","platformOs":"test","userAgent":"fake-codex"}}"#,
            );
        } else if line.contains("\"method\":\"thread/start\"") {
            send(
                &mut stdout,
                r#"{"id":2,"result":{"approvalPolicy":"never","approvalsReviewer":"user","cwd":"/workspace/project","model":"fake-default","modelProvider":"openai","reasoningEffort":"medium","sandbox":{"type":"workspaceWrite","writableRoots":[]},"thread":{"id":"fake-thread","sessionId":"fake-session","cwd":"/workspace/project"}}}"#,
            );
        } else if line.contains("\"method\":\"turn/start\"") {
            if configured_output.is_none() && !line.contains(EXPECTED_PROMPT) {
                std::process::exit(4);
            }
            io::stderr()
                .lock()
                .write_all(&vec![b'x'; 128 * 1024])
                .unwrap();
            send(
                &mut stdout,
                r#"{"id":3,"result":{"turn":{"id":"fake-turn","items":[],"status":"inProgress"}}}"#,
            );
            let final_answer = configured_output
                .as_deref()
                .unwrap_or("fake child final answer");
            send(
                &mut stdout,
                &format!(
                    r#"{{"method":"turn/completed","params":{{"threadId":"fake-thread","turn":{{"id":"fake-turn","items":[{{"id":"fake-agent-message","type":"agentMessage","text":{}}}],"status":"completed"}}}}}}"#,
                    json_string(final_answer)
                ),
            );
        }
    }
}

fn send(stdout: &mut impl Write, message: &str) {
    stdout.write_all(message.as_bytes()).unwrap();
    stdout.write_all(b"\n").unwrap();
    stdout.flush().unwrap();
}

fn json_string(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len() + 2);
    encoded.push('"');
    for character in value.chars() {
        match character {
            '"' => encoded.push_str("\\\""),
            '\\' => encoded.push_str("\\\\"),
            '\n' => encoded.push_str("\\n"),
            '\r' => encoded.push_str("\\r"),
            '\t' => encoded.push_str("\\t"),
            character if character.is_control() => {
                use std::fmt::Write as _;
                write!(&mut encoded, "\\u{:04x}", character as u32).unwrap();
            }
            character => encoded.push(character),
        }
    }
    encoded.push('"');
    encoded
}
