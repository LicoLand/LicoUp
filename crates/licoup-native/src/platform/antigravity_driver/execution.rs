use super::control::{clear_active_turn, register_active_turn, safe_session_id};
use super::errors::ProtocolFailure;
use super::hooks::{ensure_hook_bridge, read_conversation_id, receipt_path_for_turn};
use super::model::{EffectiveSettings, PROCESS_POLL_INTERVAL, RECEIPT_ENV, RunResult};
use crate::platform::process_supervisor::{IO_THREAD_EXIT_GRACE, SupervisedChild, join_bounded};
use serde_json::{Value, json};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub(in crate::platform) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> RunResult {
    let started_at = timestamp();
    if prompt.trim().is_empty() {
        return RunResult::failed(
            ProtocolFailure::new(
                "antigravity_cli_empty_prompt",
                "Antigravity CLI requires a non-empty message.",
                "request/validate",
            )
            .with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    }
    // Consent gate: the vendor CLI opens a browser OAuth flow for print turns
    // while logged out. Probe first so a send never jumps to the browser.
    if let Err(failure) = super::auth::ensure_authorized(executable) {
        return RunResult::failed(
            failure.with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    }
    if let Err(failure) = ensure_hook_bridge() {
        return RunResult::failed(
            failure.with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    }
    let receipt = match receipt_path_for_turn() {
        Ok(path) => path,
        Err(failure) => {
            return RunResult::failed(
                failure.with_session(Some(session_id)),
                started_at,
                false,
                false,
            );
        }
    };
    let workspace = resolve_workspace(params, cwd);
    let requested = session_id.trim();
    let mut command = Command::new(executable);
    command
        .arg(format!("--print={prompt}"))
        .arg("--dangerously-skip-permissions")
        .current_dir(&workspace)
        .env(RECEIPT_ENV, &receipt)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if !requested.is_empty() {
        if !safe_session_id(requested) {
            return RunResult::failed(
                ProtocolFailure::new(
                    "antigravity_cli_session_invalid",
                    "Antigravity CLI resume requires a safe native conversation identifier.",
                    "session/resume",
                )
                .with_session(Some(requested)),
                started_at,
                false,
                false,
            );
        }
        command.arg(format!("--conversation={requested}"));
    }
    apply_optional_flags(&mut command, params, &workspace);

    let mut child = match SupervisedChild::spawn(&mut command) {
        Ok(child) => child,
        Err(_) => {
            return RunResult::failed(
                ProtocolFailure::new(
                    "antigravity_cli_start_failed",
                    "Antigravity CLI could not be started.",
                    "process/start",
                )
                .with_session(Some(session_id)),
                started_at,
                false,
                false,
            );
        }
    };
    let Some(stdout) = child.stdout() else {
        let _ = child.terminate_tree();
        return RunResult::failed(
            ProtocolFailure::new(
                "antigravity_cli_start_failed",
                "Antigravity CLI stdout is unavailable.",
                "process/start",
            )
            .with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    };
    let Some(stderr) = child.stderr() else {
        let _ = child.terminate_tree();
        return RunResult::failed(
            ProtocolFailure::new(
                "antigravity_cli_start_failed",
                "Antigravity CLI stderr is unavailable.",
                "process/start",
            )
            .with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    };
    if !requested.is_empty() {
        register_active_turn(requested, child.pid());
    }
    let stdout_handle = thread::spawn(move || read_bounded(stdout, max_stdout));
    let stderr_handle = thread::spawn(move || read_bounded(stderr, max_stderr));
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    while (!stdout_handle.is_finished() || !stderr_handle.is_finished())
        && Instant::now() < deadline
    {
        thread::sleep(PROCESS_POLL_INTERVAL);
    }
    let timed_out = !stdout_handle.is_finished() || !stderr_handle.is_finished();
    let status = child.terminate_tree().ok().flatten();
    if !requested.is_empty() {
        clear_active_turn(requested);
    }
    let stdout = join_bounded(stdout_handle, IO_THREAD_EXIT_GRACE).ok();
    let stderr = join_bounded(stderr_handle, IO_THREAD_EXIT_GRACE).ok();
    let stdout_truncated = stdout.as_ref().is_some_and(|value| value.truncated);
    let stderr_truncated = stderr.as_ref().is_some_and(|value| value.truncated);
    if timed_out {
        return RunResult::failed(
            ProtocolFailure::new(
                "antigravity_cli_timeout",
                "Antigravity CLI timed out before completing the turn.",
                "turn/execute",
            )
            .with_session(Some(session_id)),
            started_at,
            stdout_truncated,
            stderr_truncated,
        );
    }
    let status_code = status.as_ref().and_then(std::process::ExitStatus::code);
    let output = stdout
        .as_ref()
        .map(|value| value.text.trim().to_string())
        .unwrap_or_default();
    let receipt_session = read_conversation_id(&receipt).unwrap_or_default();
    let native_session = if !requested.is_empty() {
        requested.to_string()
    } else {
        receipt_session.clone()
    };
    if native_session.is_empty() || !safe_session_id(&native_session) {
        return RunResult::failed(
            ProtocolFailure::new(
                "antigravity_hook_receipt_missing",
                "Antigravity hook bridge did not return a native conversation identifier.",
                "session/new",
            )
            .with_session(Some(session_id)),
            started_at,
            stdout_truncated,
            stderr_truncated,
        );
    }
    if !requested.is_empty() && !receipt_session.is_empty() && receipt_session != requested {
        return RunResult::failed(
            ProtocolFailure::new(
                "antigravity_cli_session_drift",
                "Antigravity CLI resumed a different native conversation than requested.",
                "session/resume",
            )
            .with_session(Some(requested)),
            started_at,
            stdout_truncated,
            stderr_truncated,
        );
    }
    if !status.is_some_and(|value| value.success()) {
        return RunResult::failed(
            ProtocolFailure::new(
                "antigravity_cli_turn_failed",
                "Antigravity CLI exited without a successful turn.",
                "turn/execute",
            )
            .with_session(Some(&native_session)),
            started_at,
            stdout_truncated,
            stderr_truncated,
        );
    }
    if output.is_empty() {
        return RunResult::failed(
            ProtocolFailure::new(
                "antigravity_cli_empty_output",
                "Antigravity CLI returned an empty final response.",
                "turn/execute",
            )
            .with_session(Some(&native_session)),
            started_at,
            stdout_truncated,
            stderr_truncated,
        );
    }
    let turn_id = format!(
        "agy-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );
    // Antigravity exposes only the final stdout after the CLI process exits.
    // Projecting that terminal value as a chunk would falsely claim realtime
    // response evidence, so this adapter intentionally skips the chunk event.
    let events = vec![
        json!({
            "event": "agent.message.completed",
            "sessionId": native_session,
            "turnId": turn_id,
            "payload": { "text": output }
        }),
        json!({
            "event": "dispatch.turn.completed",
            "sessionId": native_session,
            "turnId": turn_id,
            "payload": { "turnStatus": "completed" }
        }),
    ];
    RunResult {
        ok: true,
        output,
        events,
        error: None,
        session_id: native_session.clone(),
        thread_id: native_session,
        turn_id,
        turn_status: "completed".to_string(),
        effective: EffectiveSettings {
            cwd: Some(workspace.display().to_string()),
            model: text_param(params, &["model"]),
            reasoning_effort: text_param(params, &["reasoningEffort", "effort"]),
            permission_mode: Some("dangerously-skip-permissions".to_string()),
            sandbox: params.get("sandbox").cloned(),
            approval_policy: params.get("approvalPolicy").cloned(),
        },
        status_code,
        stdout_truncated,
        stderr_truncated,
        started_at,
    }
}

fn resolve_workspace(params: &Value, cwd: Option<&Path>) -> PathBuf {
    params
        .get("cwd")
        .or_else(|| params.get("workingDirectory"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| cwd.map(Path::to_path_buf))
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."))
}

fn apply_optional_flags(command: &mut Command, params: &Value, workspace: &Path) {
    if let Some(model) = text_param(params, &["model"]) {
        command.arg(format!("--model={model}"));
    }
    if let Some(effort) = text_param(params, &["reasoningEffort", "effort"]) {
        command.arg(format!("--effort={effort}"));
    }
    if params.get("sandbox").and_then(Value::as_bool) == Some(true) {
        command.arg("--sandbox");
    }
    command.arg(format!("--add-dir={}", workspace.display()));
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(value) = params.get(*key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

struct BoundedRead {
    text: String,
    truncated: bool,
}

fn read_bounded(mut reader: impl Read, max_output: usize) -> BoundedRead {
    let mut buffer = vec![0u8; 8192.min(max_output.max(1))];
    let mut collected = Vec::new();
    let mut truncated = false;
    loop {
        let read = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            Err(_) => break,
        };
        if collected.len() >= max_output {
            truncated = true;
            break;
        }
        let remaining = max_output - collected.len();
        let take = read.min(remaining);
        collected.extend_from_slice(&buffer[..take]);
        if take < read {
            truncated = true;
            break;
        }
    }
    BoundedRead {
        text: String::from_utf8_lossy(&collected).into_owned(),
        truncated,
    }
}

fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}
