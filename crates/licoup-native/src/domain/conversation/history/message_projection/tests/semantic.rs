use super::super::semantic::{
    HistoryMessageKind, delegated_subagent_prompt_title, history_message_kind_from_semantic,
    looks_like_delegated_agent_prompt, normalize_history_message_semantic,
};

#[test]
fn semantic_normalization_and_classification_are_stable() {
    assert_eq!(normalize_history_message_semantic(" Tool_Use "), "tool-use");
    assert_eq!(
        history_message_kind_from_semantic("function_call_output"),
        HistoryMessageKind::ToolResult
    );
    assert_eq!(
        history_message_kind_from_semantic("reasoning-summary"),
        HistoryMessageKind::Reasoning
    );
    assert_eq!(
        history_message_kind_from_semantic("assistant-message"),
        HistoryMessageKind::Text
    );
}

#[test]
fn delegated_prompt_detection_and_title_are_bounded() {
    let prompt = "You are A12: privacy reviewer for conversation projection. Inspect only.";
    assert!(looks_like_delegated_agent_prompt(prompt));
    assert_eq!(
        delegated_subagent_prompt_title(prompt).as_deref(),
        Some("A12: privacy reviewer")
    );
    assert!(!looks_like_delegated_agent_prompt(
        "You are a helpful assistant."
    ));
}
