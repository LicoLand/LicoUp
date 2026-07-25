use super::control::{clear_active_turn, register_active_turn};
use super::errors::ProtocolFailure;
use super::events::{assistant_text, delta_text, is_error_result, session_id, terminal_result};
use super::io::{TransportEvent, drain_stderr, read_protocol_messages};
use super::model::{CREATE_CHAT_ARGS, PROCESS_POLL_INTERVAL, RunResult, TURN_ARGS};
use crate::platform::process_supervisor::{IO_THREAD_EXIT_GRACE, SupervisedChild, join_bounded};
use serde_json::Value;
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
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
                "cursor_cli_empty_prompt",
                "Cursor Agent CLI requires a non-empty message.",
                "request/validate",
            )
            .with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    }
    let workspace = resolve_workspace(params, cwd);
    let mut native_session = session_id.trim().to_string();
    if native_session.is_empty() {
        match create_chat_session(executable, &workspace, timeout_ms, max_stdout) {
            Ok(created) => native_session = created,
            Err(failure) => {
                return RunResult::failed(failure, started_at, false, false);
            }
        }
    }
    run_turn(
        executable,
        params,
        prompt,
        &native_session,
        &workspace,
        timeout_ms,
        max_stdout,
        max_stderr,
        started_at,
    )
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

fn create_chat_session(
    executable: &str,
    workspace: &Path,
    timeout_ms: u64,
    max_output: usize,
) -> Result<String, ProtocolFailure> {
    let mut command = Command::new(executable);
    command
        .args(CREATE_CHAT_ARGS)
        .current_dir(workspace)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = SupervisedChild::spawn(&mut command).map_err(|_| {
        ProtocolFailure::new(
            "cursor_cli_start_failed",
            "Cursor Agent CLI could not be started.",
            "process/start",
        )
    })?;
    let Some(stdout) = child.stdout() else {
        let _ = child.terminate_tree();
        return Err(ProtocolFailure::new(
            "cursor_cli_start_failed",
            "Cursor Agent CLI stdout is unavailable.",
            "process/start",
        ));
    };
    let Some(stderr) = child.stderr() else {
        let _ = child.terminate_tree();
        return Err(ProtocolFailure::new(
            "cursor_cli_start_failed",
            "Cursor Agent CLI stderr is unavailable.",
            "process/start",
        ));
    };
    let stdout_handle = thread::spawn(move || read_bounded(stdout, max_output));
    let stderr_handle = thread::spawn(move || read_bounded(stderr, max_output));
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    while (!stdout_handle.is_finished() || !stderr_handle.is_finished())
        && Instant::now() < deadline
    {
        thread::sleep(PROCESS_POLL_INTERVAL);
    }
    let timed_out = !stdout_handle.is_finished() || !stderr_handle.is_finished();
    let status = child.terminate_tree().ok().flatten();
    let stdout = join_bounded(stdout_handle, IO_THREAD_EXIT_GRACE).ok();
    let stderr = join_bounded(stderr_handle, IO_THREAD_EXIT_GRACE).ok();
    if timed_out {
        return Err(ProtocolFailure::new(
            "cursor_cli_create_chat_timeout",
            "Cursor Agent CLI timed out while creating a chat session.",
            "session/new",
        ));
    }
    if !status.is_some_and(|value| value.success()) {
        return Err(ProtocolFailure::new(
            "cursor_cli_create_chat_failed",
            "Cursor Agent CLI could not create a chat session.",
            "session/new",
        ));
    }
    let stdout = stdout.ok_or_else(|| {
        ProtocolFailure::new(
            "cursor_cli_create_chat_failed",
            "Cursor Agent CLI did not return a chat session identifier.",
            "session/new",
        )
    })?;
    if stdout.truncated || stderr.is_some_and(|value| value.truncated) {
        return Err(ProtocolFailure::new(
            "cursor_cli_create_chat_failed",
            "Cursor Agent CLI create-chat output exceeded the bounded read limit.",
            "session/new",
        ));
    }
    let session_id = stdout
        .text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .ok_or_else(|| {
            ProtocolFailure::new(
                "cursor_cli_create_chat_failed",
                "Cursor Agent CLI did not return a chat session identifier.",
                "session/new",
            )
        })?;
    if !super::control::safe_session_id(session_id) {
        return Err(ProtocolFailure::new(
            "cursor_cli_create_chat_invalid",
            "Cursor Agent CLI returned an invalid chat session identifier.",
            "session/new",
        ));
    }
    Ok(session_id.to_string())
}

