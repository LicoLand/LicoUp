use super::{AdmittedCommand, CliExecution};
use anyhow::Result;

pub(super) fn handle_read(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(crate::domain::model_registry::read()))
}

pub(super) fn handle_refresh(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(crate::domain::model_registry::refresh()))
}
