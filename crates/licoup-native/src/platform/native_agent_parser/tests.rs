use super::*;
use crate::platform::runtime_adapters::RuntimeAdapter;

const ALL: [RuntimeAdapter; 13] = [
    RuntimeAdapter::Antigravity,
    RuntimeAdapter::ClaudeCode,
    RuntimeAdapter::Codex,
    RuntimeAdapter::Copilot,
    RuntimeAdapter::Cursor,
    RuntimeAdapter::Hermes,
    RuntimeAdapter::KiloCode,
    RuntimeAdapter::KimiCode,
    RuntimeAdapter::OpenClaw,
    RuntimeAdapter::OpenCode,
    RuntimeAdapter::Pi,
    RuntimeAdapter::LicoAgent,
    RuntimeAdapter::DeepSeekHarness,
];

#[test]
fn native_agent_parser_registry_is_bijective_with_packaged_inventory() {
    let registered = ALL.map(|adapter| parser_for(adapter).id);
    assert_eq!(registered, PACKAGED_ADAPTER_IDS);
    for adapter in ALL {
        assert!(!parser_for(adapter).framing.is_empty());
        assert_eq!(
            parser_for(adapter).inventory_json()["adapterId"],
            adapter.id()
        );
    }
}

#[test]
fn native_agent_parser_reconciles_delta_and_cumulative_text_once() {
    let mut reconciler = TextReconciler::default();
    assert_eq!(
        reconciler.observe("reply", TextForm::Delta("你")),
        Ok("你".into())
    );
    assert_eq!(
        reconciler.observe("reply", TextForm::Cumulative("你好")),
        Ok("好".into())
    );
    assert_eq!(
        reconciler.observe("reply", TextForm::Cumulative("你好")),
        Ok(String::new())
    );
    assert_eq!(
        reconciler.observe("reply", TextForm::Cumulative("你")),
        Ok(String::new())
    );
    assert_eq!(
        reconciler.observe("reply", TextForm::Cumulative("你好呀")),
        Ok("呀".into())
    );
    assert_eq!(
        reconciler.observe("reply", TextForm::Cumulative("另一个")),
        Err("native_text_snapshot_diverged")
    );
}

