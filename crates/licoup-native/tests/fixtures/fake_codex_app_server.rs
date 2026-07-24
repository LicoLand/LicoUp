use std::fs;
use std::io::{self, BufRead, Write};

const EXPECTED_PROMPT: &str = "fake-child-private-prompt";
const STEER_PROMPT: &str = "fake-codex-steer-prompt";
const STEER_GUIDANCE: &str = "fake-codex-steer-guidance";

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args != ["app-server", "--stdio"] {
        std::process::exit(2);
    }
    let configured_output = std::env::current_exe().ok().and_then(|mut path| {
        path.set_extension("result.json");
        fs::read_to_string(path).ok()
    });
    let steering_mode = std::env::current_exe()
        .map(|mut path| {
            path.set_extension("steer-mode");
            path.is_file()
        })
        .unwrap_or(false);

    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    let mut awaiting_steer = false;
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
            let thread_id = if steering_mode {
                "fake-steer-thread"
            } else {
                "fake-thread"
            };
            send(
                &mut stdout,
                &format!(
                    r#"{{"id":2,"result":{{"approvalPolicy":"never","approvalsReviewer":"user","cwd":"/workspace/project","model":"fake-default","modelProvider":"openai","reasoningEffort":"medium","sandbox":{{"type":"workspaceWrite","writableRoots":[]}},"thread":{{"id":"{thread_id}","sessionId":"fake-session","cwd":"/workspace/project"}}}}}}"#
                ),
            );
        } else if line.contains("\"method\":\"turn/start\"") {
            if configured_output.is_none()
                && !line.contains(EXPECTED_PROMPT)
                && !line.contains(STEER_PROMPT)
            {
                std::process::exit(4);
            }
            io::stderr()
                .lock()
                .write_all(&vec![b'x'; 128 * 1024])
                .unwrap();
            let turn_id = if steering_mode {
                "fake-steer-turn"
            } else {
                "fake-turn"
            };
            send(
                &mut stdout,
                &format!(
                    r#"{{"id":3,"result":{{"turn":{{"id":"{turn_id}","items":[],"status":"inProgress"}}}}}}"#
                ),
            );
            if line.contains(STEER_PROMPT) {
                awaiting_steer = true;
                continue;
            }
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
        } else if line.contains("\"method\":\"turn/steer\"") {
            if !awaiting_steer
                || !line.contains(STEER_GUIDANCE)
                || !line.contains("\"threadId\":\"fake-steer-thread\"")
                || !line.contains("\"expectedTurnId\":\"fake-steer-turn\"")
            {
                std::process::exit(5);
            }
            let Some(request_id) = json_string_field(&line, "id") else {
                std::process::exit(6);
            };
            send(
                &mut stdout,
                &format!(r#"{{"id":{},"result":{{}}}}"#, json_string(&request_id)),
            );
            send(
                &mut stdout,
                r#"{"method":"turn/completed","params":{"threadId":"fake-steer-thread","turn":{"id":"fake-steer-turn","items":[{"id":"fake-agent-message","type":"agentMessage","text":"fake child guided answer"}],"status":"completed"}}}"#,
            );
            awaiting_steer = false;
        }
    }
}

fn json_string_field(value: &str, field: &str) -> Option<String> {
    let marker = format!("\"{field}\":\"");
    let tail = value.split_once(&marker)?.1;
    Some(tail.split_once('"')?.0.to_string())
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
