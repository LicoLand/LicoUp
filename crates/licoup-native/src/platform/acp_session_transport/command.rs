use super::super::process_supervisor::SupervisedChild;
use super::super::virtual_machine::SshRuntimeConnection;
use super::super::virtual_machine::is_absolute_acp_working_directory;
use super::capabilities::AcpSessionDriverSpec;
use super::errors::ProtocolFailure;
use serde_json::Value;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolConfig {
    pub(in crate::platform) prompt: String,
    pub(in crate::platform) requested_session_id: String,
    pub(in crate::platform) cwd: String,
    pub(in crate::platform) model: Option<String>,
    pub(in crate::platform) turn_id: String,
    pub(in crate::platform) mcp_servers: Vec<Value>,
}

impl ProtocolConfig {
    pub(in crate::platform) fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        if prompt.trim().is_empty() {
            return Err(ProtocolFailure::new(
                "hermes_empty_prompt",
                "Hermes Agent requires a non-empty message.",
                "request/validate",
            ));
        }
        if text_param(params, &["reasoningEffort", "reasoning_effort"]).is_some() {
            return Err(ProtocolFailure::new(
                "hermes_acp_reasoning_override_unsupported",
                "Hermes ACP does not expose a per-session reasoning-effort override.",
                "capability/reasoning",
            ));
        }
        if explicit_value(params, &["sandbox", "sandboxMode"]).is_some() {
            return Err(ProtocolFailure::new(
                "hermes_acp_sandbox_override_unsupported",
                "Hermes ACP inherits the native sandbox configuration and has no per-turn override.",
                "capability/sandbox",
            ));
        }
        if explicit_value(params, &["approvalPolicy", "approval_policy"]).is_some() {
            return Err(ProtocolFailure::new(
                "hermes_acp_approval_override_unsupported",
                "Hermes ACP approvals require an explicit client approval response.",
                "capability/approval",
            ));
        }
        let cwd = cwd
            .filter(|path| is_absolute_acp_working_directory(path))
            .map(|path| path.to_string_lossy().to_string())
            .ok_or_else(|| {
                ProtocolFailure::new(
                    "hermes_acp_absolute_cwd_required",
                    "Hermes ACP requires an absolute working directory.",
                    "request/validate",
                )
            })?;
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id: session_id.trim().to_string(),
            cwd,
            model: text_param(params, &["model", "modelId"]),
            turn_id: Uuid::new_v4().to_string(),
            mcp_servers: Vec::new(),
        })
    }

    pub(in crate::platform) fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty()
    }

    pub(in crate::platform) fn load_collaboration_mcp(
        &mut self,
        runtime_id: &str,
    ) -> Result<(), ProtocolFailure> {
        self.mcp_servers = crate::domain::collaboration_plugin::acp_servers_for_runtime(runtime_id)
            .map_err(|_| {
                ProtocolFailure::new(
                    "hermes_acp_mcp_registration_invalid",
                    "The optional MCP registration could not be validated safely.",
                    "session/mcp",
                )
            })?;
        Ok(())
    }
}

#[derive(Debug)]
pub(in crate::platform) struct LaunchSpec {
    pub(in crate::platform) executable: String,
    pub(in crate::platform) driver: AcpSessionDriverSpec,
    pub(in crate::platform) cwd: PathBuf,
    pub(in crate::platform) runtime_connection: Option<SshRuntimeConnection>,
}

impl LaunchSpec {
    pub(in crate::platform) fn new(
        driver: AcpSessionDriverSpec,
        executable: &str,
        cwd: &Path,
    ) -> Self {
        Self {
            executable: executable.to_string(),
            driver,
            cwd: cwd.to_path_buf(),
            runtime_connection: None,
        }
    }

    pub(in crate::platform) fn with_runtime_connection(
        mut self,
        runtime_connection: Option<SshRuntimeConnection>,
    ) -> Self {
        self.runtime_connection = runtime_connection;
        self
    }

    pub(in crate::platform) fn spawn(&self) -> io::Result<SupervisedChild> {
        let mut command = match &self.runtime_connection {
            Some(connection) => connection
                .launch_acp_command(self.driver.runtime_id)
                .map_err(io::Error::other)?,
            None => {
                let mut command = Command::new(&self.executable);
                command.args(self.driver.launch_args).current_dir(&self.cwd);
                command
            }
        };
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        SupervisedChild::spawn(&mut command)
    }
}

fn explicit_value<'a>(params: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter()
        .find_map(|key| params.get(*key))
        .filter(|value| !value.is_null())
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}
