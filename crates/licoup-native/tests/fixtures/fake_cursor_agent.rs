use std::env;
use std::io::{self, Write};

fn emit(value: &str) {
    println!("{value}");
    io::stdout().flush().unwrap();
}

fn help_text() {
    println!("Cursor Agent CLI");
    println!("  create-chat");
    println!("  --print");
    println!("  --resume");
    println!("  --output-format stream-json");
    println!("  --trust");
    println!("  --force");
    println!("  --workspace");
}

fn create_session_id(counter: u64) -> String {
    format!("fake-cursor-session-{counter:012x}")
}

fn turn_output(prompt: &str) -> (&'static str, &'static str) {
    if prompt.contains("private first prompt") {
        ("first response", "first response")
    } else if prompt.contains("private follow-up prompt") {
        ("second response", "second response")
    } else if prompt.contains("41") {
        ("41", "41")
    } else if prompt.contains("43") {
        ("43", "43")
    } else {
        ("fake Cursor final answer", "fake Cursor final answer")
    }
}

fn run_turn(args: &[String]) {
    let resume_index = args.iter().position(|arg| arg == "--resume").expect("--resume");
    let session_id = args
        .get(resume_index + 1)
        .filter(|value| !value.is_empty())
        .expect("session id");
    let prompt = args.last().expect("prompt");
    let (chunk, response) = turn_output(prompt);
    emit(&format!(
        r#"{{"type":"assistant","session_id":"{session_id}","message":{{"content":[{{"type":"text","text":"{chunk}"}}]}}}}"#
    ));
    emit(&format!(
        r#"{{"type":"result","subtype":"success","is_error":false,"session_id":"{session_id}","result":"{response}"}}"#
    ));
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args == ["--version"] {
        println!("fake-cursor-agent 1.0.0");
        return;
    }
    if args == ["--help"] {
        help_text();
        return;
    }
    if args == ["create-chat"] {
        let session_id = create_session_id(1);
        println!("{session_id}");
        return;
    }
    if args.first().map(String::as_str) == Some("acp") {
        eprintln!("ACP entrypoint is not supported");
        std::process::exit(2);
    }
    if args.iter().any(|arg| arg == "--print")
        && args.iter().any(|arg| arg == "--resume")
        && args.iter().any(|arg| arg == "stream-json")
    {
        run_turn(&args);
        return;
    }
    std::process::exit(2);
}
