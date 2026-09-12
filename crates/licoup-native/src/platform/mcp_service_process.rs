//! Optional MCP lifecycle delegates to an independently built executable.
//! The native kernel neither links the server nor owns its protocol sessions.
use anyhow::{Result, anyhow};
use serde_json::Value;
use std::{
    env,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

fn default_binary() -> Result<PathBuf> {
    let executable = env::current_exe().map_err(|_| anyhow!("mcp_binary_unavailable"))?;
    let name = if cfg!(windows) {
        "lico-subagent-mcp.exe"
    } else {
        "lico-subagent-mcp"
    };
    Ok(executable.with_file_name(name))
}
pub fn execute(action: &str, binary: Option<&Path>) -> Result<Value> {
    if !matches!(action, "start" | "stop" | "reload" | "status") {
        return Err(anyhow!("mcp_lifecycle_invalid"));
    }
    let binary = binary
        .map(Path::to_owned)
        .map(Ok)
        .unwrap_or_else(default_binary)?;
    let cli = env::current_exe().map_err(|_| anyhow!("mcp_cli_unavailable"))?;
    let root = super::paths::portable_data_dir()?;
    super::file_security::ensure_private_dir(&root.join("client-state").join("subagent-mcp"))?;
    let output = Command::new(binary)
        .args(["service", action])
        .env("LICOUP_CLI_BINARY", cli)
        .env("LICOUP_PORTABLE_DIR", root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map_err(|_| anyhow!("mcp_service_unavailable"))?;
    if !output.status.success() {
        return Err(anyhow!("mcp_service_unavailable"));
    }
    serde_json::from_slice(&output.stdout).map_err(|_| anyhow!("mcp_service_response_invalid"))
}