fn run_turn(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    workspace: &Path,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
    started_at: String,
) -> RunResult {
    let mut command = Command::new(executable);
    command
        .args(TURN_ARGS)
        .arg("--workspace")
        .arg(workspace)
        .arg("--resume")
        .arg(session_id)
        .arg(prompt)
        .current_dir(workspace)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    apply_optional_turn_flags(&mut command, params);
    let mut child = match SupervisedChild::spawn(&mut command) {
        Ok(child) => child,
        Err(_) => {
            return RunResult::failed(
                ProtocolFailure::new(
                    "cursor_cli_start_failed",
                    "Cursor Agent CLI could not be started.",
                    "process/start",
                )
                .with_session(Some(session_id)),
                started_at,
                false,
                false,
            );
        }
    };
    register_active_turn(session_id, child.pid());
    let Some(stdout) = child.stdout() else {
        clear_active_turn(session_id);
        let _ = child.terminate_tree();
        return RunResult::failed(
            ProtocolFailure::new(
                "cursor_cli_start_failed",
                "Cursor Agent CLI stdout is unavailable.",
                "process/start",
            )
            .with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    };
    let Some(stderr) = child.stderr() else {
        clear_active_turn(session_id);
        let _ = child.terminate_tree();
        return RunResult::failed(
            ProtocolFailure::new(
                "cursor_cli_start_failed",
                "Cursor Agent CLI stderr is unavailable.",
                "process/start",
            )
            .with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    };
    let (sender, receiver) = mpsc::channel();
    let stdout_handle =
        thread::spawn(move || read_protocol_messages(BufReader::new(stdout), sender));
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || {
        let mut truncated = false;
        drain_stderr(stderr, max_stderr, &mut truncated);
        if truncated {
            stderr_flag.store(true, Ordering::Relaxed);
        }
    });
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let (outcome, failure, stdout_truncated) = consume_turn_stream(
        &receiver, session_id, &workspace, params, deadline, max_stdout,
    );
    let _ = child.finish_or_terminate_tree(Duration::from_millis(250));
    let _ = join_bounded(stdout_handle, IO_THREAD_EXIT_GRACE);
    let _ = join_bounded(stderr_handle, IO_THREAD_EXIT_GRACE);
    clear_active_turn(session_id);
    let stderr_was_truncated = stderr_truncated.load(Ordering::Relaxed);
    if let Some(outcome) = outcome {
        return RunResult {
            ok: true,
            output: outcome.output,
            events: outcome.events,
            error: None,
            thread_id: outcome.session_id.clone(),
            session_id: outcome.session_id,
            turn_id: outcome.turn_id,
            turn_status: outcome.turn_status,
            effective: outcome.effective,
            status_code: None,
            stdout_truncated,
            stderr_truncated: stderr_was_truncated,
            started_at,
        };
    }
    RunResult::failed(
        failure.unwrap_or_else(|| {
            ProtocolFailure::new(
                "cursor_cli_turn_failed",
                "Cursor Agent CLI did not complete the requested turn.",
                "turn/completed",
            )
            .with_session(Some(session_id))
        }),
        started_at,
        stdout_truncated,
        stderr_was_truncated,
    )
}

struct TurnOutcome {
    output: String,
    events: Vec<Value>,
    session_id: String,
    turn_id: String,
    turn_status: String,
    effective: super::model::EffectiveSettings,
}

fn effective_settings(
    params: &Value,
    workspace: &Path,
    events: &[Value],
) -> super::model::EffectiveSettings {
    let mut effective = super::model::EffectiveSettings {
        cwd: Some(workspace.to_string_lossy().into_owned()),
        ..Default::default()
    };
    if let Some(model) = params
        .get("model")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        effective.model = Some(model.to_string());
    }
    if let Some(effort) = params
        .get("reasoningEffort")
        .or_else(|| params.get("reasoning_effort"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        effective.reasoning_effort = Some(effort.to_string());
    }
    for message in events {
        let is_init = message.get("subtype").and_then(Value::as_str) == Some("init")
            || message.get("type").and_then(Value::as_str) == Some("init");
        if !is_init {
            continue;
        }
        if let Some(model) = message
            .get("model")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        {
            effective.model = Some(model.to_string());
        }
        if let Some(mode) = message
            .get("permissionMode")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        {
            effective.permission_mode = Some(mode.to_string());
        }
    }
    effective
}

fn consume_turn_stream(
    receiver: &mpsc::Receiver<TransportEvent>,
    requested_session: &str,
    workspace: &Path,
    params: &Value,
    deadline: Instant,
    max_stdout: usize,
) -> (Option<TurnOutcome>, Option<ProtocolFailure>, bool) {
    let mut events = Vec::new();
    let mut chunks = String::new();
    let mut output = String::new();
    let mut observed_session = requested_session.to_string();
    let mut stdout_bytes = 0usize;
    let stdout_truncated = false;
    let mut turn_id = String::new();
    loop {
        if Instant::now() >= deadline {
            return (
                None,
                Some(
                    ProtocolFailure::new(
                        "cursor_cli_timeout",
                        "Cursor Agent CLI timed out before the turn completed.",
                        "turn/wait",
                    )
                    .with_session(Some(&observed_session)),
                ),
                stdout_truncated,
            );
        }
        match receiver.recv_timeout(PROCESS_POLL_INTERVAL) {
            Ok(TransportEvent::Message { message, bytes }) => {
                stdout_bytes = stdout_bytes.saturating_add(bytes);
                if stdout_bytes > max_stdout {
                    return (
                        None,
                        Some(
                            ProtocolFailure::new(
                                "cursor_cli_output_limit",
                                "Cursor Agent CLI output exceeded the bounded read limit.",
                                "turn/read",
                            )
                            .with_session(Some(&observed_session)),
                        ),
                        true,
                    );
                }
                events.push(message.clone());
                if let Some(id) = session_id(&message) {
                    observed_session = id.to_string();
                }
                if let Some(delta) = delta_text(&message) {
                    chunks.push_str(delta);
                    if turn_id.is_empty() {
                        turn_id = message
                            .get("uuid")
                            .or_else(|| message.get("turn_id"))
                            .and_then(Value::as_str)
                            .unwrap_or("cursor-turn")
                            .to_string();
                    }
                    super::super::turn_event_emit::emit_agent_message_chunk(
                        &observed_session,
                        &turn_id,
                        delta,
                    );
                }
                if let Some(text) = assistant_text(&message) {
                    if !text.is_empty() {
                        output = text.clone();
                        if turn_id.is_empty() {
                            turn_id = message
                                .get("uuid")
                                .or_else(|| message.get("turn_id"))
                                .and_then(Value::as_str)
                                .unwrap_or("cursor-turn")
                                .to_string();
                        }
                        super::super::turn_event_emit::emit_agent_message_chunk(
                            &observed_session,
                            &turn_id,
                            &text,
                        );
                    }
                }
                if let Some(result) = terminal_result(&message) {
                    if is_error_result(&message) {
                        return (
                            None,
                            Some(
                                ProtocolFailure::new(
                                    "cursor_cli_turn_failed",
                                    "Cursor Agent CLI reported a failed turn result.",
                                    "turn/completed",
                                )
                                .with_session(Some(&observed_session)),
                            ),
                            stdout_truncated,
                        );
                    }
                    if output.is_empty() {
                        output = result.to_string();
                    }
                    if turn_id.is_empty() {
                        turn_id = message
                            .get("uuid")
                            .or_else(|| message.get("turn_id"))
                            .and_then(Value::as_str)
                            .unwrap_or("cursor-turn")
                            .to_string();
                    }
                    let final_output = if output.is_empty() {
                        chunks.clone()
                    } else {
                        output.clone()
                    };
                    let effective = effective_settings(params, workspace, &events);
                    super::super::turn_event_emit::emit_agent_message_completed(
                        &observed_session,
                        &turn_id,
                        &final_output,
                    );
                    return (
                        Some(TurnOutcome {
                            output: final_output,
                            events,
                            session_id: observed_session,
                            turn_id,
                            turn_status: "completed".to_string(),
                            effective,
                        }),
                        None,
                        stdout_truncated,
                    );
                }
            }
            Ok(TransportEvent::InvalidJson) => {
                return (
                    None,
                    Some(
                        ProtocolFailure::new(
                            "cursor_cli_invalid_json",
                            "Cursor Agent CLI returned invalid stream-json output.",
                            "turn/read",
                        )
                        .with_session(Some(&observed_session)),
                    ),
                    stdout_truncated,
                );
            }
            Ok(TransportEvent::LineLimitExceeded) => {
                return (
                    None,
                    Some(
                        ProtocolFailure::new(
                            "cursor_cli_output_limit",
                            "Cursor Agent CLI output exceeded the bounded read limit.",
                            "turn/read",
                        )
                        .with_session(Some(&observed_session)),
                    ),
                    true,
                );
            }
            Ok(TransportEvent::StdoutReadFailed) => {
                return (
                    None,
                    Some(
                        ProtocolFailure::new(
                            "cursor_cli_read_failed",
                            "Cursor Agent CLI output could not be read.",
                            "turn/read",
                        )
                        .with_session(Some(&observed_session)),
                    ),
                    stdout_truncated,
                );
            }
            Ok(TransportEvent::StdoutClosed) => break,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
    if !output.is_empty() || !chunks.is_empty() {
        let effective = effective_settings(params, workspace, &events);
        let final_output = if output.is_empty() {
            chunks.clone()
        } else {
            output.clone()
        };
        let resolved_turn_id = if turn_id.is_empty() {
            "cursor-turn".to_string()
        } else {
            turn_id.clone()
        };
        super::super::turn_event_emit::emit_agent_message_completed(
            &observed_session,
            &resolved_turn_id,
            &final_output,
        );
        return (
            Some(TurnOutcome {
                output: final_output,
                events,
                session_id: observed_session,
                turn_id: resolved_turn_id,
                turn_status: "completed".to_string(),
                effective,
            }),
            None,
            stdout_truncated,
        );
    }
    (
        None,
        Some(
            ProtocolFailure::new(
                "cursor_cli_turn_failed",
                "Cursor Agent CLI did not return a final turn result.",
                "turn/completed",
            )
            .with_session(Some(&observed_session)),
        ),
        stdout_truncated,
    )
}

fn apply_optional_turn_flags(command: &mut Command, params: &Value) {
    if let Some(model) = params
        .get("model")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        command.arg("--model").arg(model);
    }
    if let Some(effort) = params
        .get("reasoningEffort")
        .or_else(|| params.get("reasoning_effort"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        command.arg("--reasoning-effort").arg(effort);
    }
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
