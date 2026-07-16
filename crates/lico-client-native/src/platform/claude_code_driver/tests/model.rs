use super::*;

#[test]
fn failed_result_projects_bound_ids_and_no_runtime_events() {
    let failure = ProtocolFailure::new("static", "Static failure.", "test")
        .with_session(Some("native-session"))
        .with_turn("turn-1");
    let result = RunResult::failed(failure, "started".to_string(), true, false);
    assert!(!result.ok);
    assert_eq!(result.session_id, "native-session");
    assert_eq!(result.thread_id, "native-session");
    assert_eq!(result.turn_id, "turn-1");
    assert!(result.events.is_empty());
    assert_eq!(result.effective.cwd, EffectiveSettings::default().cwd);
}
