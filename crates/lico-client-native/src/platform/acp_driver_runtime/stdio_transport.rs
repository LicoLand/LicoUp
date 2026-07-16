use super::super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
};
use super::errors::ProtocolFailure;
use super::events::{TransportEvent, read_protocol_messages};
use super::io::{drain_stderr, write_message};
use super::model::{AcpDriverSpec, CapabilityProbe, PROCESS_POLL_INTERVAL, RunResult};
use super::params::{ProtocolConfig, timestamp};
use super::protocol::{AcpProtocol, ProtocolEffect, ProtocolOutcome};
use super::supervision::LaunchSpec;
use serde_json::Value;
use std::io::{self, BufReader};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

pub(in crate::platform) fn execute_acp(
    driver: AcpDriverSpec,
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
    let mut config = match ProtocolConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => {
            return RunResult::failed(
                driver,
                failure,
                started_at,
                None,
                false,
                false,
                CapabilityProbe::default(),
                Vec::new(),
            );
        }
    };
    if let Err(failure) = config.load_collaboration_mcp(driver.agent_id) {
        return RunResult::failed(
            driver,
            failure,
            started_at,
            None,
            false,
            false,
            CapabilityProbe::default(),
            Vec::new(),
        );
    }
    let launch = LaunchSpec::new(executable, driver, Path::new(&config.cwd));
    let mut child = match launch.spawn() {
        Ok(child) => child,
        Err(error) => {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The requested ACP agent executable is not available.",
                io::ErrorKind::PermissionDenied => {
                    "The requested ACP agent executable is not permitted to run."
                }
                _ => "The requested ACP agent could not be started.",
            };
            return RunResult::failed(
                driver,
                ProtocolFailure::new("acp_process_start_failed", message, "process/start"),
                started_at,
                None,
                false,
                false,
                CapabilityProbe::default(),
                Vec::new(),
            );
        }
    };

    let Some(stdout) = child.stdout() else {
        return pipe_failure(driver, &mut child, started_at);
    };
    let Some(stderr) = child.stderr() else {
        return pipe_failure(driver, &mut child, started_at);
    };
    let Some(stdin) = child.stdin() else {
        return pipe_failure(driver, &mut child, started_at);
    };
    let mut stdin = BoundedStdinWriter::new(stdin);

    let (sender, receiver) = mpsc::channel();
    let stdout_handle =
        thread::spawn(move || read_protocol_messages(BufReader::new(stdout), max_stdout, sender));
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));

    let mut protocol = AcpProtocol::new(config);
    let initial_request = match protocol.initial_request() {
        Ok(request) => request,
        Err(failure) => {
            let cleanup =
                finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
            let cleanup_failed = cleanup == Err(TransportFinishFailure::Lifecycle);
            return RunResult::failed(
                driver,
                if cleanup_failed {
                    ProtocolFailure::new(
                        "acp_process_cleanup_failed",
                        "The ACP agent process cleanup could not be completed safely.",
                        "process/cleanup",
                    )
                } else {
                    failure
                },
                started_at,
                None,
                false,
                stderr_truncated.load(Ordering::Relaxed),
                CapabilityProbe::default(),
                Vec::new(),
            );
        }
    };
    if write_message(&mut stdin, &initial_request).is_err() {
        let cleanup =
            finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
        let cleanup_failed = cleanup == Err(TransportFinishFailure::Lifecycle);
        return RunResult::failed(
            driver,
            ProtocolFailure::new(
                if cleanup_failed {
                    "acp_process_cleanup_failed"
                } else {
                    "acp_protocol_write_failed"
                },
                if cleanup_failed {
                    "The ACP agent process cleanup could not be completed safely."
                } else {
                    "The ACP agent stopped accepting protocol messages."
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
            CapabilityProbe::default(),
            Vec::new(),
        );
    }

    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let (outcome, failure, status_code, stdout_was_truncated) =
        run_protocol_loop(&mut stdin, &receiver, &mut protocol, deadline);
    let capabilities = protocol.capabilities.clone();
    let events = std::mem::take(&mut protocol.events);

    let cleanup = finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
    let stderr_was_truncated = stderr_truncated.load(Ordering::Relaxed);

    if cleanup == Err(TransportFinishFailure::Lifecycle) {
        return RunResult::failed(
            driver,
            ProtocolFailure::new(
                "acp_process_cleanup_failed",
                "The ACP agent process cleanup could not be completed safely.",
                "process/cleanup",
            ),
            started_at,
            status_code,
            stdout_was_truncated,
            stderr_was_truncated,
            capabilities,
            events,
        );
    }
    if outcome.is_some() && cleanup == Err(TransportFinishFailure::StdinWrite) {
        return RunResult::failed(
            driver,
            ProtocolFailure::new(
                "acp_protocol_write_failed",
                "The ACP agent stopped accepting protocol messages.",
                "protocol/write",
            ),
            started_at,
            status_code,
            stdout_was_truncated,
            stderr_was_truncated,
            capabilities,
            events,
        );
    }

    if let Some(outcome) = outcome {
        return RunResult {
            ok: true,
            output: outcome.output,
            events: outcome.events,
            error: None,
            session_id: outcome.session_id,
            thread_id: outcome.thread_id,
            turn_id: outcome.turn_id,
            turn_status: outcome.turn_status,
            effective: outcome.effective,
            capabilities: outcome.capabilities,
            status_code,
            stdout_truncated: stdout_was_truncated,
            stderr_truncated: stderr_was_truncated,
            started_at,
            runtime_protocol: driver.runtime_protocol,
            driver_id: driver.agent_id,
        };
    }

    RunResult::failed(
        driver,
        failure.unwrap_or_else(|| {
            ProtocolFailure::new(
                "acp_protocol_failed",
                "The ACP agent did not complete the request.",
                "protocol",
            )
            .with_session(protocol.session_id.as_deref())
        }),
        started_at,
        status_code,
        stdout_was_truncated,
        stderr_was_truncated,
        capabilities,
        events,
    )
}

fn pipe_failure(
    driver: AcpDriverSpec,
    child: &mut SupervisedChild,
    started_at: String,
) -> RunResult {
    let cleanup_ok = child.terminate_tree().is_ok();
    RunResult::failed(
        driver,
        ProtocolFailure::new(
            if cleanup_ok {
                "acp_process_pipe_failed"
            } else {
                "acp_process_cleanup_failed"
            },
            if cleanup_ok {
                "The ACP agent protocol pipes are unavailable."
            } else {
                "The ACP agent process cleanup could not be completed safely."
            },
            if cleanup_ok {
                "process/start"
            } else {
                "process/cleanup"
            },
        ),
        started_at,
        None,
        false,
        false,
        CapabilityProbe::default(),
        Vec::new(),
    )
}

fn run_protocol_loop(
    stdin: &mut BoundedStdinWriter,
    receiver: &Receiver<TransportEvent>,
    protocol: &mut AcpProtocol,
    deadline: Instant,
) -> (
    Option<ProtocolOutcome>,
    Option<ProtocolFailure>,
    Option<i32>,
    bool,
) {
    loop {
        if stdin.check_health().is_err() {
            let failure = ProtocolFailure::new(
                "acp_protocol_write_failed",
                "The ACP agent stopped accepting protocol messages.",
                "protocol/write",
            )
            .with_session(protocol.session_id.as_deref());
            return (None, Some(failure), None, false);
        }
        let now = Instant::now();
        if now >= deadline {
            let failure = ProtocolFailure::new(
                "acp_protocol_timeout",
                "The ACP agent timed out before the turn completed.",
                "session/prompt",
            )
            .with_session(protocol.session_id.as_deref());
            return (None, Some(failure), None, false);
        }
        let wait = (deadline - now).min(PROCESS_POLL_INTERVAL);
        match receiver.recv_timeout(wait) {
            Ok(TransportEvent::Message(message)) => {
                for effect in protocol.handle_message(message) {
                    match effect {
                        ProtocolEffect::Send(message) => {
                            if write_message(stdin, &message).is_err() {
                                let failure = ProtocolFailure::new(
                                    "acp_protocol_write_failed",
                                    "The ACP agent stopped accepting protocol messages.",
                                    "protocol/write",
                                )
                                .with_session(protocol.session_id.as_deref());
                                return (None, Some(failure), None, false);
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
                        "acp_protocol_invalid_json",
                        "The ACP agent returned an invalid protocol message.",
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
                        "acp_protocol_output_limit",
                        "The ACP agent exceeded the configured protocol output limit.",
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
                        "acp_protocol_read_failed",
                        "The ACP agent protocol output could not be read.",
                        "protocol/read",
                    )),
                    None,
                    false,
                );
            }
            Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                return (
                    None,
                    Some(ProtocolFailure::new(
                        "acp_process_exited",
                        "The ACP agent exited before the turn completed.",
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
