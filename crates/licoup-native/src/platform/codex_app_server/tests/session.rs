use super::support::{config, initialize, open_thread, sent_messages};
use crate::platform::codex_app_server::protocol::CodexProtocol;
use crate::platform::turn_event_emit::{StreamSinkGuard, install_stream_sink};
use serde_json::{Map, Value, json};
use std::sync::{Arc, Mutex};

#[test]
fn new_thread_sends_prompt_only_in_turn_start_stdio_message() {
    let prompt = "private prompt that must not enter argv";
    let mut protocol = CodexProtocol::new(config(
        json!({"model": "explicit-model", "reasoningEffort": "high"}),
        prompt,
        "",
    ));

    let initialize_request = protocol.initial_request();
    assert_eq!(initialize_request["method"], "initialize");
    assert!(!initialize_request.to_string().contains(prompt));

    let thread_messages = sent_messages(initialize(&mut protocol));
    assert_eq!(thread_messages[0], json!({"method": "initialized"}));
    assert_eq!(thread_messages[1]["method"], "thread/start");
    assert!(!thread_messages[1].to_string().contains(prompt));
    assert!(thread_messages[1]["params"].get("sandbox").is_none());

    let turn_messages = sent_messages(open_thread(&mut protocol));
    assert_eq!(turn_messages.len(), 1);
    assert_eq!(turn_messages[0]["method"], "turn/start");
    assert_eq!(turn_messages[0]["params"]["threadId"], "thread-1");
    assert_eq!(turn_messages[0]["params"]["input"][0]["type"], "text");
    assert_eq!(turn_messages[0]["params"]["input"][0]["text"], prompt);
    assert_eq!(turn_messages[0]["params"]["model"], "explicit-model");
    assert_eq!(turn_messages[0]["params"]["effort"], "high");
}

#[test]
fn resume_accepts_session_path_aliases_and_extracts_thread_id() {
    for key in ["sessionPath", "sourcePath"] {
        let mut params = Map::new();
        params.insert(
            key.to_string(),
            json!("/sessions/rollout-2026-01-01-01234567-89ab-cdef-0123-456789abcdef.jsonl"),
        );
        let mut protocol = CodexProtocol::new(config(Value::Object(params), "hello", ""));
        let thread_messages = sent_messages(initialize(&mut protocol));
        let resume = &thread_messages[1];
        assert_eq!(resume["method"], "thread/resume");
        assert_eq!(
            resume["params"]["threadId"],
            "01234567-89ab-cdef-0123-456789abcdef"
        );
        assert!(resume["params"]["path"].as_str().is_some());
    }
}

#[test]
fn turn_start_ack_emits_accepted_lifecycle_receipt() {
    let captured = Arc::new(Mutex::new(Vec::new()));
    let sink_target = Arc::clone(&captured);
    install_stream_sink(Box::new(move |event| {
        sink_target.lock().unwrap().push(event);
    }));
    let _guard = StreamSinkGuard;
    let mut protocol = CodexProtocol::new(config(json!({}), "hello", ""));
    initialize(&mut protocol);
    open_thread(&mut protocol);
    super::support::start_turn(&mut protocol);

    let events = captured.lock().unwrap().clone();
    assert!(events.iter().any(|event| {
        event["event"] == "agent.turn.accepted"
            && event["sessionId"] == "thread-1"
            && event["turnId"] == "turn-1"
    }));
}