#[test]
fn cursor_parser_streams_only_assistant_frames_and_completes_with_cumulative_result() {
    use crate::platform::cursor_driver::model::EffectiveSettings;
    use crate::platform::native_agent_parser::adapters::cursor::{CursorEffect, CursorParser};

    let mut parser = CursorParser::new("synthetic-session", EffectiveSettings::default());
    let init = parser
        .parse_line(br#"{"type":"system","subtype":"init","apiKeySource":"synthetic","cwd":"/tmp","session_id":"synthetic-session","model":"fake-model","permissionMode":"default"}"#)
        .unwrap();
    assert!(init.iter().any(|effect| matches!(
        effect,
        CursorEffect::Accepted { session_id, turn_id }
            if session_id == "synthetic-session" && turn_id == "cursor-turn"
    )));
    // The user prompt echo is an acknowledgement and must never output.
    let echo = parser
        .parse_line(br#"{"type":"user","session_id":"synthetic-session","message":{"role":"user","content":[{"type":"text","text":"exact user prompt"}]}}"#)
        .unwrap();
    assert!(
        echo.iter()
            .all(|effect| !matches!(effect, CursorEffect::Text { .. }))
    );
    let first = parser
        .parse_line(br#"{"type":"assistant","session_id":"synthetic-session","timestamp_ms":1,"message":{"role":"assistant","content":[{"type":"text","text":"hello "}]}}"#)
        .unwrap();
    assert!(first.iter().any(|effect| matches!(
        effect,
        CursorEffect::Text { text, .. } if text == "hello "
    )));
    let second = parser
        .parse_line(br#"{"type":"assistant","session_id":"synthetic-session","timestamp_ms":2,"message":{"role":"assistant","content":[{"type":"text","text":"world"}]}}"#)
        .unwrap();
    assert!(second.iter().any(|effect| matches!(
        effect,
        CursorEffect::Text { text, .. } if text == "world"
    )));
    // The cumulative result repeats the streamed fragments exactly: no extra
    // suffix, and completion carries the full cumulative reply with the
    // request-id transport turn id.
    let terminal = parser
        .parse_line(br#"{"type":"result","subtype":"success","is_error":false,"session_id":"synthetic-session","request_id":"req-1","result":"hello world"}"#)
        .unwrap();
    assert!(
        terminal
            .iter()
            .all(|effect| !matches!(effect, CursorEffect::Text { .. }))
    );
    assert!(terminal.iter().any(|effect| matches!(
        effect,
        CursorEffect::Complete(outcome)
            if outcome.output == "hello world" && outcome.turn_id == "req-1"
    )));
}

#[test]
fn cursor_parser_terminal_result_appends_missing_suffix() {
    use crate::platform::cursor_driver::model::EffectiveSettings;
    use crate::platform::native_agent_parser::adapters::cursor::{CursorEffect, CursorParser};

    let mut parser = CursorParser::new("synthetic-session", EffectiveSettings::default());
    let first = parser
        .parse_line(br#"{"type":"assistant","session_id":"synthetic-session","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}"#)
        .unwrap();
    assert!(first.iter().any(|effect| matches!(
        effect,
        CursorEffect::Text { text, .. } if text == "hello"
    )));
    let terminal = parser
        .parse_line(br#"{"type":"result","subtype":"success","is_error":false,"session_id":"synthetic-session","result":"hello world"}"#)
        .unwrap();
    assert!(terminal.iter().any(|effect| matches!(
        effect,
        CursorEffect::Text { text, .. } if text == " world"
    )));
    assert!(terminal.iter().any(|effect| matches!(
        effect,
        CursorEffect::Complete(outcome) if outcome.output == "hello world"
    )));
}

#[test]
fn cursor_parser_terminal_result_rejects_true_divergence() {
    use crate::platform::cursor_driver::model::EffectiveSettings;
    use crate::platform::native_agent_parser::adapters::cursor::{
        CursorParseFailure, CursorParser,
    };

    let mut parser = CursorParser::new("synthetic-session", EffectiveSettings::default());
    parser
        .parse_line(br#"{"type":"assistant","session_id":"synthetic-session","message":{"role":"assistant","content":[{"type":"text","text":"hello"},{"type":"text","text":" world"}]}}"#)
        .unwrap();
    let divergent = parser.parse_line(
        br#"{"type":"result","subtype":"success","is_error":false,"session_id":"synthetic-session","result":"a different answer"}"#,
    );
    assert!(matches!(
        divergent,
        Err(CursorParseFailure::TextSnapshotDiverged)
    ));
}

#[test]
fn cursor_parser_accepts_an_explicit_empty_success_result() {
    use crate::platform::cursor_driver::model::EffectiveSettings;
    use crate::platform::native_agent_parser::adapters::cursor::{CursorEffect, CursorParser};

    let mut parser = CursorParser::new("synthetic-session", EffectiveSettings::default());
    let effects = parser
        .parse_line(br#"{"type":"result","subtype":"success","result":""}"#)
        .unwrap();
    assert!(effects.iter().any(|effect| matches!(
        effect,
        CursorEffect::Complete(outcome) if outcome.output.is_empty()
    )));
}

#[test]
fn native_agent_parser_closes_lifecycle_prefix_and_keeps_first_failure() {
    let mut reducer = TransitionReducer::default();
    let stages = reducer.advance(LifecycleStage::Responding);
    assert_eq!(stages.len(), 4);
    assert!(matches!(
        stages[0],
        Transition::Lifecycle(LifecycleStage::Submitted)
    ));
    assert!(matches!(
        stages[3],
        Transition::Lifecycle(LifecycleStage::Responding)
    ));
    assert!(reducer.fail("native", "turn", "first").is_some());
    assert!(reducer.fail("observer", "observe", "later").is_none());
    assert!(reducer.advance(LifecycleStage::Completed).is_empty());
}

#[test]
fn native_agent_parser_rejects_failure_after_terminal_completion() {
    let mut reducer = TransitionReducer::default();
    assert_eq!(reducer.advance(LifecycleStage::Completed).len(), 5);
    assert!(
        reducer
            .fail("late_transport_failure", "observer/read", "late failure")
            .is_none()
    );
}
