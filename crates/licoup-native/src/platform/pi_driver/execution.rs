use super::super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
};
use super::active_control::{ActiveTurnGuard, SteerRequest, bind};
use super::errors::ProtocolFailure;
use super::io::{TransportEvent, drain_stderr, read_protocol_messages, write_message};
use super::model::{PROCESS_POLL_INTERVAL, RunResult};
use super::params::ProtocolConfig;
use super::protocol::{PiProtocol, ProtocolEffect, ProtocolOutcome};
use super::supervision::LaunchSpec;
use serde_json::Value;
use std::collections::HashMap;
use std::io::{self, BufReader};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TryRecvError};
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
    let config = match ProtocolConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => return RunResult::failed(failure, started_at, None, false, false),
    };
    let launch = LaunchSpec::new(executable, Path::new(&config.cwd));
    let mut child = match launch.spawn() {
        Ok(child) => child,
        Err(error) => {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The Pi Agent executable is not available.",
                io::ErrorKind::PermissionDenied => {
                    "The Pi Agent executable is not permitted to run."
                }
                _ => "Pi RPC could not be started.",
            };
            return RunResult::failed(
                ProtocolFailure::new("pi_rpc_start_failed", message, "process/start"),
                started_at,
                None,
                false,
                false,
            );
        }
    };
    let Some(stdout) = child.stdout() else {
        return pipe_failure(&mut child, started_at, "Pi RPC stdout is unavailable.");
    };
    let Some(stderr) = child.stderr() else {
        return pipe_failure(&mut child, started_at, "Pi RPC stderr is unavailable.");
    };
    let Some(stdin) = child.stdin() else {
        return pipe_failure(&mut child, started_at, "Pi RPC stdin is unavailable.");
    };
    let mut stdin = BoundedStdinWriter::new(stdin);

    let (sender, receiver) = mpsc::channel();
    let stdout_handle =
        thread::spawn(move || read_protocol_messages(BufReader::new(stdout), max_stdout, sender));
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));

    let mut protocol = PiProtocol::new(config);
    let (control_sender, control_receiver) = mpsc::sync_channel(16);
    let initial = protocol.initial_request();
    if write_message(&mut stdin, &initial).is_err() {
        let cleanup =
            finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
        let cleanup_failed = cleanup == Err(TransportFinishFailure::Lifecycle);
        return RunResult::failed(
            ProtocolFailure::new(
                if cleanup_failed {
                    "pi_rpc_cleanup_failed"
                } else {
                    "pi_rpc_write_failed"
                },
                if cleanup_failed {
                    "Pi RPC process cleanup could not be completed safely."
                } else {
                    "Pi RPC stopped accepting protocol messages."
                },
                if cleanup_failed {
                    "process/cleanup"
                } else {
                    "protocol/write"
                },
            ),
            started_at,
            None,
            false,
            stderr_truncated.load(Ordering::Relaxed),
        );
    }

    let deadline = if timeout_ms == 0 {
        None
    } else {
        Some(Instant::now() + Duration::from_millis(timeout_ms))
    };
    let (outcome, failure, status_code, stdout_was_truncated) = run_protocol_loop(
        &mut stdin,
        &receiver,
        &control_sender,
        &control_receiver,
        &mut protocol,
        deadline,
    );

    let cleanup = finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
    let stderr_was_truncated = stderr_truncated.load(Ordering::Relaxed);

    if cleanup == Err(TransportFinishFailure::Lifecycle) {
        return RunResult::failed(
            ProtocolFailure::new(
                "pi_rpc_cleanup_failed",
                "Pi RPC process cleanup could not be completed safely.",
                "process/cleanup",
            ),
            started_at,
            status_code,
            stdout_was_truncated,
            stderr_was_truncated,
        );
    }
    if outcome.is_some() && cleanup == Err(TransportFinishFailure::StdinWrite) {
        return RunResult::failed(
            ProtocolFailure::new(
                "pi_rpc_write_failed",
                "Pi RPC stopped accepting protocol messages.",
                "protocol/write",
            ),
            started_at,
            status_code,
            stdout_was_truncated,
            stderr_was_truncated,
        );
    }

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
            status_code,
            stdout_truncated: stdout_was_truncated,
            stderr_truncated: stderr_was_truncated,
            started_at,
        };
    }
    RunResult::failed(
        failure.unwrap_or_else(|| {
            ProtocolFailure::new(
                "pi_rpc_failed",
                "Pi RPC did not complete the request.",
                "protocol",
            )
        }),
        started_at,
        status_code,
        stdout_was_truncated,
        stderr_was_truncated,
    )
}

