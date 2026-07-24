use super::super::process_supervisor::SupervisedChild;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug)]
pub(super) struct CodexLaunchSpec {
    pub(super) executable: String,
    pub(super) args: Vec<String>,
    pub(super) cwd: Option<PathBuf>,
}

impl CodexLaunchSpec {
    /// The official stdio app-server owns thread continuity through its
    /// `thread.id`; no parallel daemon or prompt-bearing argv channel exists.
    pub(super) fn new(executable: &str, cwd: Option<&Path>) -> Self {
        Self {
            executable: executable.to_string(),
            args: vec!["app-server".to_string(), "--stdio".to_string()],
            cwd: cwd.map(Path::to_path_buf),
        }
    }

    pub(super) fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(cwd) = self.cwd.as_ref() {
            command.current_dir(cwd);
        }
        SupervisedChild::spawn(&mut command)
    }
}
