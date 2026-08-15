//! Per-agent installed-version probes. Missing agents stay blank; never "unknown".

use super::argv::{self, ArgvKind};
use super::contract::{AgentRecipe, FIRST_BATCH_IDS, InstallChannel};
use super::version;
use serde_json::Value;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const PROBE_TIMEOUT: Duration = Duration::from_millis(1500);

pub fn installed_version(
    agent: &AgentRecipe,
    channel: Option<&InstallChannel>,
    present: bool,
    live_lookup: bool,
    params: &Value,
) -> String {
    if !present {
        return String::new();
    }
    if let Some(injected) = injected_probe(params, &agent.id) {
        return parse_output(&agent.id, &injected, "");
    }
    if !live_lookup {
        return String::new();
    }
    let Some(channel) = channel else {
        return String::new();
    };
    if channel.verify_argv.is_empty() {
        return String::new();
    }
    let program = &channel.verify_argv[0];
    let args = &channel.verify_argv[1..];
    if argv::validate_program_args(program, args, ArgvKind::Lifecycle).is_err() {
        return String::new();
    }
    let output = match run_probe(program, args) {
        Some(output) => output,
        None => return String::new(),
    };
    parse_output(&agent.id, &output.stdout, &output.stderr)
}

pub fn parse_output(agent_id: &str, stdout: &str, stderr: &str) -> String {
    let combined = if stdout.trim().is_empty() {
        stderr
    } else {
        stdout
    };
    let parsed = match agent_id {
        "codex" => parse_codex(combined),
        "cursor" => parse_cursor(combined),
        "opencode" => parse_opencode(combined),
        "claude-code" => parse_claude_code(combined),
        "pi" => parse_pi(combined),
        "openclaw" => parse_openclaw(combined),
        "hermes" => parse_hermes(combined),
        "antigravity" => parse_antigravity(combined),
        _ => String::new(),
    };
    reject_unknown(parsed)
}

fn parse_codex(raw: &str) -> String {
    version::concrete_display(strip_prefix(raw, &["codex-cli", "codex"]))
}

fn parse_cursor(raw: &str) -> String {
    version::concrete_display(strip_prefix(raw, &["cursor-agent", "cursor"]))
}

fn parse_opencode(raw: &str) -> String {
    version::concrete_display(strip_prefix(raw, &["opencode", "OpenCode"]))
}

fn parse_claude_code(raw: &str) -> String {
    version::concrete_display(strip_prefix(raw, &["claude", "Claude Code", "Claude"]))
}

fn parse_pi(raw: &str) -> String {
    version::concrete_display(strip_prefix(raw, &["pi-agent", "pi"]))
}

fn parse_openclaw(raw: &str) -> String {
    version::concrete_display(strip_prefix(raw, &["openclaw"]))
}

fn parse_hermes(raw: &str) -> String {
    version::concrete_display(strip_prefix(raw, &["hermes-agent", "hermes"]))
}

fn parse_antigravity(raw: &str) -> String {
    version::concrete_display(strip_prefix(raw, &["agy", "antigravity"]))
}

fn strip_prefix<'a>(raw: &'a str, prefixes: &[&str]) -> &'a str {
    let line = raw
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("");
    for prefix in prefixes {
        if let Some(rest) = line
            .strip_prefix(prefix)
            .or_else(|| line.strip_prefix(&format!("{prefix} ")))
        {
            return rest.trim();
        }
    }
    line
}

fn reject_unknown(value: String) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("unknown") || trimmed == "未知" {
        return String::new();
    }
    trimmed.to_string()
}

pub(crate) fn injected_probe(params: &Value, agent_id: &str) -> Option<String> {
    if !FIRST_BATCH_IDS.contains(&agent_id) {
        return None;
    }
    params
        .get("versionProbes")
        .and_then(Value::as_object)
        .and_then(|map| map.get(agent_id))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

struct ProbeOutput {
    stdout: String,
    stderr: String,
}

fn run_probe(program: &str, args: &[String]) -> Option<ProbeOutput> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + PROBE_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                let output = child.wait_with_output().ok()?;
                return Some(ProbeOutput {
                    stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                    stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                });
            }
            Ok(None) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(40));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}
