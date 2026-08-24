use super::control::{clear_active_turn, register_active_turn};
use super::errors::ProtocolFailure;
use super::io::{TransportEvent, drain_stderr, read_protocol_messages};
use super::model::{CREATE_CHAT_ARGS, PROCESS_POLL_INTERVAL, RunResult, TURN_ARGS};
use super::update_watcher::{
    AgentUpdateWatcher, UPDATE_WATCH_INTERVAL, UpdateChange, UpdatePhase, cursor_agent_install_dir,
};
use crate::platform::process_supervisor::{IO_THREAD_EXIT_GRACE, SupervisedChild, join_bounded};
use crate::platform::turn_event_emit::emit_turn_event;
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
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> RunResult {
    let started_at = timestamp();
    if params
        .get("privateInstructions")
        .or_else(|| params.get("private_instructions"))
        .and_then(Value::as_str)
        .is_some_and(|value| !value.trim().is_empty())
    {
        return RunResult::failed(
            ProtocolFailure::new(
                "cursor_cli_private_instructions_unsupported",
                "Cursor Agent CLI does not expose a separate private instruction channel.",
                "capability/instructions",
            )
            .with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    }
    // timeoutMs 0 opts out of any turn deadline (see runtime_adapters/dispatch):
    // the agent runs until the turn completes, however long that takes. A
    // non-zero window covers the whole turn, including the session-creation
    // phase, so create-chat time is charged against the caller's deadline
    // instead of silently stacking on top of it.
    let deadline = (timeout_ms != 0).then(|| Instant::now() + Duration::from_millis(timeout_ms));
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
    let Some(workspace) = resolve_workspace(params, cwd) else {
        return RunResult::failed(
            ProtocolFailure::new(
                "cursor_cli_workspace_unavailable",
                "Cursor Agent CLI needs one bounded absolute project directory.",
                "request/validate",
            )
            .with_session(Some(session_id)),
            started_at,
            false,
            false,
        );
    };
    let mut native_session = session_id.trim().to_string();
    if native_session.is_empty() {
        emit_turn_event(
            "agent.turn.processing",
            "",
            "",
            serde_json::json!({
                "evidenceKind": "tool",
                "toolName": "create-chat",
                "text": "creating native chat session",
            }),
        );
        match create_chat_session(executable, &workspace, timeout_ms, max_stdout) {
            Ok(created) => {
                native_session = created;
                emit_turn_event(
                    "dispatch.turn.bound",
                    &native_session,
                    "",
                    serde_json::json!({}),
                );
            }
            Err(failure) => {
                // A caller deadline that expires during create-chat still
                // belongs to the whole turn. Preserve the create-specific
                // timeout only for the independent 60s safety bound; when
                // the caller's own deadline fired, report the same turn
                // timeout used by the execution phase.
                if failure.code == "cursor_cli_create_chat_timeout"
                    && deadline.is_some_and(|deadline| Instant::now() >= deadline)
                {
                    return RunResult::failed(
                        ProtocolFailure::new(
                            "cursor_cli_timeout",
                            "Cursor Agent CLI exhausted the turn timeout while creating the chat session.",
                            "turn/execute",
                        ),
                        started_at,
                        false,
                        false,
                    );
                }
                return RunResult::failed(failure, started_at, false, false);
            }
        }
    }
    // The turn phase may not start past the caller's deadline: if the
    // session-creation phase consumed the whole window, fail up front instead
    // of starting a turn that can only time out.
    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        return RunResult::failed(
            ProtocolFailure::new(
                "cursor_cli_timeout",
                "Cursor Agent CLI exhausted the turn timeout while creating the chat session.",
                "turn/execute",
            )
            .with_session(Some(&native_session)),
            started_at,
            false,
            false,
        );
    }
    run_turn(
        executable,
        params,
        prompt,
        &native_session,
        &workspace,
        deadline,
        max_stdout,
        max_stderr,
        started_at,
    )
}

