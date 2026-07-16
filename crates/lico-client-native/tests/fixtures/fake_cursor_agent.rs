use std::io::{self, BufRead, Write};

/// Deterministic ACP v1 fake for Cursor's public `agent acp` / `cursor-agent acp`
/// entrypoint. Launch args stay fixed; session identity and prompts travel only
/// on the stdio JSON-RPC channel.
fn id(line: &str) -> i64 {
    let marker = "\"id\":";
    let start = line.find(marker).expect("jsonrpc id") + marker.len();
    line[start..]
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .expect("numeric id")
}

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args == ["--version"] {
        println!("fake-cursor-agent 1.0.0");
        return;
    }
    if args == ["--help"] {
        println!("fake Cursor Agent ACP help");
        return;
    }
    if args != ["acp"] {
        std::process::exit(2);
    }

    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    let first = match lines.next() {
        Some(Ok(line)) => line,
        _ => std::process::exit(3),
    };
    if !first.contains("\"method\":\"initialize\"") {
        std::process::exit(4);
    }
    println!(
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":true}}}}}}",
        id(&first)
    );
    io::stdout().flush().unwrap();

    let second = match lines.next() {
        Some(Ok(line)) => line,
        _ => std::process::exit(5),
    };
    let (method, session_id) = if second.contains("\"method\":\"session/new\"") {
        ("session/new", "fake-cursor-session")
    } else if second.contains("\"method\":\"session/load\"") {
        if !second.contains("fake-cursor-session") && !second.contains("existing-cursor-native") {
            std::process::exit(6);
        }
        ("session/load", "fake-cursor-session")
    } else {
        std::process::exit(7);
    };
    if method == "session/load" {
        println!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":null}}",
            id(&second)
        );
    } else {
        println!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"sessionId\":\"{session_id}\",\"configOptions\":[]}}}}",
            id(&second)
        );
    }
    io::stdout().flush().unwrap();

    let third = match lines.next() {
        Some(Ok(line)) => line,
        _ => std::process::exit(8),
    };
    if !third.contains("\"method\":\"session/prompt\"") {
        std::process::exit(9);
    }
    println!(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"{session_id}\",\"update\":{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"text\",\"text\":\"fake Cursor final answer\"}}}}}}}}"
    );
    println!(
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{{\"stopReason\":\"end_turn\"}}}}",
        id(&third)
    );
    io::stdout().flush().unwrap();
}
