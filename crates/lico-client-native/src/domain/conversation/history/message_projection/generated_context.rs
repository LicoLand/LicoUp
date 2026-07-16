use super::antigravity::system_boilerplate_text;
use super::semantic::looks_like_delegated_agent_prompt;

pub(super) fn extract_user_authored_text(text: &str) -> String {
    let request_text = if let Some(index) = find_case_insensitive(text, "## My request for Codex:")
    {
        &text[index + "## My request for Codex:".len()..]
    } else if let Some(index) = find_case_insensitive(text, "My request for Codex:") {
        &text[index + "My request for Codex:".len()..]
    } else {
        text
    };
    strip_generated_context_blocks(request_text)
}

pub(in crate::domain::conversation::history) fn strip_generated_context_blocks(
    text: &str,
) -> String {
    let mut lines = Vec::<String>::new();
    let mut close_marker: Option<&'static str> = None;
    for line in text.lines() {
        let lower = line.trim_start().to_ascii_lowercase();
        if let Some(close) = close_marker {
            if generated_context_line_contains_close(&lower, close) {
                close_marker = None;
                if let Some(after) = trailing_text_after_context_close(line, close) {
                    if !after.trim().is_empty() {
                        lines.push(after);
                    }
                }
            }
            continue;
        }
        if lower.starts_with("# files mentioned by the user:") {
            continue;
        }
        if let Some(close) = generated_context_block_close_marker(&lower) {
            if generated_context_line_contains_close(&lower, close) {
                if let Some(after) = trailing_text_after_context_close(line, close) {
                    if !after.trim().is_empty() {
                        lines.push(after);
                    }
                }
            } else {
                close_marker = Some(close);
            }
            continue;
        }
        lines.push(line.to_string());
    }
    lines.join("\n")
}

fn trailing_text_after_context_close(line: &str, close: &str) -> Option<String> {
    let lower = line.to_ascii_lowercase();
    let close_lower = close.to_ascii_lowercase();
    lower
        .find(&close_lower)
        .map(|index| line[index + close.len()..].to_string())
}

fn generated_context_block_close_marker(lower_line: &str) -> Option<&'static str> {
    for (prefix, close) in [
        ("<command-name", "</command-name>"),
        ("<command", "</command>"),
        ("<image", "</image>"),
        ("<system_message", "</system_message>"),
        ("<system-message", "</system-message>"),
        ("<environment_context", "</environment_context>"),
        ("<app-context", "</app-context>"),
        ("<apps_instructions", "</apps_instructions>"),
        ("<apps-instructions", "</apps-instructions>"),
        ("<skills_instructions", "</skills_instructions>"),
        ("<plugins_instructions", "</plugins_instructions>"),
        ("<recommended_plugins", "</recommended_plugins>"),
        ("<additional_metadata", "</additional_metadata>"),
        ("<collaboration_mode", "</collaboration_mode>"),
        ("<permissions instructions", "</permissions instructions>"),
        ("<system", "</system>"),
        ("<developer", "</developer>"),
        ("<instructions", "</instructions>"),
        ("<local-command-caveat", "</local-command-caveat>"),
        ("<local-command-output", "</local-command-output>"),
        ("<local-command-stdout", "</local-command-stdout>"),
        ("<local-command-stderr", "</local-command-stderr>"),
    ] {
        if lower_line.starts_with(prefix) {
            return Some(close);
        }
    }
    None
}

fn generated_context_line_contains_close(lower_line: &str, close: &str) -> bool {
    lower_line.contains(close)
        || compact_context_marker(lower_line).contains(&compact_context_marker(close))
}

fn compact_context_marker(value: &str) -> String {
    value
        .chars()
        .filter(|character| !matches!(character, '_' | '-' | ' ' | '\t'))
        .collect()
}

pub(in crate::domain::conversation::history) fn background_context_prompt_text(text: &str) -> bool {
    let lower = text.trim_start().to_ascii_lowercase();
    system_boilerplate_text(text)
        || lower.starts_with("# agents.md instructions")
        || lower.starts_with("agents.md instructions")
        || lower.starts_with("<instructions>")
        || lower.starts_with("you are codex, a coding agent")
        || lower.starts_with("you are chatgpt")
        || looks_like_delegated_agent_prompt(text)
        || lower.starts_with("knowledge cutoff:")
        || lower.starts_with("current date:")
        || lower.starts_with("filesystem sandboxing defines")
        || lower.starts_with("sandbox_mode")
        || lower.starts_with("<system")
        || lower.starts_with("<system_message")
        || lower.starts_with("<system-message")
        || lower.starts_with("<developer")
        || lower.starts_with("<app-context")
        || lower.starts_with("<apps_instructions")
        || lower.starts_with("<apps-instructions")
        || lower.starts_with("<environment_context")
        || lower.starts_with("<skills_instructions")
        || lower.starts_with("<plugins_instructions")
        || lower.starts_with("<collaboration_mode")
}

pub(in crate::domain::conversation::history) fn generated_control_text(text: &str) -> bool {
    let lower = text.trim_start().to_ascii_lowercase();
    lower.starts_with("<local-command-caveat>")
        || lower.starts_with("<command-name")
        || lower.starts_with("<command")
        || lower.starts_with("<local-command-output>")
        || lower.starts_with("<local-command-stdout>")
        || lower.starts_with("<local-command-stderr>")
        || lower.starts_with("<local-command-exit-code>")
        || lower.starts_with("<local-command-timeout>")
        || lower.starts_with("<environment_context>")
        || lower.starts_with("<apps_instructions>")
        || lower.starts_with("<apps-instructions>")
        || lower.starts_with("<recommended_plugins")
        || lower.starts_with("<additional_metadata")
        || lower.starts_with("<plugins_instructions")
        || background_context_prompt_text(text)
        || (lower.contains("<local-command-caveat>") && lower.contains("do not respond"))
}

fn find_case_insensitive(haystack: &str, needle: &str) -> Option<usize> {
    haystack
        .to_ascii_lowercase()
        .find(&needle.to_ascii_lowercase())
}
