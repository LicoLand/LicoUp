use super::support::{config, initialize, open_thread, sent_messages};
use crate::platform::codex_app_server::config::ProtocolConfig;
use crate::platform::codex_app_server::protocol::CodexProtocol;
use crate::platform::turn_event_emit::{StreamSinkGuard, install_stream_sink};
use serde_json::{Map, Value, json};
use std::path::Path;
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

#[test]
fn turn_start_emits_ordered_text_then_local_image_inputs() {
    let prompt = "describe the attachments";
    let mut protocol = CodexProtocol::new(config(
        json!({
            "attachments": [
                {
                    "id": "sel-1",
                    "name": "first.png",
                    "mediaType": "image/png",
                    "path": "attachment-fixtures/first.png"
                },
                {
                    "id": "sel-2",
                    "name": "second.jpg",
                    "mediaType": "image/jpeg",
                    "path": "attachment-fixtures/second.jpg"
                }
            ]
        }),
        prompt,
        "",
    ));

    let thread_messages = sent_messages(initialize(&mut protocol));
    assert_eq!(thread_messages[0], json!({"method": "initialized"}));
    assert_eq!(thread_messages[1]["method"], "thread/start");

    let turn_messages = sent_messages(open_thread(&mut protocol));
    assert_eq!(turn_messages.len(), 1);
    assert_eq!(turn_messages[0]["method"], "turn/start");
    let input = turn_messages[0]["params"]["input"].as_array().unwrap();
    assert_eq!(input.len(), 3);
    assert_eq!(input[0], json!({"type": "text", "text": prompt}));
    assert_eq!(
        input[1],
        json!({
            "type": "localImage",
            "path": "attachment-fixtures/first.png",
            "mediaType": "image/png",
            "name": "first.png"
        })
    );
    assert_eq!(
        input[2],
        json!({
            "type": "localImage",
            "path": "attachment-fixtures/second.jpg",
            "mediaType": "image/jpeg",
            "name": "second.jpg"
        })
    );
}

#[test]
fn attachment_only_turn_start_contains_no_text_item() {
    let mut protocol = CodexProtocol::new(config(
        json!({
            "attachments": [
                {
                    "id": "sel-1",
                    "name": "first.png",
                    "mediaType": "image/png",
                    "path": "attachment-fixtures/first.png"
                }
            ]
        }),
        "",
        "",
    ));

    initialize(&mut protocol);
    let turn_messages = sent_messages(open_thread(&mut protocol));
    let input = turn_messages[0]["params"]["input"].as_array().unwrap();
    assert_eq!(input.len(), 1);
    assert_eq!(
        input[0],
        json!({
            "type": "localImage",
            "path": "attachment-fixtures/first.png",
            "mediaType": "image/png",
            "name": "first.png"
        })
    );
}

#[test]
fn invalid_attachment_config_fails_closed_without_paths() {
    for params in [
        json!({"attachments": "not-an-array"}),
        json!({"attachments": [{"id": "1", "name": "a.png", "mediaType": "image/png"}]}),
        json!({
            "attachments": [{
                "id": "1",
                "name": "a.png",
                "mediaType": "image/png",
                "path": "attachment-fixtures/a.png",
                "extra": true
            }]
        }),
        json!({
            "attachments": [{
                "id": "1",
                "name": "a.heic",
                "mediaType": "image/heic",
                "path": "attachment-fixtures/a.heic"
            }]
        }),
        json!({
            "attachments": [
                {"id": "1", "name": "a.png", "mediaType": "image/png", "path": "attachment-fixtures/a.png"},
                {"id": "2", "name": "b.png", "mediaType": "image/png", "path": "attachment-fixtures/b.png"},
                {"id": "3", "name": "c.png", "mediaType": "image/png", "path": "attachment-fixtures/c.png"},
                {"id": "4", "name": "d.png", "mediaType": "image/png", "path": "attachment-fixtures/d.png"},
                {"id": "5", "name": "e.png", "mediaType": "image/png", "path": "attachment-fixtures/e.png"}
            ]
        }),
    ] {
        let failure = ProtocolConfig::from_params(
            &params,
            "hello",
            "",
            Some(Path::new("/workspace/project")),
        )
        .expect_err("invalid attachment config must fail closed");
        assert_eq!(failure.code, "codex_invalid_local_image");
        assert!(!failure.message.contains("attachment-fixtures"));
    }
}
