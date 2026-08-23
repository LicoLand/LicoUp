use super::*;

#[test]
fn failed_result_projects_bound_ids_and_parser_failure_transition() {
    let failure = ProtocolFailure::new("static", "Static failure.", "test")
        .with_session(Some("native-session"))
        .with_turn("turn-1");
    let result = RunResult::failed(failure, "started".to_string(), true, false);
    assert!(!result.ok);
    assert_eq!(result.session_id, "native-session");
    assert_eq!(result.thread_id, "native-session");
    assert_eq!(result.turn_id, "turn-1");
    assert!(matches!(
        result.transitions.last(),
        Some(crate::platform::native_agent_parser::Transition::Failed { code, .. }) if code == "static"
    ));
    assert_eq!(result.effective.cwd, EffectiveSettings::default().cwd);
}

#[test]
fn transport_lifecycle_is_monotonic_and_single_claimed() {
    let lifecycle = TransportLifecycle::default();
    assert!(lifecycle.is_live());
    assert!(lifecycle.begin_closing());
    assert!(!lifecycle.is_live());
    assert!(lifecycle.is_closing());
    assert!(!lifecycle.begin_closing());
    assert!(lifecycle.mark_closed());
    assert!(lifecycle.is_closed());
    assert!(!lifecycle.mark_closed());
}

#[test]
fn transcript_evicts_fifo_by_turn_and_byte_limits_and_clears() {
    let mut transcript = BoundedTranscript::new(2, 18);
    transcript.record_success("turn-1", "123456");
    transcript.record_success("turn-2", "abcdef");
    transcript.record_success("turn-3", "uvwxyz");

    let projection = transcript.project();
    assert_eq!(projection.len(), 2);
    assert_eq!(projection[0]["turnId"], "turn-2");
    assert_eq!(projection[1]["turnId"], "turn-3");
    assert_eq!(transcript.byte_count(), "abcdefuvwxyz".len());

    transcript.record_success("turn-oversized", "this entry exceeds the whole byte budget");
    assert!(transcript.project().is_empty());
    assert_eq!(transcript.byte_count(), 0);

    transcript.record_success("turn-4", "bounded");
    transcript.clear();
    assert!(transcript.project().is_empty());
    assert_eq!(transcript.byte_count(), 0);
}

#[test]
fn transcript_counts_utf8_bytes_and_keeps_the_latest_valid_fifo_suffix() {
    let first = "甲🙂";
    let second = "乙🙂";
    let third = "éé";
    assert_eq!(first.as_bytes().len(), 7);
    assert_ne!(first.as_bytes().len(), first.chars().count());

    let mut transcript = BoundedTranscript::new(8, 13);
    transcript.record_success("turn-first", first);
    transcript.record_success("turn-second", second);

    let after_first_eviction = transcript.project();
    assert_eq!(after_first_eviction.len(), 1);
    assert_eq!(after_first_eviction[0]["turnId"], "turn-second");
    assert_eq!(after_first_eviction[0]["output"], second);
    assert_eq!(transcript.byte_count(), second.as_bytes().len());

    transcript.record_success("turn-third", third);
    let retained_suffix = transcript.project();
    assert_eq!(retained_suffix.len(), 2);
    assert_eq!(retained_suffix[0]["turnId"], "turn-second");
    assert_eq!(retained_suffix[1]["turnId"], "turn-third");
    assert_eq!(
        transcript.byte_count(),
        second.as_bytes().len() + third.as_bytes().len()
    );
}
