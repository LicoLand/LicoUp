use super::super::process_supervisor::SupervisedChild;
use serde_json::Value;
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
        self.spawn_with_context(None)
    }

    pub(super) fn spawn_with_context(&self, params: Option<&Value>) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(cwd) = self.cwd.as_ref() {
            command.current_dir(cwd);
        }
        apply_launch_environment(&mut command, params)?;
        SupervisedChild::spawn(&mut command)
    }
}

/// Membership headers must be present on the plugin MCP child. Resolve the
/// same effective root as the rest of the app (including its saved selection)
/// and never trust a captured shell value from Codex's launch profile. The
/// released plugin currently allowlists the legacy variable, so pass both
/// names at this one plugin boundary with the same effective value.
pub(super) fn apply_launch_environment(
    command: &mut Command,
    params: Option<&Value>,
) -> io::Result<()> {
    let root = licoup_foundation::platform::paths::selected_data_home()
        .map_err(|_| io::Error::other("cannot resolve selected LicoUp data root"))?
        .path
        .into_os_string();
    apply_launch_environment_with_root(command, params, Some(root));
    Ok(())
}

pub(super) fn apply_launch_environment_with_root(
    command: &mut Command,
    params: Option<&Value>,
    portable_root: Option<std::ffi::OsString>,
) {
    super::super::user_shell_environment::apply_to_command(command);
    command.env_remove("LICOUP_HOME");
    command.env_remove("LICOUP_PORTABLE_DIR");
    if let Some(root) = portable_root.filter(|value| !value.is_empty()) {
        command.env("LICOUP_HOME", root.clone());
        command.env("LICOUP_PORTABLE_DIR", root);
    }
    if let Some(params) = params {
        crate::platform::runtime_adapters::apply_subagent_caller_context(command, params);
    }
}
