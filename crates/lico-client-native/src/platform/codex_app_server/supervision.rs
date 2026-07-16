use super::super::process_supervisor::{BoundedStdinWriter, SupervisedChild};
use super::io::{TransportEvent, write_message};
use super::limits::PROCESS_POLL_INTERVAL;
use super::model::{ProtocolEffect, ProtocolFailure, ProtocolOutcome, RunResult};
use super::protocol::CodexProtocol;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Instant;

pub(super) fn run_protocol_loop(
    stdin: &mut BoundedStdinWriter,
    receiver: &Receiver<TransportEvent>,
    protocol: &mut CodexProtocol,
    deadline: Instant,
) -> (
    Option<ProtocolOutcome>,
    Option<ProtocolFailure>,
    Option<i32>,
    bool,
) {
    loop {
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
