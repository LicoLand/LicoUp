use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::env;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const RUNTIME_SCHEMA_VERSION: u32 = 1;
const DEFAULT_TIMEOUT_MS: u64 = 120_000;
const DEFAULT_MAX_STDOUT_BYTES: usize = 2 * 1024 * 1024;
const DEFAULT_MAX_STDERR_BYTES: usize = 512 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RuntimeAdapter {
    Antigravity,
    ClaudeCode,
    Codex,
    Copilot,
    Cursor,
    Hermes,
    KiloCode,
    OpenClaw,
    OpenCode,
}

struct RuntimeCommand {
    executable: String,
    args: Vec<String>,
    stdin: Option<String>,
    cwd: Option<PathBuf>,
    protocol: &'static str,
}

pub fn send_message(params: &Value) -> Result<Value> {
    let agent_id = text_param(params, &["agent", "agentId", "target"])
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("agent message send requires --agent"))?;
    let text = text_param(params, &["text", "message", "prompt"])
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("agent message send requires --text"))?;
    let adapter = adapter_for_agent(&agent_id)
        .ok_or_else(|| anyhow!("unsupported runtime adapter: {}", agent_id))?;
    let session_id = text_param(params, &["sessionId", "nativeSessionId"]).unwrap_or_default();
    let cwd = text_param(params, &["cwd", "workingDirectory"])
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::current_dir().ok());
    let command = runtime_command(adapter, params, &text, &session_id, cwd.as_deref())?;
    let timeout_ms = u64_param(params, "timeoutMs", DEFAULT_TIMEOUT_MS);
    let max_stdout = u64_param(params, "maxStdoutBytes", DEFAULT_MAX_STDOUT_BYTES as u64) as usize;
    let max_stderr = u64_param(params, "maxStderrBytes", DEFAULT_MAX_STDERR_BYTES as u64) as usize;
    let execution = execute_runtime_command(command, timeout_ms, max_stdout, max_stderr)?;
    Ok(json!({
        "ok": execution.ok,
        "schemaVersion": RUNTIME_SCHEMA_VERSION,
        "mode": "runtime-adapter",
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "runtimeProtocol": execution.protocol,
        "agentId": adapter.id(),
        "sessionId": session_id,
        "statusCode": execution.status_code,
        "output": execution.output,
        "stderr": execution.stderr,
        "stdoutTruncated": execution.stdout_truncated,
        "stderrTruncated": execution.stderr_truncated,
        "pid": execution.pid,
        "startedAt": execution.started_at,
        "completedAt": timestamp(),
        "planner": false,
        "clientOwnedToolLoop": false,
        "approvalOwner": "target-agent-runtime"
    }))
}

