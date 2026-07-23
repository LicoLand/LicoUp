use super::super::process_supervisor::{BoundedStdinWriter, SupervisedChild};
use super::active_control::{ActiveTurnGuard, SteerRequest, bind};
use super::io::{TransportEvent, write_message};
use super::limits::PROCESS_POLL_INTERVAL;
use super::model::{ProtocolEffect, ProtocolFailure, ProtocolOutcome, RunResult};
use super::protocol::CodexProtocol;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TryRecvError};
use std::time::Instant;

pub(super) fn run_protocol_loop(
    stdin: &mut BoundedStdinWriter,
    receiver: &Receiver<TransportEvent>,
    control_sender: &SyncSender<SteerRequest>,
    control_receiver: &Receiver<SteerRequest>,
    protocol: &mut CodexProtocol,
    deadline: Instant,
) -> (
    Option<ProtocolOutcome>,
    Option<ProtocolFailure>,
    Option<i32>,
    bool,
) {
    let mut active_guard: Option<ActiveTurnGuard> = None;
    let mut pending_steers = HashMap::<String, SyncSender<bool>>::new();
    loop {
        if let Some((thread_id, turn_id)) = protocol.active_turn_binding() {
            if active_guard.is_none() {
                active_guard = bind(thread_id, turn_id, control_sender.clone());
                if active_guard.is_some() {
                    super::super::turn_event_emit::emit_turn_event(
                        "dispatch.turn.bound",
                        thread_id,
                        turn_id,
                        serde_json::json!({"nativeSteer": true}),
                    );
                }
            }
            loop {
                match control_receiver.try_recv() {
                    Ok(request) => {
                        let (request_id, message, acknowledged) =
                            request.into_protocol(thread_id, turn_id);
                        if write_message(stdin, &message).is_err() {
                            let _ = acknowledged.send(false);
                            return (
                                None,
                                Some(protocol.contextualize(ProtocolFailure::new(
                                    "codex_app_server_write_failed",
                                    "Codex app-server stopped accepting turn guidance.",
                                    "turn/steer",
                                ))),
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
                Some(protocol.contextualize(ProtocolFailure::new(
                    "codex_app_server_write_failed",
                    "Codex app-server stopped accepting protocol messages.",
                    "protocol/write",
                ))),
                None,
                false,
            );
        }
        let now = Instant::now();
        if now >= deadline {
            return (
                None,
                Some(protocol.contextualize(ProtocolFailure::new(
                    "codex_app_server_timeout",
                    "Codex app-server timed out before the turn completed.",
                    "turn/wait",
                ))),
                None,
                false,
            );
        }
        let wait = (deadline - now).min(PROCESS_POLL_INTERVAL);
        match receiver.recv_timeout(wait) {
            Ok(TransportEvent::Message(message)) => {
                if acknowledge_steer_response(&message, &mut pending_steers) {
                    continue;
                }
                for effect in protocol.handle_message(message) {
                    match effect {
                        ProtocolEffect::Send(message) => {
                            if write_message(stdin, &message).is_err() {
                                return (
                                    None,
                                    Some(protocol.contextualize(ProtocolFailure::new(
                                        "codex_app_server_write_failed",
                                        "Codex app-server stopped accepting protocol messages.",
                                        "protocol/write",
                                    ))),
                                    None,
                                    false,
                                );
                            }
                        }
                        ProtocolEffect::Complete(outcome) => {
                            return (Some(outcome), None, None, false);
                        }
                        ProtocolEffect::Fail(failure) => {
                            return (None, Some(protocol.contextualize(failure)), None, false);
                        }
                    }
                }
            }
            Ok(TransportEvent::InvalidJson) => {
                return read_failure(
                    protocol,
                    "codex_app_server_invalid_json",
                    "Codex app-server returned an invalid protocol message.",
                    false,
                );
            }
            Ok(TransportEvent::StdoutLimitExceeded) => {
                return read_failure(
                    protocol,
                    "codex_app_server_output_limit",
                    "Codex app-server exceeded the configured protocol output limit.",
                    true,
                );
            }
            Ok(TransportEvent::StdoutReadFailed) => {
                return read_failure(
                    protocol,
                    "codex_app_server_read_failed",
                    "Codex app-server protocol output could not be read.",
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(protocol.contextualize(ProtocolFailure::new(
                        "codex_app_server_exited",
                        "Codex app-server exited before the turn completed.",
                        "process/exit",
                    ))),
                    None,
                    false,
                );
            }
            Err(RecvTimeoutError::Timeout) => {}
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
    let accepted = message.get("error").is_none() && message.get("result").is_some();
    let _ = acknowledged.send(accepted);
    true
}

fn read_failure(
    protocol: &CodexProtocol,
    code: &'static str,
    message: &'static str,
    stdout_truncated: bool,
) -> (
    Option<ProtocolOutcome>,
    Option<ProtocolFailure>,
    Option<i32>,
    bool,
) {
    (
        None,
        Some(protocol.contextualize(ProtocolFailure::new(code, message, "protocol/read"))),
        None,
        stdout_truncated,
    )
}

pub(super) fn pipe_failure(
    child: &mut SupervisedChild,
    started_at: String,
    message: &'static str,
) -> RunResult {
    let failure = if child.terminate_tree().is_ok() {
        ProtocolFailure::new("codex_app_server_pipe_failed", message, "process/start")
    } else {
        ProtocolFailure::new(
            "codex_app_server_cleanup_failed",
            "Codex app-server process cleanup could not be completed safely.",
            "process/cleanup",
        )
    };
    RunResult::failed(failure, started_at, None, false, false)
}
