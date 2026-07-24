use super::super::process_supervisor::SupervisedChild;
use super::errors::ProtocolFailure;
use super::model::AcpDriverSpec;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug)]
pub(super) struct LaunchSpec {
    pub(super) executable: String,
    pub(super) driver: AcpDriverSpec,
    pub(super) cwd: PathBuf,
}

impl LaunchSpec {
    pub(super) fn new(executable: &str, driver: AcpDriverSpec, cwd: &Path) -> Self {
        Self {
            executable: executable.to_string(),
            driver,
            cwd: cwd.to_path_buf(),
        }
    }

    pub(super) fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(self.driver.launch_args)
            .current_dir(&self.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        SupervisedChild::spawn(&mut command)
    }
}

pub(super) fn acp_pipe_failure(child: &mut SupervisedChild) -> ProtocolFailure {
    if child.terminate_tree().is_ok() {
        ProtocolFailure::new(
            "acp_process_pipe_failed",
            "The ACP agent protocol pipes are unavailable.",
            "process/start",
        )
    } else {
        ProtocolFailure::new(
            "acp_process_cleanup_failed",
            "The ACP agent process cleanup could not be completed safely.",
            "process/cleanup",
        )
    }
}