fn runtime_command(
    adapter: RuntimeAdapter,
    params: &Value,
    text: &str,
    session_id: &str,
    cwd: Option<&Path>,
) -> Result<RuntimeCommand> {
    if let Some(command) = custom_runtime_command(params, text, session_id, cwd) {
        return Ok(command);
    }
    let cwd_text = cwd
        .map(|path| path.to_string_lossy().to_string())
        .unwrap_or_default();
    match adapter {
        RuntimeAdapter::Codex => {
            let executable = binary_param(params, "codex");
            let mut args = vec!["exec".to_string()];
            if session_id.trim().is_empty() {
                args.extend([
                    "--skip-git-repo-check".to_string(),
                    "--sandbox".to_string(),
                    "read-only".to_string(),
                    "--ask-for-approval".to_string(),
                    "never".to_string(),
                ]);
                if !cwd_text.is_empty() {
                    args.extend(["--cd".to_string(), cwd_text]);
                }
                args.push("-".to_string());
            } else {
                args.extend([
                    "resume".to_string(),
                    "--skip-git-repo-check".to_string(),
                    session_id.to_string(),
                    "-".to_string(),
                ]);
            }
            Ok(RuntimeCommand {
                executable,
                args,
                stdin: Some(text.to_string()),
                cwd: cwd.map(Path::to_path_buf),
                protocol: "codex-cli-exec",
            })
        }
        RuntimeAdapter::OpenCode => {
            let executable = binary_param(params, "opencode");
            let mut args = vec![
                "run".to_string(),
                "--format".to_string(),
                "json".to_string(),
            ];
            if !session_id.trim().is_empty() {
                args.extend(["--session".to_string(), session_id.to_string()]);
            }
            if !cwd_text.is_empty() {
                args.extend(["--dir".to_string(), cwd_text]);
            }
            args.push(text.to_string());
            Ok(RuntimeCommand {
                executable,
                args,
                stdin: None,
                cwd: cwd.map(Path::to_path_buf),
                protocol: "opencode-cli-run",
            })
        }
        RuntimeAdapter::Copilot => {
            let executable = binary_param(params, "copilot");
            let mut args = vec![
                "--prompt".to_string(),
                text.to_string(),
                "--output-format".to_string(),
                "json".to_string(),
                "--no-remote".to_string(),
                "--plan".to_string(),
            ];
            if !session_id.trim().is_empty() {
                args.extend(["--resume".to_string(), session_id.to_string()]);
            }
            if !cwd_text.is_empty() {
                args.extend(["-C".to_string(), cwd_text]);
            }
            Ok(RuntimeCommand {
                executable,
                args,
                stdin: None,
                cwd: cwd.map(Path::to_path_buf),
                protocol: "copilot-cli-prompt",
            })
        }
        RuntimeAdapter::Antigravity
        | RuntimeAdapter::ClaudeCode
        | RuntimeAdapter::Cursor
        | RuntimeAdapter::Hermes
        | RuntimeAdapter::KiloCode
        | RuntimeAdapter::OpenClaw => Err(anyhow!(
            "{} runtime adapter requires an explicit --command/--args protocol configuration",
            adapter.id()
        )),
    }
}

fn custom_runtime_command(
    params: &Value,
    text: &str,
    session_id: &str,
    cwd: Option<&Path>,
) -> Option<RuntimeCommand> {
    let executable = params.get("command").and_then(Value::as_str)?.trim();
    if executable.is_empty() {
        return None;
    }
    let cwd_text = cwd
        .map(|path| path.to_string_lossy().to_string())
        .unwrap_or_default();
    let mut args = args_param(params)
        .into_iter()
        .map(|arg| replace_placeholders(&arg, text, session_id, &cwd_text))
        .collect::<Vec<_>>();
    let stdin = if args.iter().any(|arg| arg.contains(text)) {
        None
    } else if bool_param(params, "stdin").unwrap_or(args.is_empty()) {
        Some(text.to_string())
    } else {
        args.push(text.to_string());
        None
    };
    Some(RuntimeCommand {
        executable: executable.to_string(),
        args,
        stdin,
        cwd: cwd.map(Path::to_path_buf),
        protocol: "configured-command",
    })
}

struct RuntimeExecution {
    ok: bool,
    status_code: Option<i32>,
    output: String,
    stderr: String,
    stdout_truncated: bool,
    stderr_truncated: bool,
    pid: u32,
    started_at: String,
    protocol: &'static str,
}

