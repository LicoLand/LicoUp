use super::super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
};
use super::capabilities::PROCESS_POLL_INTERVAL;
use super::command::{LaunchSpec, ProtocolConfig};
use super::continuity::ControlRequest;
use super::errors::ProtocolFailure;
use super::events::{TransportEvent, read_protocol_messages, request_id_matches};
use super::io::{drain_stderr, write_message};
use super::protocol::{INITIALIZE_REQUEST_ID, SessionProtocol};
use crate::core::acp;
use std::io::{self, BufReader};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug)]
pub(super) struct PersistentTransport {
    pub(super) child: SupervisedChild,
    pub(super) stdin: BoundedStdinWriter,
    pub(super) receiver: Receiver<TransportEvent>,
    pub(super) control_receiver: Receiver<ControlRequest>,
    pub(super) stdout_handle: Option<thread::JoinHandle<()>>,
    pub(super) stderr_handle: Option<thread::JoinHandle<()>>,
    pub(super) stderr_truncated: Arc<AtomicBool>,
    pub(super) closed: bool,
}

impl PersistentTransport {
    pub(super) fn spawn(
        launch: &LaunchSpec,
        control_receiver: Receiver<ControlRequest>,
        timeout_ms: u64,
        max_stdout: usize,
        max_stderr: usize,
    ) -> Result<Self, ProtocolFailure> {
        let mut child = launch.spawn().map_err(|error| {
            let message = match error.kind() {
                io::ErrorKind::NotFound => "The Hermes Agent executable is not available.",
                io::ErrorKind::PermissionDenied => {
                    "The Hermes Agent executable is not permitted to run."
                }
                _ => "Hermes ACP could not be started.",
            };
            ProtocolFailure::new("hermes_acp_start_failed", message, "process/start")
        })?;
        let stdout = child.stdout().ok_or_else(|| {
            ProtocolFailure::new(
                "hermes_acp_pipe_failed",
                "Hermes ACP stdout is unavailable.",
                "process/start",
            )
        })?;
        let stderr = child.stderr().ok_or_else(|| {
            ProtocolFailure::new(
                "hermes_acp_pipe_failed",
                "Hermes ACP stderr is unavailable.",
                "process/start",
            )
        })?;
        let stdin = child.stdin().ok_or_else(|| {
            ProtocolFailure::new(
                "hermes_acp_pipe_failed",
                "Hermes ACP stdin is unavailable.",
                "process/start",
            )
        })?;
        let stdin = BoundedStdinWriter::new(stdin);
        let (sender, receiver) = mpsc::channel();
        let stdout_handle =
            thread::spawn(move || read_protocol_messages(BufReader::new(stdout), sender));
        let stderr_truncated = Arc::new(AtomicBool::new(false));
        let stderr_flag = Arc::clone(&stderr_truncated);
        let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));
        let mut transport = Self {
            child,
            stdin,
            receiver,
            control_receiver,
            stdout_handle: Some(stdout_handle),
            stderr_handle: Some(stderr_handle),
            stderr_truncated,
            closed: false,
        };
        if let Err(failure) = transport.initialize(timeout_ms, max_stdout) {
            let _ = transport.shutdown();
            return Err(failure);
        }
        Ok(transport)
    }

    pub(super) fn initialize(
        &mut self,
        timeout_ms: u64,
        max_stdout: usize,
    ) -> Result<(), ProtocolFailure> {
        let request = SessionProtocol::new(ProtocolConfig {
            prompt: String::new(),
            requested_session_id: String::new(),
            cwd: String::new(),
            model: None,
            turn_id: String::new(),
            mcp_servers: Vec::new(),
        })
        .initial_request()?;
        write_message(&mut self.stdin, &request).map_err(|_| {
            ProtocolFailure::new(
                "hermes_acp_write_failed",
                "Hermes ACP stopped accepting protocol messages.",
                "initialize",
            )
        })?;
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        let mut observed_bytes = 0usize;
        loop {
            if self.stdin.check_health().is_err() {
                return Err(ProtocolFailure::new(
                    "hermes_acp_write_failed",
                    "Hermes ACP stopped accepting protocol messages.",
                    "initialize",
                ));
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(ProtocolFailure::new(
                    "hermes_acp_timeout",
                    "Hermes ACP timed out during initialization.",
                    "initialize",
                ));
            }
            match self
                .receiver
                .recv_timeout((deadline - now).min(PROCESS_POLL_INTERVAL))
            {
                Ok(TransportEvent::Message { message, bytes }) => {
                    observed_bytes = observed_bytes.saturating_add(bytes);
                    if observed_bytes > max_stdout {
                        return Err(ProtocolFailure::new(
                            "hermes_acp_output_limit",
                            "Hermes ACP exceeded the configured protocol output limit.",
                            "initialize",
                        ));
                    }
                    if !request_id_matches(&message, INITIALIZE_REQUEST_ID) {
                        continue;
                    }
                    match acp::validate_initialize_response(&message, INITIALIZE_REQUEST_ID) {
                        Ok(response) if response.capabilities.load_session => return Ok(()),
                        Ok(_) => {
                            return Err(ProtocolFailure::new(
                                "hermes_acp_capability_mismatch",
                                "Hermes ACP does not expose the required conversation lifecycle.",
                                "initialize/capabilities",
                            ));
                        }
                        Err(error) if error.is_remote_error() => {
                            return Err(ProtocolFailure::new(
                                "hermes_acp_initialize_failed",
                                "Hermes ACP initialization failed.",
                                acp::INITIALIZE_METHOD,
                            ));
                        }
                        Err(error) => {
                            return Err(ProtocolFailure::from_acp(error, acp::INITIALIZE_METHOD));
                        }
                    }
                }
                Ok(TransportEvent::InvalidJson) => {
                    return Err(ProtocolFailure::new(
                        "hermes_acp_invalid_json",
                        "Hermes ACP returned an invalid protocol message.",
                        "initialize",
                    ));
                }
                Ok(TransportEvent::LineLimitExceeded) => {
                    return Err(ProtocolFailure::new(
                        "hermes_acp_output_limit",
                        "Hermes ACP exceeded the hard protocol line limit.",
                        "initialize",
                    ));
                }
                Ok(TransportEvent::StdoutReadFailed) => {
                    return Err(ProtocolFailure::new(
                        "hermes_acp_read_failed",
                        "Hermes ACP protocol output could not be read.",
                        "initialize",
                    ));
                }
                Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                    return Err(ProtocolFailure::new(
                        "hermes_acp_exited",
                        "Hermes ACP exited during initialization.",
                        "process/exit",
                    ));
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
    }

    pub(super) fn shutdown(&mut self) -> Result<(), TransportFinishFailure> {
        if self.closed {
            return Ok(());
        }
        self.closed = true;
        let Some(stdout_handle) = self.stdout_handle.take() else {
            return Err(TransportFinishFailure::Lifecycle);
        };
        let Some(stderr_handle) = self.stderr_handle.take() else {
            return Err(TransportFinishFailure::Lifecycle);
        };
        finish_protocol_transport(
            &mut self.child,
            &mut self.stdin,
            stdout_handle,
            stderr_handle,
        )
    }
}

impl Drop for PersistentTransport {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}
