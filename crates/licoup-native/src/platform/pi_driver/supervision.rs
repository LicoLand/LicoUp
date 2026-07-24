use super::super::process_supervisor::SupervisedChild;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub(super) const LAUNCH_ARGS: &[&str] = &["--mode", "rpc", "--offline"];

#[derive(Clone, Debug)]
pub(super) struct LaunchSpec {
    pub(super) executable: String,
    pub(super) args: Vec<&'static str>,
    pub(super) cwd: PathBuf,
}

impl LaunchSpec {
    pub(super) fn new(executable: &str, cwd: &Path) -> Self {
        Self {
            executable: executable.to_string(),
            args: LAUNCH_ARGS.to_vec(),
            cwd: cwd.to_path_buf(),
        }
    }

    pub(super) fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(self.args.clone())
            .current_dir(&self.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        SupervisedChild::spawn(&mut command)
    }
}
