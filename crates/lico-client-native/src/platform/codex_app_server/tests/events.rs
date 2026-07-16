use super::support::{completed_outcome, config, initialize, open_thread, start_turn};
use crate::platform::codex_app_server::protocol::CodexProtocol;
use serde_json::json;

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
