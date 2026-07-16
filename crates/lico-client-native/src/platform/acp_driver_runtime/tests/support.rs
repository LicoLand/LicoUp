use super::*;

pub(super) fn absolute_test_cwd() -> PathBuf {
    std::env::current_dir().expect("test working directory")
}

pub(super) fn initialize_response(load: bool, resume: bool) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": INITIALIZE_REQUEST_ID,
        "result": {
            "protocolVersion": acp::PROTOCOL_VERSION,
            "agentCapabilities": {
                "loadSession": load,
                "sessionCapabilities": if resume { json!({"resume": {}}) } else { json!({}) },
                "promptCapabilities": {"image": true}
            }
        }
    })
}

pub(super) fn new_protocol(params: Value, prompt: &str, session: &str) -> AcpProtocol {
    AcpProtocol::new(
        ProtocolConfig::from_params(
            &params,
            prompt,
            session,
            Some(absolute_test_cwd().as_path()),
        )
        .unwrap(),
    )
}

pub(super) const FAKE_AGENT_SOURCE: &str = r#"
use std::io::{self, BufRead, Write};
fn id(line: &str) -> i64 {
let marker = "\"id\":";
let start = line.find(marker).unwrap() + marker.len();
line[start..].chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().unwrap()
}
fn main() {
let args = std::env::args().skip(1).collect::<Vec<_>>();
assert_eq!(args, vec!["acp"]);
std::thread::spawn(|| { let mut e=io::stderr(); let _=e.write_all(&vec![b'x'; 128*1024]); });
let stdin = io::stdin();
let mut lines = stdin.lock().lines();
let first = lines.next().unwrap().unwrap();
assert!(first.contains("\"method\":\"initialize\""));
println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":true}}}}}}", id(&first));
io::stdout().flush().unwrap();
let second = lines.next().unwrap().unwrap();
assert!(second.contains("\"method\":\"session/new\""));
println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"sessionId\":\"native-fake-session\",\"configOptions\":[]}}}}", id(&second));
io::stdout().flush().unwrap();
let third = lines.next().unwrap().unwrap();
assert!(third.contains("private-stdin-prompt"));
assert!(third.contains("\"method\":\"session/prompt\""));
println!("{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"native-fake-session\",\"update\":{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"text\",\"text\":\"fake final\"}}}}}}}}");
println!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"stopReason\":\"end_turn\"}}}}", id(&third));
io::stdout().flush().unwrap();
std::thread::sleep(std::time::Duration::from_secs(1));
}
"#;
