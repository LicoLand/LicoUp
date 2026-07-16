use super::super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
};
use super::errors::ProtocolFailure;
use super::io::{TransportEvent, drain_stderr, read_protocol_messages, write_message};
use super::model::{PROCESS_POLL_INTERVAL, RunResult};
use super::params::ProtocolConfig;
use super::protocol::{OpenClawProtocol, ProtocolEffect, ProtocolOutcome};
use super::supervision::{LaunchSpec, attach_mode, resolve_gateway_endpoint};
use serde_json::{Value, json};
use std::io::{self, BufReader};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
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
    let config = match ProtocolConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => return RunResult::failed(failure, started_at, None, false, false),
    };
    let gateway = match resolve_gateway_endpoint(executable, params) {
        Ok(endpoint) => endpoint,
        Err(failure) => return RunResult::failed(failure, started_at, None, false, false),
    };
    super::super::turn_event_emit::emit_turn_event(
        "dispatch.gateway.attached",
        config.native_session_key.as_deref().unwrap_or(""),
        &config.turn_id,
        json!({
            "wsUrlHostClass": "loopback",
            "port": gateway.port,
            "attachMode": attach_mode(gateway.port)
        }),
    );
    let launch =
        LaunchSpec::for_gateway_attach(executable, Path::new(&config.cwd), &gateway.ws_url);
    let mut child = match launch.spawn() {
        Ok(child) => child,
        Err(error) => {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The OpenClaw executable is not available.",
                io::ErrorKind::PermissionDenied => {
                    "The OpenClaw executable is not permitted to run."
                }
                _ => "OpenClaw ACP could not be started against the Gateway.",
            };
            return RunResult::failed(
                ProtocolFailure::new("openclaw_acp_start_failed", message, "process/start"),
                started_at,
                None,
                false,
                false,
            );
        }
    };
    let Some(stdout) = child.stdout() else {
        return pipe_failure(
            &mut child,
            started_at,
            "OpenClaw ACP stdout is unavailable.",
        );
    };
    let Some(stderr) = child.stderr() else {
        return pipe_failure(
            &mut child,
            started_at,
            "OpenClaw ACP stderr is unavailable.",
        );
    };
    let Some(stdin) = child.stdin() else {
        return pipe_failure(&mut child, started_at, "OpenClaw ACP stdin is unavailable.");
    };
    let mut stdin = BoundedStdinWriter::new(stdin);

    let (sender, receiver) = mpsc::channel();
    let stdout_handle =
        thread::spawn(move || read_protocol_messages(BufReader::new(stdout), max_stdout, sender));
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));

    let mut protocol = OpenClawProtocol::new(config);
    let initial_request = match protocol.initial_request() {
        Ok(request) => request,
        Err(failure) => {
            let cleanup =
                finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
            let cleanup_failed = cleanup == Err(TransportFinishFailure::Lifecycle);
            return RunResult::failed(
                if cleanup_failed {
                    ProtocolFailure::new(
                        "openclaw_acp_cleanup_failed",
                        "OpenClaw ACP process cleanup could not be completed safely.",
                        "process/cleanup",
                    )
                } else {
                    failure
                },
                started_at,
                None,
                false,
                stderr_truncated.load(Ordering::Relaxed),
            );
        }
    };
    if write_message(&mut stdin, &initial_request).is_err() {
        let cleanup =
            finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
        let cleanup_failed = cleanup == Err(TransportFinishFailure::Lifecycle);
        return RunResult::failed(
            ProtocolFailure::new(
                if cleanup_failed {
                    "openclaw_acp_cleanup_failed"
                } else {
                    "openclaw_acp_write_failed"
                },
                if cleanup_failed {
                    "OpenClaw ACP process cleanup could not be completed safely."
                } else {
                    "OpenClaw ACP stopped accepting protocol messages."
                },
                if cleanup_failed {
                    "process/cleanup"
                } else {
                    "initialize"
                },
            ),
            started_at,
            None,
            false,
            stderr_truncated.load(Ordering::Relaxed),
        );
    }

    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let (outcome, failure, status_code, stdout_was_truncated) =
        run_protocol_loop(&mut stdin, &receiver, &mut protocol, deadline);

    let cleanup = finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
    let stderr_was_truncated = stderr_truncated.load(Ordering::Relaxed);

    if cleanup == Err(TransportFinishFailure::Lifecycle) {
        return RunResult::failed(
            ProtocolFailure::new(
                "openclaw_acp_cleanup_failed",
                "OpenClaw ACP process cleanup could not be completed safely.",
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
                "openclaw_acp_write_failed",
                "OpenClaw ACP stopped accepting protocol messages.",
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
                "openclaw_acp_failed",
                "OpenClaw ACP did not complete the request.",
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
    protocol: &mut OpenClawProtocol,
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
                Some(protocol.failure_with_ids(
                    "openclaw_acp_write_failed",
                    "OpenClaw ACP stopped accepting protocol messages.",
                    "protocol/write",
                )),
                None,
                false,
            );
        }
        let now = Instant::now();
        if now >= deadline {
            let mut failure = protocol.failure_with_ids(
                "openclaw_acp_timeout",
                "OpenClaw ACP timed out before the turn completed.",
                "turn/wait",
            );
            failure.turn_status = Some("timeout".to_string());
            return (None, Some(failure), None, false);
        }
        match receiver.recv_timeout((deadline - now).min(PROCESS_POLL_INTERVAL)) {
            Ok(TransportEvent::Message(message)) => {
                for effect in protocol.handle_message(message) {
                    match effect {
                        ProtocolEffect::Send(message) => {
                            if write_message(stdin, &message).is_err() {
                                return (
                                    None,
                                    Some(protocol.failure_with_ids(
                                        "openclaw_acp_write_failed",
                                        "OpenClaw ACP stopped accepting protocol messages.",
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
                    Some(ProtocolFailure::new(
                        "openclaw_acp_invalid_json",
                        "OpenClaw ACP returned an invalid protocol message.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutLimitExceeded) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "openclaw_acp_output_limit",
                        "OpenClaw ACP exceeded the configured protocol output limit.",
                        "protocol/read",
                    )),
                    None,
                    true,
                );
            }
            Ok(TransportEvent::StdoutReadFailed) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "openclaw_acp_read_failed",
                        "OpenClaw ACP protocol output could not be read.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(protocol.failure_with_ids(
                        "openclaw_acp_exited",
                        "OpenClaw ACP exited before the turn completed.",
                        "process/exit",
                    )),
                    None,
                    false,
                );
            }
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

pub(super) fn pipe_failure(
    child: &mut SupervisedChild,
    started_at: String,
    message: &'static str,
) -> RunResult {
    let failure = if child.terminate_tree().is_ok() {
        ProtocolFailure::new("openclaw_acp_pipe_failed", message, "process/start")
    } else {
        ProtocolFailure::new(
            "openclaw_acp_cleanup_failed",
            "OpenClaw ACP process cleanup could not be completed safely.",
            "process/cleanup",
        )
    };
    RunResult::failed(failure, started_at, None, false, false)
}

pub(super) fn timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}