pub(super) fn run_protocol_loop(
    stdin: &mut BoundedStdinWriter,
    receiver: &Receiver<TransportEvent>,
    control_sender: &SyncSender<SteerRequest>,
    control_receiver: &Receiver<SteerRequest>,
    protocol: &mut PiProtocol,
    deadline: Option<Instant>,
) -> (
    Option<ProtocolOutcome>,
    Option<ProtocolFailure>,
    Option<i32>,
    bool,
) {
    let mut active_guard: Option<ActiveTurnGuard> = None;
    let mut pending_steers = HashMap::<String, SyncSender<bool>>::new();
    loop {
        if let Some((session_id, turn_id)) = protocol.active_turn_binding() {
            if active_guard.is_none() {
                active_guard = bind(session_id, turn_id, control_sender.clone());
                if active_guard.is_some() {
                    super::super::turn_event_emit::emit_turn_event(
                        "dispatch.turn.bound",
                        session_id,
                        turn_id,
                        serde_json::json!({"nativeSteer": true}),
                    );
                }
            }
            loop {
                match control_receiver.try_recv() {
                    Ok(request) => {
                        let (request_id, message, acknowledged) = request.into_protocol();
                        if write_message(stdin, &message).is_err() {
                            let _ = acknowledged.send(false);
                            return (
                                None,
                                Some(protocol.failure_with_ids(
                                    "pi_rpc_write_failed",
                                    "Pi RPC stopped accepting turn guidance.",
                                    "turn/steer",
                                )),
                                None,
                                false,
                            );
                        }
                        pending_steers.insert(request_id, acknowledged);
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => break,
                }
            }
        }
        if stdin.check_health().is_err() {
            return (
                None,
                Some(protocol.failure_with_ids(
                    "pi_rpc_write_failed",
                    "Pi RPC stopped accepting protocol messages.",
                    "protocol/write",
                )),
                None,
                false,
            );
        }
        let now = Instant::now();
        if deadline.is_some_and(|deadline| now >= deadline) {
            return (
                None,
                Some(protocol.failure_with_ids(
                    "pi_rpc_timeout",
                    "Pi RPC timed out before the turn completed.",
                    "turn/wait",
                )),
                None,
                false,
            );
        }
        let wait = deadline
            .map(|deadline| (deadline - now).min(PROCESS_POLL_INTERVAL))
            .unwrap_or(PROCESS_POLL_INTERVAL);
        match receiver.recv_timeout(wait) {
            Ok(TransportEvent::Message(message)) => {
                if acknowledge_steer_response(&message, &mut pending_steers) {
                    continue;
                }
                for effect in protocol.handle_message(message) {
                    match effect {
                        ProtocolEffect::Send(payload) => {
                            if write_message(stdin, &payload).is_err() {
                                return (
                                    None,
                                    Some(protocol.failure_with_ids(
                                        "pi_rpc_write_failed",
                                        "Pi RPC stopped accepting protocol messages.",
                                        "protocol/write",
                                    )),
                                    None,
                                    false,
                                );
                            }
                        }
                        ProtocolEffect::Complete(outcome) => {
                            return (Some(outcome), None, None, false);
                        }
                        ProtocolEffect::Fail(failure) => {
                            return (None, Some(failure), None, false);
                        }
                    }
                }
            }
            Ok(TransportEvent::InvalidJson) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "pi_rpc_invalid_json",
                        "Pi RPC returned an invalid protocol frame.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutLimitExceeded) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "pi_rpc_output_limit",
                        "Pi RPC exceeded the bounded stdout limit.",
                        "protocol/read",
                    )),
                    None,
                    true,
                );
            }
            Ok(TransportEvent::StdoutReadFailed) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "pi_rpc_read_failed",
                        "Pi RPC stdout could not be read.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "pi_rpc_exited",
                        "Pi RPC exited before the turn completed.",
                        "process/exit",
                    )),
                    None,
                    false,
                );
            }
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "pi_rpc_exited",
                        "Pi RPC exited before the turn completed.",
                        "process/exit",
                    )),
                    None,
                    false,
                );
            }
        }
    }
}

fn acknowledge_steer_response(
    message: &Value,
    pending_steers: &mut HashMap<String, SyncSender<bool>>,
) -> bool {
    let Some(request_id) = message.get("id").and_then(Value::as_str) else {
        return false;
    };
    let Some(acknowledged) = pending_steers.remove(request_id) else {
        return false;
    };
    let accepted = message.get("type").and_then(Value::as_str) == Some("response")
        && message.get("success").and_then(Value::as_bool) == Some(true);
    let _ = acknowledged.send(accepted);
    true
}

pub(super) fn pipe_failure(
    child: &mut SupervisedChild,
    started_at: String,
    _message: &str,
) -> RunResult {
    let _ = child.terminate_tree();
    RunResult::failed(
        ProtocolFailure::new(
            "pi_rpc_pipe_failed",
            "Pi RPC pipes are unavailable.",
            "process/start",
        ),
        started_at,
        None,
        false,
        false,
    )
}

pub(super) fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}