/// The caller resolves one bounded workspace before dispatch, so its value wins
/// over the raw request. The client-owned default keeps a direct driver call
/// from indexing whatever directory the client process happens to run in.
///
/// Every candidate passes the same bounded-workspace rule. A relative path is
/// never used: `cursor-agent` resolves it against the client process directory
/// and then indexes and trusts that tree, which is how a turn ends up walking
/// the whole home directory.
fn resolve_workspace(params: &Value, cwd: Option<&Path>) -> Option<PathBuf> {
    let requested = cwd.map(Path::to_path_buf).or_else(|| {
        params
            .get("cwd")
            .or_else(|| params.get("workingDirectory"))
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from)
    });
    crate::platform::agent_workspace::resolve_local_agent_workspace("cursor", requested.as_deref())
        .filter(|workspace| workspace.is_absolute())
}

fn create_chat_session(
    executable: &str,
    workspace: &Path,
    timeout_ms: u64,
    max_output: Option<usize>,
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
    let deadline = if timeout_ms == 0 {
        None
    } else {
        Some(Instant::now() + Duration::from_millis(timeout_ms))
    };
    while (!stdout_handle.is_finished() || !stderr_handle.is_finished())
        && deadline.is_none_or(|deadline| Instant::now() < deadline)
    {
        thread::sleep(PROCESS_POLL_INTERVAL);
    }
    let timed_out =
        deadline.is_some() && (!stdout_handle.is_finished() || !stderr_handle.is_finished());
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
    let session_id =
        crate::platform::native_agent_parser::adapters::cursor::parse_created_session(&stdout.text)
            .map_err(|kind| {
                use crate::platform::native_agent_parser::adapters::cursor::CreatedSessionFailure;
                match kind {
                    CreatedSessionFailure::Missing => ProtocolFailure::new(
                        "cursor_cli_create_chat_failed",
                        "Cursor Agent CLI did not return a chat session identifier.",
                        "session/new",
                    ),
                    CreatedSessionFailure::Invalid => ProtocolFailure::new(
                        "cursor_cli_create_chat_invalid",
                        "Cursor Agent CLI returned an invalid chat session identifier.",
                        "session/new",
                    ),
                }
            })?;
    Ok(session_id)
}

