use super::support::{
    completed_outcome, config, failed_effect, initialize, open_thread, start_turn,
};
use crate::platform::codex_app_server::protocol::CodexProtocol;
use crate::platform::turn_event_emit::{StreamSinkGuard, install_stream_sink};
use serde_json::json;
use std::sync::{Arc, Mutex};

#[test]
fn matching_completion_uses_last_agent_message_and_thread_authority() {
    let mut protocol = CodexProtocol::new(config(
        json!({"model": "explicit-model", "reasoningEffort": "high"}),
        "hello",
        "",
    ));
    initialize(&mut protocol);
    open_thread(&mut protocol);
    start_turn(&mut protocol);

    assert!(
        protocol
            .handle_message(json!({
                "method": "turn/completed",
                "params": {
                    "threadId": "another-thread",
                    "turn": {"id": "turn-1", "status": "completed", "items": []}
                }
            }))
            .is_empty()
    );

    let outcome = completed_outcome(protocol.handle_message(json!({
        "method": "turn/completed",
        "params": {
            "threadId": "thread-1",
            "turn": {
                "id": "turn-1",
                "status": "completed",
                "items": [
                    {"id": "agent-1", "type": "agentMessage", "text": "draft"},
                    {"id": "reasoning-1", "type": "reasoning", "summary": []},
                    {"id": "agent-2", "type": "agentMessage", "text": "final answer"}
                ]
            }
        }
    })));
    assert_eq!(outcome.output, "final answer");
    assert_eq!(outcome.session_id, "thread-1");
    assert_eq!(outcome.thread_id, "thread-1");
    assert_eq!(outcome.turn_id, "turn-1");
    assert_eq!(outcome.turn_status, "completed");
    assert_eq!(outcome.effective.model.as_deref(), Some("explicit-model"));
    assert_eq!(outcome.effective.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(outcome.effective.cwd.as_deref(), Some("/workspace/project"));
    assert_eq!(outcome.effective.approval_policy, Some(json!("on-request")));
}

#[test]
fn native_item_started_emits_redacted_processing_receipt() {
    let captured = Arc::new(Mutex::new(Vec::new()));
    let sink_target = Arc::clone(&captured);
    install_stream_sink(Box::new(move |event| {
        sink_target.lock().unwrap().push(event);
    }));
    let _guard = StreamSinkGuard;
    let mut protocol = CodexProtocol::new(config(json!({}), "hello", ""));
    initialize(&mut protocol);
    open_thread(&mut protocol);
    start_turn(&mut protocol);

    protocol.handle_message(json!({
        "method": "item/started",
        "params": {
            "threadId": "thread-1",
            "turnId": "turn-1",
            "item": {
                "id": "private-item-id",
                "type": "reasoning",
                "summary": [{"text": "private chain of thought"}]
            }
        }
    }));

    let events = captured.lock().unwrap().clone();
    assert!(events.iter().any(|event| {
        event["event"] == "agent.turn.processing"
            && event["payload"] == json!({"evidenceKind": "reasoning"})
    }));
    let encoded = serde_json::to_string(&events).unwrap();
    assert!(!encoded.contains("private-item-id"));
    assert!(!encoded.contains("private chain of thought"));
}

#[test]
fn failed_turn_classifies_closed_codex_error_without_leaking_details() {
    let captured = Arc::new(Mutex::new(Vec::new()));
    let sink_target = Arc::clone(&captured);
    install_stream_sink(Box::new(move |event| {
        sink_target.lock().unwrap().push(event);
    }));
    let _guard = StreamSinkGuard;
    let mut protocol = CodexProtocol::new(config(json!({}), "hello", ""));
    initialize(&mut protocol);
    open_thread(&mut protocol);
    start_turn(&mut protocol);

    let failure = failed_effect(protocol.handle_message(json!({
        "method": "turn/completed",
        "params": {
            "threadId": "thread-1",
            "turn": {
                "id": "turn-1",
                "status": "failed",
                "items": [],
                "error": {
                    "message": "turn-fixture/secret.txt is unreadable",
                    "codexErrorInfo": "Unauthorized",
                    "additionalDetails": "turn-fixture/secret.txt"
                }
            }
        }
    })));
    assert_eq!(failure.code, "codex_turn_not_completed");
    assert_eq!(failure.turn_status.as_deref(), Some("failed/Unauthorized"));
    assert_eq!(failure.message, "Codex rejected the turn as unauthorized.");
    let encoded = format!("{failure:?}");
    assert!(!encoded.contains("secret.txt"));
    assert!(!encoded.contains("turn-fixture"));
    let events = captured.lock().unwrap().clone();
    let failed = events
        .iter()
        .find(|event| event["event"] == "dispatch.turn.failed")
        .expect("failed turn emits dispatch.turn.failed");
    assert_eq!(failed["payload"]["turnStatus"], "failed/Unauthorized");
    assert_eq!(failed["payload"]["code"], "codex_turn_not_completed");
    let payload = serde_json::to_string(&failed["payload"]).unwrap();
    assert!(!payload.contains("secret.txt"));
    assert!(!payload.contains("turn-fixture"));
}

#[test]
fn interrupted_turn_is_not_completed() {
    let mut protocol = CodexProtocol::new(config(json!({}), "hello", ""));
    initialize(&mut protocol);
    open_thread(&mut protocol);
    start_turn(&mut protocol);

    let failure = failed_effect(protocol.handle_message(json!({
        "method": "turn/completed",
        "params": {
            "threadId": "thread-1",
            "turn": {"id": "turn-1", "status": "interrupted", "items": []}
        }
    })));
    assert_eq!(failure.code, "codex_turn_not_completed");
    assert_eq!(failure.turn_status.as_deref(), Some("interrupted"));
    assert_eq!(failure.message, "Codex interrupted the requested turn.");
}
