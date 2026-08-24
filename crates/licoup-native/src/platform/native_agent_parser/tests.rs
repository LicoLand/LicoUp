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
fn cursor_parser_keeps_one_lossless_text_unit_across_stale_snapshots() {
    use crate::platform::cursor_driver::model::EffectiveSettings;
    use crate::platform::native_agent_parser::adapters::cursor::{CursorEffect, CursorParser};

    let mut parser = CursorParser::new("synthetic-session", EffectiveSettings::default());
    let first = parser
        .parse_line(br#"{"type":"content_block_delta","delta":{"text":"hello"}}"#)
        .unwrap();
    assert!(first.iter().any(|effect| matches!(
        effect,
        CursorEffect::Text { text, .. } if text == "hello"
    )));
    let stale = parser
        .parse_line(br#"{"type":"assistant","message":{"content":[{"type":"text","text":"hel"}]}}"#)
        .unwrap();
    assert!(
        !stale
            .iter()
            .any(|effect| matches!(effect, CursorEffect::Text { .. }))
    );
    let terminal = parser
        .parse_line(br#"{"type":"result","subtype":"success","result":"hello world"}"#)
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
