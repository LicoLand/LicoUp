use super::super::generated_context::{
    background_context_prompt_text, extract_user_authored_text, generated_control_text,
    strip_generated_context_blocks,
};

#[test]
fn generated_context_blocks_are_removed_without_dropping_trailing_user_text() {
    let text = "<environment_context>\nprivate context\n</environment_context>Keep this\nUser line";
    assert_eq!(strip_generated_context_blocks(text), "Keep this\nUser line");
    assert_eq!(
        extract_user_authored_text("## My request for Codex:\nDo the bounded change"),
        "\nDo the bounded change"
    );
}

#[test]
fn generated_control_and_background_prompts_fail_closed() {
    assert!(generated_control_text(
        "<local-command-output>secret</local-command-output>"
    ));
    assert!(background_context_prompt_text(
        "# AGENTS.md instructions\nprivate rules"
    ));
    assert!(!generated_control_text("User-authored message"));
}
