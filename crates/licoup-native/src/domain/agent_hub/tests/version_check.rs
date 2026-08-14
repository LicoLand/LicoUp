use crate::domain::agent_hub::version_check::parse_output;

#[test]
fn each_agent_has_a_dedicated_parser() {
    assert_eq!(parse_output("codex", "codex-cli 0.147.0\n", ""), "0.147.0");
    assert_eq!(parse_output("cursor", "cursor-agent 2026.8.9\n", ""), "2026.8.9");
    assert_eq!(parse_output("opencode", "OpenCode 1.2.3\n", ""), "1.2.3");
    assert_eq!(
        parse_output("claude-code", "1.0.40 (Claude Code)\n", ""),
        "1.0.40"
    );
    assert_eq!(parse_output("pi", "pi 0.5.1\n", ""), "0.5.1");
    assert_eq!(parse_output("openclaw", "openclaw 0.3.0\n", ""), "0.3.0");
    assert_eq!(parse_output("hermes", "hermes 0.1.2\n", ""), "0.1.2");
    assert_eq!(parse_output("antigravity", "agy 0.9.0\n", ""), "0.9.0");
}

#[test]
fn unknown_tokens_and_empty_probes_stay_blank() {
    assert_eq!(parse_output("codex", "", ""), "");
    assert_eq!(parse_output("codex", "unknown\n", ""), "");
    assert_eq!(parse_output("codex", "未知\n", ""), "");
    assert_eq!(parse_output("cursor", "latest\n", ""), "");
    assert_eq!(parse_output("not-an-agent", "1.0.0\n", ""), "");
}

#[test]
fn stderr_is_used_when_stdout_is_empty() {
    assert_eq!(parse_output("claude-code", "", "claude 1.2.3\n"), "1.2.3");
}
