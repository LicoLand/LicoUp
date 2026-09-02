use serde_json::json;

use super::super::super::HistoryPageConfig;
use super::super::dedupe_paging::{
    dedupe_history_sessions, history_session_dedupe_key, paged_history_sessions,
};

#[test]
fn dedupe_uses_codex_native_identity_and_other_adapter_source_identity() {
    let codex_active = json!({
        "adapterId": "codex", "nativeSessionId": "same", "sourcePath": "active"
    });
    let codex_archive = json!({
        "adapterId": "codex", "nativeSessionId": "same", "sourcePath": "archive"
    });
    assert_eq!(
        history_session_dedupe_key(&codex_active),
        history_session_dedupe_key(&codex_archive)
    );
    assert_eq!(
        dedupe_history_sessions(vec![codex_active, codex_archive]).len(),
        1
    );

    let other_a = json!({"adapterId": "pi", "nativeSessionId": "same", "sourcePath": "a"});
    let other_b = json!({"adapterId": "pi", "nativeSessionId": "same", "sourcePath": "b"});
    assert_ne!(
        history_session_dedupe_key(&other_a),
        history_session_dedupe_key(&other_b)
    );
}

#[test]
fn paging_applies_offset_and_bounded_end_without_overread() {
    let sessions = (0..5).map(|id| json!({"id": id})).collect();
    let page = HistoryPageConfig {
        offset: 2,
        limit: Some(2),
    };
    let page = paged_history_sessions(sessions, &page);
    assert_eq!(page, vec![json!({"id": 2}), json!({"id": 3})]);

    let empty = paged_history_sessions(
        vec![json!({"id": 1})],
        &HistoryPageConfig {
            offset: 2,
            limit: Some(1),
        },
    );
    assert!(empty.is_empty());
}
