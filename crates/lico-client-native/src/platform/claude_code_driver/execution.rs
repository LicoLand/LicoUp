use super::control::{ControlRequest, denied_control_response, interrupt_request};
use super::errors::{ProtocolFailure, requires_transport_reset, supervisor_failure};
use super::io::{TransportEvent, write_message};
use super::model::{PROCESS_POLL_INTERVAL, RunResult};
use super::params::DriverConfig;
use super::protocol::{TurnOutcome, TurnState};
use super::supervision::{
    ManagedTransport, bind_session, lookup_session_transport, remove_transport, set_active_session,
    spawn_transport,
};
use super::transport::PersistentTransport;
use serde_json::Value;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::sync::mpsc::{RecvTimeoutError, TryRecvError};
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
    let config = match DriverConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => return RunResult::failed(failure, started_at, false, false),
    };
    let managed = if config.requested_session_id.is_empty() {
        match spawn_transport(executable, &config, cwd, max_stderr) {
            Ok(managed) => managed,
            Err(failure) => return RunResult::failed(failure, started_at, false, false),
        }
    } else {
        let Some(managed) = lookup_session_transport(&config.requested_session_id) else {
            return RunResult::failed(
                ProtocolFailure::new(
                    "claude_code_live_session_unavailable",
                    "The exact Claude Code streaming process is no longer available in this client process.",
                    "session/resume",
                )
                .with_session(Some(&config.requested_session_id))
                .with_turn(&config.turn_id),
                started_at,
                false,
                false,
            );
        };
        if !managed.identity.compatible_with(executable, &config, cwd) {
            return RunResult::failed(
                ProtocolFailure::new(
                    "claude_code_session_configuration_mismatch",
                    "The requested controls do not match the live Claude Code streaming process.",
                    "session/resume",
                )
                .with_session(Some(&config.requested_session_id))
                .with_turn(&config.turn_id),
                started_at,
                false,
                false,
            );
        }
        managed
    };
    let mut transport = match managed.transport.lock() {
        Ok(transport) => transport,
        Err(_) => {
            remove_transport(&managed, false);
            return RunResult::failed(supervisor_failure(), started_at, false, false);
        }
    };
    let known_session = managed
        .native_session_id
        .lock()
        .ok()
        .and_then(|value| value.clone());
    if !config.requested_session_id.is_empty()
        && known_session.as_deref() != Some(config.requested_session_id.as_str())
    {
        drop(transport);
        remove_transport(&managed, true);
        return RunResult::failed(
            ProtocolFailure::new(
                "claude_code_session_mismatch",
                "The live Claude Code process is not bound to the requested conversation.",
                "session/resume",
            )
            .with_session(Some(&config.requested_session_id))
            .with_turn(&config.turn_id),
            started_at,
            false,
            false,
        );
    }
    set_active_session(&managed, Some(known_session.clone().unwrap_or_default()));
    let message = match config.stdin_message() {
        Ok(message) => message,
        Err(_) => {
            set_active_session(&managed, None);
            return RunResult::failed(
                ProtocolFailure::new(
                    "claude_code_input_encode_failed",
                    "Claude Code input could not be encoded.",
                    "request/encode",
                )
                .with_turn(&config.turn_id),
                started_at,
                false,
                false,
            );
        }
    };
    let initial_write = write_message(&mut transport.stdin, &message);
    let (outcome, failure, stdout_truncated) = if initial_write.is_err() {
        (
            None,
            Some(
                ProtocolFailure::new(
                    "claude_code_write_failed",
                    "Claude Code stopped accepting streamed user messages.",
                    "protocol/write",
                )
                .with_session(known_session.as_deref())
                .with_turn(&config.turn_id),
            ),
            false,
        )
    } else {
        run_turn_loop(
            &mut transport,
            &managed,
            &config,
            known_session,
            Instant::now() + Duration::from_millis(timeout_ms),
            max_stdout,
        )
    };
    let stderr_truncated = transport.stderr_truncated.load(Ordering::Relaxed);
    set_active_session(&managed, None);
    drop(transport);
    if let Some(outcome) = outcome {
        bind_session(&managed, &outcome.session_id);
        return RunResult {
            ok: true,
            output: outcome.output,
            events: outcome.events,
            error: None,
            thread_id: outcome.session_id.clone(),
            session_id: outcome.session_id,
            turn_id: outcome.turn_id,
            turn_status: "completed".to_string(),
            effective: outcome.effective,
            status_code: None,
            stdout_truncated,
            stderr_truncated,
            started_at,
        };
    }
    let failure = failure.unwrap_or_else(|| {
        ProtocolFailure::new(
            "claude_code_turn_failed",
            "Claude Code did not complete the requested turn.",
            "turn/completed",
        )
        .with_turn(&config.turn_id)
    });
    if requires_transport_reset(&failure) {
        remove_transport(&managed, true);
    }
    RunResult::failed(failure, started_at, stdout_truncated, stderr_truncated)
}