fn run_turn(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    workspace: &Path,
    deadline: Option<Instant>,
    max_stdout: Option<usize>,
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
        .stderr(Stdio::piped());
    apply_optional_turn_flags(&mut command, params);
    let (mut child, stdout) = match spawn_turn_transport(command) {
        Ok(transport) => transport,
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
    // The deadline already spans the whole turn, including any create-chat
    // phase, so the turn phase simply keeps consuming the same window.
    let (outcome, failure, stdout_truncated) = consume_turn_stream(
        &receiver,
        session_id,
        &workspace,
        params,
        deadline,
        max_stdout,
        child.pid(),
    );
    let status = child
        .finish_or_terminate_tree(Duration::from_millis(250))
        .ok()
        .flatten();
    let _ = join_bounded(stdout_handle, IO_THREAD_EXIT_GRACE);
    let _ = join_bounded(stderr_handle, IO_THREAD_EXIT_GRACE);
    clear_active_turn(session_id);
    let stderr_was_truncated = stderr_truncated.load(Ordering::Relaxed);
    if let Some(outcome) = outcome {
        let transitions =
            crate::platform::native_agent_parser::adapters::cursor::completed_transitions(
                &outcome.output,
            );
        return RunResult {
            ok: true,
            output: outcome.output,
            transitions,
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
    if let Some(failure) = failure {
        return RunResult::failed(failure, started_at, stdout_truncated, stderr_was_truncated);
    }
    // consume_turn_stream returned no outcome and no protocol failure: stdout
    // closed before a terminal result arrived (cancel, crash, or early exit).
    // Partial output was already streamed live as chunk events; the exit
    // status decides how the truncated turn is reported.
    #[cfg(unix)]
    {
        use libc::SIGTERM;
        use std::os::unix::process::ExitStatusExt;
        if status.is_some_and(|status| status.signal() == Some(SIGTERM)) {
            return RunResult::failed(
                ProtocolFailure::new(
                    "cursor_cli_cancelled",
                    "Cursor Agent CLI turn was cancelled.",
                    "turn/cancelled",
                )
                .with_session(Some(session_id))
                .with_turn_status("cancelled"),
                started_at,
                stdout_truncated,
                stderr_was_truncated,
            );
        }
    }
    if !status.is_some_and(|status| status.success()) {
        return RunResult::failed(
            ProtocolFailure::new(
                "cursor_cli_turn_failed",
                "Cursor Agent CLI exited without completing the turn.",
                "turn/completed",
            )
            .with_session(Some(session_id)),
            started_at,
            stdout_truncated,
            stderr_was_truncated,
        );
    }
    RunResult::failed(
        ProtocolFailure::new(
            "cursor_cli_turn_failed",
            "Cursor Agent CLI did not complete the requested turn.",
            "turn/completed",
        )
        .with_session(Some(session_id)),
        started_at,
        stdout_truncated,
        stderr_was_truncated,
    )
}

/// Spawns the turn subprocess with stdin+stdout on a pty slave so the CLI
/// sees a real terminal while `stream-json` NDJSON output stays line-faithful
/// (raw mode keeps `\n` only); stderr remains a real pipe so the protocol
/// parser never sees stderr noise.
#[cfg(unix)]
fn spawn_turn_transport(
    command: Command,
) -> std::io::Result<(SupervisedChild, crate::platform::pty_transport::Master)> {
    crate::platform::pty_transport::spawn(command)
}

#[cfg(not(unix))]
fn spawn_turn_transport(
    command: Command,
) -> std::io::Result<(SupervisedChild, std::process::ChildStdout)> {
    let mut command = command;
    command.stdin(Stdio::null()).stdout(Stdio::piped());
    let mut child = SupervisedChild::spawn(&mut command)?;
    let stdout = child
        .stdout()
        .ok_or_else(|| std::io::Error::other("Cursor Agent CLI stdout is unavailable."))?;
    Ok((child, stdout))
}

struct ProtocolFinishReport {
    output: String,
    session_id: String,
    turn_id: String,
    turn_status: String,
    effective: super::model::EffectiveSettings,
}

fn initial_effective_settings(params: &Value, workspace: &Path) -> super::model::EffectiveSettings {
    let mut effective = super::model::EffectiveSettings {
        cwd: Some(workspace.to_string_lossy().into_owned()),
        ..Default::default()
    };
    if let Some(model) = params
        .get("model")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        effective.model = Some(model.to_owned());
    }
    if let Some(effort) = params
        .get("reasoningEffort")
        .or_else(|| params.get("reasoning_effort"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        effective.reasoning_effort = Some(effort.to_owned());
    }
    effective
}

fn consume_turn_stream(
    receiver: &mpsc::Receiver<TransportEvent>,
    requested_session: &str,
    workspace: &Path,
    params: &Value,
    deadline: Option<Instant>,
    max_stdout: Option<usize>,
    root_pid: u32,
) -> (Option<ProtocolFinishReport>, Option<ProtocolFailure>, bool) {
    use crate::platform::native_agent_parser::adapters::cursor::{
        CursorEffect, CursorParseFailure, CursorParser,
    };

    let mut parser = CursorParser::new(
        requested_session,
        initial_effective_settings(params, workspace),
    );
    let mut stdout_bytes = 0usize;
    let mut update_watcher = AgentUpdateWatcher::new(cursor_agent_install_dir());
    let mut last_update_watch: Option<Instant> = None;
    loop {
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            return (
                None,
                Some(
                    ProtocolFailure::new(
                        "cursor_cli_timeout",
                        "Cursor Agent CLI timed out before the turn completed.",
                        "turn/wait",
                    )
                    .with_session(Some(parser.session_id())),
                ),
                false,
            );
        }
        match receiver.recv_timeout(PROCESS_POLL_INTERVAL) {
            Ok(TransportEvent::Line(line)) => {
                stdout_bytes = stdout_bytes.saturating_add(line.len());
                if max_stdout.is_some_and(|limit| stdout_bytes > limit) {
                    return (
                        None,
                        Some(
                            ProtocolFailure::new(
                                "cursor_cli_output_limit",
                                "Cursor Agent CLI output exceeded the bounded read limit.",
                                "turn/read",
                            )
                            .with_session(Some(parser.session_id())),
                        ),
                        true,
                    );
                }
                let effects = match parser.parse_line(&line) {
                    Ok(effects) => effects,
                    Err(kind) => {
                        let (code, message, stage) = match kind {
                            CursorParseFailure::InvalidJson => (
                                "cursor_cli_invalid_json",
                                "Cursor Agent CLI returned invalid stream-json output.",
                                "turn/read",
                            ),
                            CursorParseFailure::TextSnapshotDiverged => (
                                "cursor_cli_text_snapshot_diverged",
                                "Cursor Agent CLI returned a divergent assistant snapshot.",
                                "turn/read",
                            ),
                            CursorParseFailure::TurnFailed => (
                                "cursor_cli_turn_failed",
                                "Cursor Agent CLI reported a failed turn result.",
                                "turn/completed",
                            ),
                        };
                        return (
                            None,
                            Some(
                                ProtocolFailure::new(code, message, stage)
                                    .with_session(Some(parser.session_id())),
                            ),
                            false,
                        );
                    }
                };
                for effect in effects {
                    match effect {
                        CursorEffect::Accepted {
                            session_id,
                            turn_id,
                        } => {
                            emit_turn_event(
                                "agent.turn.accepted",
                                &session_id,
                                &turn_id,
                                serde_json::json!({"evidenceKind": "native-event"}),
                            );
                        }
                        CursorEffect::Text {
                            session_id,
                            turn_id,
                            text,
                        } => {
                            super::super::turn_event_emit::emit_agent_message_chunk(
                                &session_id,
                                &turn_id,
                                &text,
                            );
                        }
                        CursorEffect::Complete(outcome) => {
                            super::super::turn_event_emit::emit_agent_message_completed(
                                &outcome.session_id,
                                &outcome.turn_id,
                                &outcome.output,
                            );
                            return (
                                Some(ProtocolFinishReport {
                                    output: outcome.output,
                                    session_id: outcome.session_id,
                                    turn_id: outcome.turn_id,
                                    turn_status: "completed".to_owned(),
                                    effective: outcome.effective,
                                }),
                                None,
                                false,
                            );
                        }
                    }
                }
            }
            Ok(TransportEvent::UnterminatedLine) => {
                return (
                    None,
                    Some(
                        ProtocolFailure::new(
                            "cursor_cli_unterminated_json",
                            "Cursor Agent CLI returned an unterminated stream-json line.",
                            "turn/read",
                        )
                        .with_session(Some(parser.session_id())),
                    ),
                    false,
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
                        .with_session(Some(parser.session_id())),
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
                        .with_session(Some(parser.session_id())),
                    ),
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let now = Instant::now();
                if last_update_watch
                    .is_none_or(|last| now.duration_since(last) >= UPDATE_WATCH_INTERVAL)
                {
                    last_update_watch = Some(now);
                    if let Some(change) = update_watcher.watch(root_pid) {
                        emit_update_change(&change, parser.session_id(), "");
                    }
                }
            }
        }
    }
    (None, None, false)
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

fn read_bounded(mut reader: impl Read, max_output: Option<usize>) -> BoundedRead {
    // None means unbounded: read everything the agent produces.
    let max_output = max_output.unwrap_or(usize::MAX);
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

/// Surfaces a cursor-agent auto-update transition as a streaming event.
///
/// `turn_id` may still be empty here (the update blocks the first NDJSON
/// frame); the client keys the card by its own live turn id, never by the
/// transport turn id.
fn emit_update_change(change: &UpdateChange, session_id: &str, turn_id: &str) {
    let payload = |version: &Option<String>, phase: Option<UpdatePhase>| {
        serde_json::json!({
            "artifact": "cursor-agent",
            "version": version.clone().unwrap_or_default(),
            "phase": phase.map(UpdatePhase::as_str).unwrap_or_default(),
        })
    };
    match change {
        UpdateChange::Started { version, phase } | UpdateChange::Phase { version, phase } => {
            super::super::turn_event_emit::emit_turn_event(
                "agent.runtime.updating",
                session_id,
                turn_id,
                payload(version, Some(*phase)),
            );
        }
        UpdateChange::Completed { version } => {
            super::super::turn_event_emit::emit_turn_event(
                "agent.runtime.update.completed",
                session_id,
                turn_id,
                payload(version, None),
            );
        }
        UpdateChange::Interrupted { version } => {
            super::super::turn_event_emit::emit_turn_event(
                "agent.runtime.update.interrupted",
                session_id,
                turn_id,
                serde_json::json!({
                    "artifact": "cursor-agent",
                    "version": version.clone().unwrap_or_default(),
                    "hint": "stale-lock-removed",
                }),
            );
        }
    }
}

fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}
