use super::support::{config, initialize, open_thread, start_turn};
use crate::platform::codex_app_server::model::ProtocolEffect;
use crate::platform::native_agent_parser::adapters::codex::CodexParser;
use serde_json::json;

#[test]
fn server_request_is_declined_and_stops_autonomous_dispatch() {
    let mut protocol = CodexParser::new(config(json!({}), "hello", ""));
    initialize(&mut protocol);
    open_thread(&mut protocol);
    start_turn(&mut protocol);

    let effects = protocol.handle_message(json!({
        "id": "approval-1",
        "method": "item/commandExecution/requestApproval",
        "params": {
            "threadId": "thread-1",
            "turnId": "turn-1",
            "command": "sensitive command"
        }
    }));
    assert_eq!(effects.len(), 2);
    match &effects[0] {
        ProtocolEffect::Send(response) => {
            assert_eq!(response["id"], "approval-1");
            assert_eq!(response["error"]["code"], -32001);
            assert!(response.get("result").is_none());
        }
        _ => panic!("server request must be explicitly declined"),
    }
    match &effects[1] {
        ProtocolEffect::Fail(failure) => {
            assert_eq!(failure.code, "codex_user_interaction_required");
            assert!(failure.user_interaction_required);
            assert_eq!(
                failure.request_method.as_deref(),
                Some("item/commandExecution/requestApproval")
            );
            assert_eq!(failure.thread_id.as_deref(), Some("thread-1"));
            assert_eq!(failure.turn_id.as_deref(), Some("turn-1"));
        }
        _ => panic!("server request must stop autonomous dispatch"),
    }
}
