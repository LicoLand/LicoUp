use super::super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
};
use super::command::LaunchIdentity;
use super::control::ControlRequest;
use super::errors::{ProtocolFailure, pipe_failure};
use super::io::{TransportEvent, drain_stderr, read_protocol_messages};
use std::io::BufReader;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{self, Receiver};
use std::thread;

#[derive(Debug)]
pub(super) struct PersistentTransport {
    child: SupervisedChild,
    pub(super) stdin: BoundedStdinWriter,
    pub(super) receiver: Receiver<TransportEvent>,
    pub(super) control_receiver: Receiver<ControlRequest>,
    stdout_handle: Option<thread::JoinHandle<()>>,
    stderr_handle: Option<thread::JoinHandle<()>>,
    pub(super) stderr_truncated: Arc<AtomicBool>,
    closed: bool,
}

impl PersistentTransport {
    pub(super) fn spawn(
        identity: &LaunchIdentity,
        control_receiver: Receiver<ControlRequest>,
        max_stderr: usize,
    ) -> Result<Self, ProtocolFailure> {
        let mut child = identity.spawn().map_err(|error| {
            let message = match error.kind() {
                std::io::ErrorKind::NotFound => "The Claude Code executable is not available.",
                std::io::ErrorKind::PermissionDenied => {
                    "The Claude Code executable is not permitted to run."
                }
                _ => "Claude Code could not be started.",
            };
            ProtocolFailure::new("claude_code_start_failed", message, "process/start")
        })?;
        let stdout = child.stdout().ok_or_else(pipe_failure)?;
        let stderr = child.stderr().ok_or_else(pipe_failure)?;
        let stdin = child.stdin().ok_or_else(pipe_failure)?;
        let (sender, receiver) = mpsc::channel();
        let stdout_handle =
            thread::spawn(move || read_protocol_messages(BufReader::new(stdout), sender));
        let stderr_truncated = Arc::new(AtomicBool::new(false));
        let stderr_flag = Arc::clone(&stderr_truncated);
        let stderr_handle = thread::spawn(move || drain_stderr(stderr, max_stderr, &stderr_flag));
        Ok(Self {
            child,
            stdin: BoundedStdinWriter::new(stdin),
            receiver,
            control_receiver,
            stdout_handle: Some(stdout_handle),
            stderr_handle: Some(stderr_handle),
            stderr_truncated,
            closed: false,
        })
    }

    pub(super) fn shutdown(&mut self) -> Result<(), TransportFinishFailure> {
        if self.closed {
            return Ok(());
        }
        self.closed = true;
        let stdout = self
            .stdout_handle
            .take()
            .ok_or(TransportFinishFailure::Lifecycle)?;
        let stderr = self
            .stderr_handle
            .take()
            .ok_or(TransportFinishFailure::Lifecycle)?;
        finish_protocol_transport(&mut self.child, &mut self.stdin, stdout, stderr)
    }
}

impl Drop for PersistentTransport {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}