fn execute_runtime_command(
    command: RuntimeCommand,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> Result<RuntimeExecution> {
    let started_at = timestamp();
    let mut process = Command::new(&command.executable);
    process.args(&command.args);
    if let Some(cwd) = &command.cwd {
        process.current_dir(cwd);
    }
    let mut child = process
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| anyhow!("failed to start runtime adapter command: {}", error))?;
    if let Some(stdin_text) = command.stdin {
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(stdin_text.as_bytes())?;
        }
    }

    let pid = child.id();
    let deadline = SystemTime::now() + Duration::from_millis(timeout_ms);
    loop {
        match child.try_wait()? {
            Some(status) => {
                let output = child.wait_with_output()?;
                let stdout_len = output.stdout.len().min(max_stdout);
                let stderr_len = output.stderr.len().min(max_stderr);
                return Ok(RuntimeExecution {
                    ok: status.success(),
                    status_code: status.code(),
                    output: String::from_utf8_lossy(&output.stdout[..stdout_len]).to_string(),
                    stderr: String::from_utf8_lossy(&output.stderr[..stderr_len]).to_string(),
                    stdout_truncated: output.stdout.len() > max_stdout,
                    stderr_truncated: output.stderr.len() > max_stderr,
                    pid,
                    started_at,
                    protocol: command.protocol,
                });
            }
            None => {
                if SystemTime::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Ok(RuntimeExecution {
                        ok: false,
                        status_code: None,
                        output: String::new(),
                        stderr: format!("Runtime adapter timed out after {}ms", timeout_ms),
                        stdout_truncated: false,
                        stderr_truncated: false,
                        pid,
                        started_at,
                        protocol: command.protocol,
                    });
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

fn adapter_for_agent(agent_id: &str) -> Option<RuntimeAdapter> {
    match agent_id {
        "antigravity" => Some(RuntimeAdapter::Antigravity),
        "claude" | "claude-code" => Some(RuntimeAdapter::ClaudeCode),
        "codex" => Some(RuntimeAdapter::Codex),
        "copilot" | "github-copilot" => Some(RuntimeAdapter::Copilot),
        "cursor" => Some(RuntimeAdapter::Cursor),
        "hermes" | "hermes-agent" => Some(RuntimeAdapter::Hermes),
        "kilo" | "kilo-code" => Some(RuntimeAdapter::KiloCode),
        "openclaw" => Some(RuntimeAdapter::OpenClaw),
        "opencode" => Some(RuntimeAdapter::OpenCode),
        _ => None,
    }
}

impl RuntimeAdapter {
    fn id(self) -> &'static str {
        match self {
            RuntimeAdapter::Antigravity => "antigravity",
            RuntimeAdapter::ClaudeCode => "claude-code",
            RuntimeAdapter::Codex => "codex",
            RuntimeAdapter::Copilot => "copilot",
            RuntimeAdapter::Cursor => "cursor",
            RuntimeAdapter::Hermes => "hermes",
            RuntimeAdapter::KiloCode => "kilo-code",
            RuntimeAdapter::OpenClaw => "openclaw",
            RuntimeAdapter::OpenCode => "opencode",
        }
    }

    fn label(self) -> &'static str {
        match self {
            RuntimeAdapter::Antigravity => "Antigravity",
            RuntimeAdapter::ClaudeCode => "Claude Code",
            RuntimeAdapter::Codex => "Codex",
            RuntimeAdapter::Copilot => "GitHub Copilot",
            RuntimeAdapter::Cursor => "Cursor",
            RuntimeAdapter::Hermes => "Hermes Agent",
            RuntimeAdapter::KiloCode => "Kilo Code",
            RuntimeAdapter::OpenClaw => "OpenClaw",
            RuntimeAdapter::OpenCode => "OpenCode",
        }
    }
}

fn binary_param(params: &Value, fallback: &str) -> String {
    text_param(params, &["binary", "binaryPath", "executable"])
        .unwrap_or_else(|| fallback.to_string())
}

fn args_param(params: &Value) -> Vec<String> {
    params
        .get("args")
        .or_else(|| params.get("commandArgs"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .or_else(|| {
            params
                .get("args")
                .or_else(|| params.get("argsJson"))
                .and_then(Value::as_str)
                .and_then(parse_args_json)
        })
        .or_else(|| {
            params
                .get("argsJson")
                .and_then(Value::as_str)
                .and_then(parse_args_json)
        })
        .unwrap_or_default()
}

fn parse_args_json(text: &str) -> Option<Vec<String>> {
    serde_json::from_str::<Value>(text).ok().and_then(|value| {
        value.as_array().map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
    })
}

fn replace_placeholders(value: &str, text: &str, session_id: &str, cwd: &str) -> String {
    value
        .replace("{prompt}", text)
        .replace("{text}", text)
        .replace("{message}", text)
        .replace("{sessionId}", session_id)
        .replace("{cwd}", cwd)
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(|value| value.trim().to_string())
}

fn u64_param(params: &Value, key: &str, fallback: u64) -> u64 {
    params
        .get(key)
        .and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.trim().parse().ok()))
        })
        .unwrap_or(fallback)
}

