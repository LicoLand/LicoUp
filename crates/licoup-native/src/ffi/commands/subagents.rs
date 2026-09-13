use super::{AdmittedCommand, CliExecution};
use crate::domain::subagents::local;
use anyhow::{Result, anyhow};

pub(super) fn handle_subagents_catalog(_: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(local::catalog()?))
}

pub(super) fn handle_subagents_execute(mut command: AdmittedCommand) -> Result<CliExecution> {
    let input = command
        .take_option_json("stdin-json")
        .ok_or_else(|| anyhow!("subagents_request_required"))?;
    Ok(CliExecution::Json(local::execute(input)?))
}
fn lifecycle(action: &str, binary: Option<&str>) -> Result<CliExecution> {
    let binary = binary.map(std::path::PathBuf::from);
    Ok(CliExecution::Json(
        crate::platform::mcp_service_process::execute(action, binary.as_deref())?,
    ))
}
pub(super) fn handle_mcp_start(command: AdmittedCommand) -> Result<CliExecution> {
    lifecycle("start", command.option_text("binary"))
}
pub(super) fn handle_mcp_stop(_: AdmittedCommand) -> Result<CliExecution> {
    lifecycle("stop", None)
}
pub(super) fn handle_mcp_reload(command: AdmittedCommand) -> Result<CliExecution> {
    lifecycle("reload", command.option_text("binary"))
}
pub(super) fn handle_mcp_status(_: AdmittedCommand) -> Result<CliExecution> {
    lifecycle("status", None)
}
