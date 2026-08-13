use super::support::{completed_outcome, config, initialize, open_thread, start_turn};
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
