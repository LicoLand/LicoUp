use command_group::{CommandGroup, GroupChild};
use std::io::{self, Write};
use std::process::{ChildStderr, ChildStdin, ChildStdout, Command, ExitStatus};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const PROCESS_EXIT_GRACE: Duration = Duration::from_secs(2);
const PROCESS_GRACEFUL_EXIT_GRACE: Duration = Duration::from_millis(100);
pub(super) const IO_THREAD_EXIT_GRACE: Duration = Duration::from_secs(1);
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(10);
const STDIN_QUEUE_CAPACITY: usize = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum LifecycleFailure {
    Terminate,
    Wait,
    IoThread,
}

#[derive(Debug)]
pub(super) struct SupervisedChild {
    child: GroupChild,
    cleaned: bool,
    pid: u32,
}

impl SupervisedChild {
    pub(super) fn spawn(command: &mut Command) -> io::Result<Self> {
        #[cfg(windows)]
        let mut child = command.group().kill_on_drop(true).spawn()?;
        #[cfg(not(windows))]
        let mut child = command.group_spawn()?;
        let pid = child.inner().id();

        Ok(Self {
            child,
            cleaned: false,
            pid,
        })
    }

    pub(super) fn stdin(&mut self) -> Option<ChildStdin> {
        self.child.inner().stdin.take()
    }

    pub(super) fn stdout(&mut self) -> Option<ChildStdout> {
        self.child.inner().stdout.take()
    }

    pub(super) fn stderr(&mut self) -> Option<ChildStderr> {
        self.child.inner().stderr.take()
    }

    pub(super) fn pid(&self) -> u32 {
        self.pid
    }

    /// Gives a batch-style child a bounded opportunity to report its natural
    /// exit status before terminating any process tree it left behind. The
    /// root stays unreaped during the grace period so its process-group ID
    /// cannot be recycled before descendant cleanup.
    pub(super) fn finish_or_terminate_tree(
        &mut self,
        graceful_exit_grace: Duration,
    ) -> Result<Option<ExitStatus>, LifecycleFailure> {
        if self.cleaned {
            return self.child.try_wait().map_err(|_| LifecycleFailure::Wait);
        }

        let deadline = Instant::now() + graceful_exit_grace;
        while Instant::now() < deadline {
            thread::sleep(PROCESS_POLL_INTERVAL);
        }
        self.terminate_tree()
    }

    /// Terminates the complete supervised process tree and reaps the root.
    ///
    /// This must be called on every non-panicking path. `Drop` is only a final
    /// leak-prevention fallback because it cannot report lifecycle errors.
    pub(super) fn terminate_tree(&mut self) -> Result<Option<ExitStatus>, LifecycleFailure> {
        if self.cleaned {
            return self.child.try_wait().map_err(|_| LifecycleFailure::Wait);
        }

        self.child
            .kill()
            .or_else(|error| {
                if process_group_is_gone(&error) {
                    Ok(())
                } else {
                    Err(error)
                }
            })
            .map_err(|_| LifecycleFailure::Terminate)?;

        let status = wait_for_exit(&mut self.child, PROCESS_EXIT_GRACE)?;
        self.cleaned = true;
        Ok(status)
    }

    fn terminate_best_effort(&mut self) {
        if self.cleaned {
            return;
        }
        let _ = self.child.kill();
        self.cleaned = true;
    }
}

fn process_group_is_gone(error: &io::Error) -> bool {
    if matches!(
        error.kind(),
        io::ErrorKind::InvalidInput | io::ErrorKind::NotFound
    ) {
        return true;
    }
    #[cfg(unix)]
    if matches!(
        error.raw_os_error(),
        Some(code)
            if code == nix::errno::Errno::ESRCH as i32
                || code == nix::errno::Errno::EPERM as i32
    ) {
        // Darwin reports EPERM when a process group contains only the
        // unreaped zombie leader. The leader is deliberately left unreaped
        // until after this signal attempt, so its process-group ID cannot have
        // been recycled. A live same-credential descendant remains signalable
        // and therefore does not take this branch.
        return true;
    }
    false
}