fn run_turn_loop(
    transport: &mut PersistentTransport,
    managed: &Arc<ManagedTransport>,
    config: &DriverConfig,
    known_session: Option<String>,
    deadline: Instant,
    max_stdout: usize,
) -> (Option<TurnOutcome>, Option<ProtocolFailure>, bool) {
    let mut state = TurnState::new(config, &managed.identity, known_session);
    let mut observed_bytes = 0usize;
    loop {
        if let Some(failure) = handle_control_requests(transport, &state) {
            return (None, Some(failure), false);
        }
        if transport.stdin.check_health().is_err() {
            return (
                None,
                Some(state.failure(
                    "claude_code_write_failed",
                    "Claude Code stopped accepting streamed messages.",
                    "protocol/write",
                )),
                false,
            );
        }
        let now = Instant::now();
        if now >= deadline {
            let mut failure = state.failure(
                "claude_code_timeout",
                "Claude Code timed out before the turn completed.",
                "turn/wait",
            );
            failure.turn_status = Some("timeout".to_string());
            return (None, Some(failure), false);
        }
        match transport
            .receiver
            .recv_timeout((deadline - now).min(PROCESS_POLL_INTERVAL))
        {
            Ok(TransportEvent::Message { message, bytes }) => {
                observed_bytes = observed_bytes.saturating_add(bytes);
                if observed_bytes > max_stdout {
                    return (
                        None,
                        Some(state.failure(
                            "claude_code_output_limit",
                            "Claude Code exceeded the configured structured output limit.",
                            "protocol/read",
                        )),
                        true,
                    );
                }
                if message.get("type").and_then(Value::as_str) == Some("control_request") {
                    state.interaction_failure = true;
                    if let Some(response) = denied_control_response(&message)
                        && write_message(&mut transport.stdin, &response).is_err()
                    {
                        return (
                            None,
                            Some(state.failure(
                                "claude_code_write_failed",
                                "Claude Code stopped accepting control responses.",
                                "permission/response",
                            )),
                            false,
                        );
                    }
                }
                match state.handle(message) {
                    Ok(Some(outcome)) => return (Some(outcome), None, false),
                    Ok(None) => {
                        if let Some(session_id) = state.observed_session_id.as_deref() {
                            bind_session(managed, session_id);
                            set_active_session(managed, Some(session_id.to_string()));
                        }
                    }
                    Err(failure) => return (None, Some(failure), false),
                }
            }
            Ok(TransportEvent::InvalidJson) => {
                return (
                    None,
                    Some(state.failure(
                        "claude_code_invalid_json",
                        "Claude Code returned an invalid stream event.",
                        "protocol/read",
                    )),
                    false,
                );
            }
            Ok(TransportEvent::LineLimitExceeded) => {
                return (
                    None,
                    Some(state.failure(
                        "claude_code_output_limit",
                        "Claude Code exceeded the hard structured-event limit.",
                        "protocol/read",
                    )),
                    true,
                );
            }
            Ok(TransportEvent::StdoutReadFailed) => {
                return (
                    None,
                    Some(state.failure(
                        "claude_code_read_failed",
                        "Claude Code structured output could not be read.",
                        "protocol/read",
                    )),
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(state.failure(
                        "claude_code_exited",
                        "Claude Code exited before the turn completed.",
                        "process/exit",
                    )),
                    false,
                );
            }
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

fn handle_control_requests(
    transport: &mut PersistentTransport,
    state: &TurnState<'_>,
) -> Option<ProtocolFailure> {
    loop {
        match transport.control_receiver.try_recv() {
            Ok(ControlRequest::Cancel {
                session_id,
                acknowledged,
            }) => {
                let current = state
                    .observed_session_id
                    .as_deref()
                    .or(state.expected_session_id.as_deref());
                let matches = current == Some(session_id.as_str());
                let written =
                    matches && write_message(&mut transport.stdin, &interrupt_request()).is_ok();
                let _ = acknowledged.send(written);
                if matches && !written {
                    return Some(state.failure(
                        "claude_code_write_failed",
                        "Claude Code stopped accepting an interrupt request.",
                        "turn/cancel",
                    ));
                }
            }
            Ok(ControlRequest::Cleanup { acknowledged }) => {
                let _ = write_message(&mut transport.stdin, &interrupt_request());
                let _ = acknowledged.send(true);
                return Some(state.failure(
                    "claude_code_cleanup_requested",
                    "Claude Code transport cleanup was requested.",
                    "process/cleanup",
                ));
            }
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => {
                return Some(state.failure(
                    "claude_code_supervisor_unavailable",
                    "Claude Code supervisor control channel is unavailable.",
                    "process/supervisor",
                ));
            }
        }
    }
}

pub(super) fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}
