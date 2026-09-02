use super::super::process_supervisor::SupervisedChild;
use super::model::EffectiveSettings;
use super::params::DriverConfig;
use serde_json::Value;
use std::ffi::{OsStr, OsString};
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub(super) const FIXED_STREAM_ARGS: &[&str] = &[
    "--print",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    // Token-level streaming: the CLI emits content_block_delta events so the
    // client renders replies progressively instead of whole messages.
    "--include-partial-messages",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct LaunchIdentity {
    pub(super) executable: String,
    pub(super) cwd: Option<PathBuf>,
    pub(super) model: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) permission_mode: Option<String>,
    /// Comma-joined tool allowlist passed via `--allowedTools` so an approved
    /// retry does not re-trigger a permission denial.
    pub(super) allowed_tools: Option<String>,
    /// Native conversation to resume in a freshly launched process via
    /// `--resume`. Only set when no process-local live transport owns the
    /// session; the CLI loads the persisted transcript itself.
    pub(super) resume_session_id: Option<String>,
}

impl LaunchIdentity {
    pub(super) fn new(executable: &str, config: &DriverConfig, cwd: Option<&Path>) -> Self {
        Self {
            executable: executable.to_string(),
            cwd: cwd.map(Path::to_path_buf),
            model: config.model.clone(),
            reasoning_effort: config.reasoning_effort.clone(),
            permission_mode: config.permission_mode.clone(),
            allowed_tools: config.allowed_tools.clone(),
            resume_session_id: (!config.requested_session_id.is_empty())
                .then(|| config.requested_session_id.clone()),
        }
    }

    pub(super) fn compatible_with(
        &self,
        executable: &str,
        config: &DriverConfig,
        cwd: Option<&Path>,
    ) -> bool {
        self.executable == executable
            && self.cwd.as_deref() == cwd
            && config
                .model
                .as_ref()
                .is_none_or(|value| self.model.as_ref() == Some(value))
            && config
                .reasoning_effort
                .as_ref()
                .is_none_or(|value| self.reasoning_effort.as_ref() == Some(value))
            && config
                .permission_mode
                .as_ref()
                .is_none_or(|value| self.permission_mode.as_ref() == Some(value))
            && config
                .allowed_tools
                .as_ref()
                .is_none_or(|value| self.allowed_tools.as_ref() == Some(value))
    }

    pub(super) fn args(&self) -> Vec<String> {
        let mut args = FIXED_STREAM_ARGS
            .iter()
            .map(|value| (*value).to_string())
            .collect::<Vec<_>>();
        if let Some(session_id) = self.resume_session_id.as_ref() {
            args.extend(["--resume".to_string(), session_id.clone()]);
        }
        if let Some(model) = self.model.as_ref() {
            args.extend(["--model".to_string(), model.clone()]);
        }
        if let Some(effort) = self.reasoning_effort.as_ref() {
            args.extend(["--effort".to_string(), effort.clone()]);
        }
        if let Some(permission_mode) = self.permission_mode.as_ref() {
            args.extend(["--permission-mode".to_string(), permission_mode.clone()]);
        }
        if let Some(allowed_tools) = self.allowed_tools.as_ref() {
            args.extend(["--allowedTools".to_string(), allowed_tools.clone()]);
        }
        args
    }

    pub(super) fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = Command::new(&self.executable);
        command
            .args(self.args())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(path) =
            executable_augmented_path(&self.executable, std::env::var_os("PATH").as_deref())
        {
            command.env("PATH", path);
        }
        if let Some(cwd) = self.cwd.as_ref() {
            command.current_dir(cwd);
        }
        SupervisedChild::spawn(&mut command)
    }

    pub(super) fn effective(&self) -> EffectiveSettings {
        EffectiveSettings {
            cwd: self
                .cwd
                .as_ref()
                .map(|path| path.to_string_lossy().to_string()),
            model: self.model.clone(),
            reasoning_effort: self.reasoning_effort.clone(),
            permission_mode: self.permission_mode.clone(),
            sandbox: None,
            approval_policy: self.permission_mode.clone().map(Value::String),
        }
    }
}

pub(super) fn executable_augmented_path(
    executable: &str,
    inherited: Option<&OsStr>,
) -> Option<OsString> {
    let parent = Path::new(executable).parent()?.as_os_str();
    if parent.is_empty() {
        return None;
    }
    let mut paths = vec![PathBuf::from(parent)];
    if let Some(inherited) = inherited {
        paths.extend(std::env::split_paths(inherited));
    }
    std::env::join_paths(paths).ok()
}