impl Drop for SupervisedChild {
    fn drop(&mut self) {
        self.terminate_best_effort();
    }
}

fn wait_for_exit(
    child: &mut GroupChild,
    grace: Duration,
) -> Result<Option<ExitStatus>, LifecycleFailure> {
    let deadline = Instant::now() + grace;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(Some(status)),
            Ok(None) if Instant::now() < deadline => thread::sleep(PROCESS_POLL_INTERVAL),
            Ok(None) => return Err(LifecycleFailure::Wait),
            Err(_) => return Err(LifecycleFailure::Wait),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum StdinFailure {
    Unavailable,
    Busy,
    Write,
    Shutdown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum TransportFinishFailure {
    Lifecycle,
    StdinWrite,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WriterEvent {
    Written,
    Failed,
}

#[derive(Debug)]
pub(super) struct BoundedStdinWriter {
    sender: Option<SyncSender<Vec<u8>>>,
    events: Receiver<WriterEvent>,
    handle: Option<JoinHandle<Result<(), StdinFailure>>>,
    failed: bool,
}

impl BoundedStdinWriter {
    pub(super) fn new(mut stdin: ChildStdin) -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Vec<u8>>(STDIN_QUEUE_CAPACITY);
        let (event_sender, events) = mpsc::channel();
        let handle = thread::spawn(move || {
            while let Ok(bytes) = receiver.recv() {
                if stdin.write_all(&bytes).is_err() || stdin.flush().is_err() {
                    let _ = event_sender.send(WriterEvent::Failed);
                    return Err(StdinFailure::Write);
                }
                let _ = event_sender.send(WriterEvent::Written);
            }
            drop(stdin);
            Ok(())
        });
        Self {
            sender: Some(sender),
            events,
            handle: Some(handle),
            failed: false,
        }
    }

    pub(super) fn enqueue(&mut self, bytes: Vec<u8>) -> Result<(), StdinFailure> {
        self.check_health()?;
        let Some(sender) = self.sender.as_ref() else {
            return Err(StdinFailure::Unavailable);
        };
        match sender.try_send(bytes) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => Err(StdinFailure::Busy),
            Err(TrySendError::Disconnected(_)) => {
                self.failed = true;
                Err(StdinFailure::Write)
            }
        }
    }

    pub(super) fn check_health(&mut self) -> Result<(), StdinFailure> {
        if self.failed {
            return Err(StdinFailure::Write);
        }
        loop {
            match self.events.try_recv() {
                Ok(WriterEvent::Written) => {}
                Ok(WriterEvent::Failed) => {
                    self.failed = true;
                    return Err(StdinFailure::Write);
                }
                Err(TryRecvError::Empty) => return Ok(()),
                Err(TryRecvError::Disconnected) => {
                    if self
                        .handle
                        .as_ref()
                        .is_some_and(|handle| handle.is_finished())
                    {
                        return Ok(());
                    }
                    self.failed = true;
                    return Err(StdinFailure::Write);
                }
            }
        }
    }

    pub(super) fn finish(&mut self, grace: Duration) -> Result<(), StdinFailure> {
        self.sender.take();
        let Some(handle) = self.handle.take() else {
            return if self.failed {
                Err(StdinFailure::Write)
            } else {
                Ok(())
            };
        };
        match join_bounded(handle, grace) {
            Ok(Ok(())) if !self.failed => Ok(()),
            Ok(Ok(())) | Ok(Err(_)) => Err(StdinFailure::Write),
            Err(_) => Err(StdinFailure::Shutdown),
        }
    }
}

pub(super) fn join_bounded<T>(
    handle: JoinHandle<T>,
    grace: Duration,
) -> Result<T, LifecycleFailure> {
    let deadline = Instant::now() + grace;
    while !handle.is_finished() && Instant::now() < deadline {
        thread::sleep(PROCESS_POLL_INTERVAL);
    }
    if !handle.is_finished() {
        drop(handle);
        return Err(LifecycleFailure::IoThread);
    }
    handle.join().map_err(|_| LifecycleFailure::IoThread)
}

pub(super) fn finish_protocol_transport(
    child: &mut SupervisedChild,
    stdin: &mut BoundedStdinWriter,
    stdout_handle: JoinHandle<()>,
    stderr_handle: JoinHandle<()>,
) -> Result<(), TransportFinishFailure> {
    let stdin = stdin.finish(IO_THREAD_EXIT_GRACE);
    let graceful_deadline = Instant::now() + PROCESS_GRACEFUL_EXIT_GRACE;
    while !stdout_handle.is_finished() && Instant::now() < graceful_deadline {
        thread::sleep(PROCESS_POLL_INTERVAL);
    }
    let process = child.terminate_tree();
    let stdout = join_bounded(stdout_handle, IO_THREAD_EXIT_GRACE);
    let stderr = join_bounded(stderr_handle, IO_THREAD_EXIT_GRACE);
    if process.is_err()
        || stdout.is_err()
        || stderr.is_err()
        || stdin == Err(StdinFailure::Shutdown)
    {
        return Err(TransportFinishFailure::Lifecycle);
    }
    if stdin.is_err() {
        return Err(TransportFinishFailure::StdinWrite);
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::io::Read;
    use std::process::Stdio;

    #[test]
    fn termination_closes_pipe_retained_by_descendant() {
        let mut command = Command::new("sh");
        command
            .args(["-c", "sleep 30 & printf ready"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = SupervisedChild::spawn(&mut command).unwrap();
        let mut stdout = child.stdout().unwrap();
        let reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            stdout.read_to_end(&mut bytes).map(|_| bytes)
        });

        thread::sleep(Duration::from_millis(50));
        child.terminate_tree().unwrap();
        let bytes = join_bounded(reader, IO_THREAD_EXIT_GRACE).unwrap().unwrap();
        assert_eq!(bytes, b"ready");
    }

    #[test]
    fn blocked_stdin_writer_does_not_own_the_deadline_loop() {
        let mut command = Command::new("sh");
        command
            .args(["-c", "sleep 30"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = SupervisedChild::spawn(&mut command).unwrap();
        let stdin = child.stdin().unwrap();
        let mut writer = BoundedStdinWriter::new(stdin);
        let started = Instant::now();
        writer.enqueue(vec![b'x'; 16 * 1024 * 1024]).unwrap();

        thread::sleep(Duration::from_millis(50));
        child.terminate_tree().unwrap();
        writer.finish(IO_THREAD_EXIT_GRACE).unwrap_err();
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn timeout_terminates_root_and_pipe_holding_descendant() {
        let mut command = Command::new("sh");
        command
            .args(["-c", "sleep 30 & printf ready; sleep 30"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = SupervisedChild::spawn(&mut command).unwrap();
        let mut stdout = child.stdout().unwrap();
        let reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            stdout.read_to_end(&mut bytes).map(|_| bytes)
        });
        let started = Instant::now();
        let deadline = started + Duration::from_millis(50);
        while Instant::now() < deadline {
            thread::sleep(PROCESS_POLL_INTERVAL);
        }

        child.terminate_tree().unwrap();
        let bytes = join_bounded(reader, IO_THREAD_EXIT_GRACE).unwrap().unwrap();
        assert_eq!(bytes, b"ready");
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn bounded_grace_preserves_a_natural_batch_exit_status() {
        let mut command = Command::new("sh");
        command
            .args(["-c", "exec 1>&-; sleep 0.05; exit 0"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = SupervisedChild::spawn(&mut command).unwrap();
        let mut stdout = child.stdout().unwrap();
        let mut bytes = Vec::new();
        stdout.read_to_end(&mut bytes).unwrap();

        let status = child
            .finish_or_terminate_tree(Duration::from_secs(1))
            .unwrap()
            .unwrap();
        assert!(status.success());
    }

    #[test]
    fn cleanup_reaps_a_naturally_exited_group() {
        let mut command = Command::new("sh");
        command
            .args(["-c", "exit 0"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = SupervisedChild::spawn(&mut command).unwrap();
        thread::sleep(Duration::from_millis(50));
        let status = child.terminate_tree().unwrap().unwrap();
        assert!(status.success());
    }
}