fn bool_param(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(|value| {
        value.as_bool().or_else(|| match value.as_str()?.trim() {
            "true" | "1" | "yes" => Some(true),
            "false" | "0" | "no" => Some(false),
            _ => None,
        })
    })
}

fn timestamp() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("{}", millis)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn codex_runtime_adapter_builds_read_only_exec_command() {
        let command = runtime_command(
            RuntimeAdapter::Codex,
            &json!({"binary": "codex-test"}),
            "hello",
            "",
            Some(Path::new("/tmp/lico-runtime")),
        )
        .unwrap();
        assert_eq!(command.executable, "codex-test");
        assert_eq!(command.protocol, "codex-cli-exec");
        assert!(command.args.contains(&"--sandbox".to_string()));
        assert!(command.args.contains(&"read-only".to_string()));
        assert!(command.args.contains(&"--ask-for-approval".to_string()));
        assert!(command.args.contains(&"never".to_string()));
        assert_eq!(command.stdin.as_deref(), Some("hello"));
    }

    #[test]
    fn opencode_runtime_adapter_maps_session_id() {
        let command = runtime_command(
            RuntimeAdapter::OpenCode,
            &json!({"binary": "opencode-test"}),
            "hello",
            "session-1",
            Some(Path::new("/tmp/lico-runtime")),
        )
        .unwrap();
        assert_eq!(command.protocol, "opencode-cli-run");
        assert_eq!(command.args[0], "run");
        assert!(
            command
                .args
                .windows(2)
                .any(|items| items == ["--session", "session-1"])
        );
        assert!(
            command
                .args
                .windows(2)
                .any(|items| items == ["--dir", "/tmp/lico-runtime"])
        );
    }

    #[cfg(unix)]
    #[test]
    fn configured_runtime_command_executes_without_shell_parsing() {
        let dir = env::temp_dir().join(format!("lico-runtime-{}", timestamp()));
        fs::create_dir_all(&dir).unwrap();
        let script = dir.join("echo-agent.sh");
        fs::write(&script, "#!/bin/sh\nprintf 'agent:%s' \"$1\"\n").unwrap();
        let mut permissions = fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script, permissions).unwrap();

        let result = send_message(&json!({
            "agent": "codex",
            "text": "from-phone",
            "command": script.to_string_lossy(),
            "args": ["{prompt}"],
            "timeoutMs": 5_000
        }))
        .unwrap();

        assert_eq!(result["ok"], true);
        assert_eq!(result["mode"], "runtime-adapter");
        assert_eq!(result["runtimeProtocol"], "configured-command");
        assert_eq!(result["output"], "agent:from-phone");
    }

    #[test]
    fn args_param_parses_cli_args_json_string() {
        assert_eq!(
            args_param(&json!({"args": ["{prompt}", "--flag"]})),
            vec!["{prompt}".to_string(), "--flag".to_string()]
        );
        assert_eq!(
            args_param(&json!({"args": r#"["{prompt}","--flag"]"#})),
            vec!["{prompt}".to_string(), "--flag".to_string()]
        );
    }

    #[test]
    fn unsupported_default_runtime_requires_protocol_configuration() {
        let error = send_message(&json!({
            "agent": "antigravity",
            "text": "hello"
        }))
        .unwrap_err();
        assert!(error.to_string().contains("requires an explicit"));
    }

    #[test]
    fn unknown_runtime_adapter_is_rejected() {
        let error = send_message(&json!({
            "agent": "unknown",
            "text": "hello"
        }))
        .unwrap_err();
        assert!(error.to_string().contains("unsupported runtime adapter"));
    }
}
