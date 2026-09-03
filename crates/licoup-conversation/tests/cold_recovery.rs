use licoup_conversation::{ConversationStore, DispatchState};
use serde_json::json;

#[test]
fn cold_recovery_kill_mid_turn_rebuilds_store_without_orphan_inflight_state() {
    let root = std::env::temp_dir().join(format!(
        "lico-conversation-cold-recovery-{}",
        uuid::Uuid::new_v4()
    ));
    let scope = {
        let host = ConversationStore::open(&root).unwrap();
        let scope = host
            .prepare_runtime_dispatch(
                "fixture-agent",
                "",
                "persist this turn",
                None,
                None,
                None,
                None,
            )
            .unwrap();
        host.append_runtime_frame(
            &scope,
            1,
            &json!({"type": "agent.message.chunk", "delta": "partial"}),
        )
        .unwrap();
        assert_eq!(
            host.dispatch_record(&scope.dispatch_id)
                .unwrap()
                .unwrap()
                .state,
            DispatchState::Running
        );
        // Dropping the only host models an abrupt process loss: no in-memory
        // value is handed to the next host.
        scope
    };

    let reopened = ConversationStore::open(&root).unwrap();
    let dispatch = reopened
        .dispatch_record(&scope.dispatch_id)
        .unwrap()
        .unwrap();
    assert_eq!(dispatch.state, DispatchState::Failed);
    assert_eq!(
        dispatch.error_code.as_deref(),
        Some("host_lifecycle_interrupted")
    );
    let events = reopened
        .page_events(&scope.conversation_id, None, 100)
        .unwrap()
        .events;
    let runtime_event = events
        .iter()
        .find(|event| event.id == scope.event_id)
        .unwrap();
    assert!(runtime_event.finalized);
    assert!(
        runtime_event
            .parts
            .iter()
            .any(|part| { part.content.contains("host_lifecycle_interrupted") })
    );
    assert_eq!(reopened.cold_recover().unwrap().recovered_dispatches, 0);

    let _ = std::fs::remove_dir_all(root);
}
