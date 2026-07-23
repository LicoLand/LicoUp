use super::{AdmittedCommand, CliExecution, admitted_params};
use anyhow::Result;
use serde_json::Value;

pub(super) fn handle_targets_scan(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("stateRoot", command.option_text("state-root")),
            (
                "includeAccessibleEnvironments",
                command.option_text("include-accessible-environments"),
            ),
            (
                "includeHistoryModelCatalog",
                command.option_text("include-history-model-catalog"),
            ),
            (
                "installerScanCommand",
                command.option_text("installer-scan-command"),
            ),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::targets::scan_targets_with_params(&params)?,
    ))
}

pub(super) fn handle_targets_add(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("target", command.option_text("target")),
            ("configPath", command.option_text("config-path")),
            ("binaryPath", command.option_text("binary-path")),
            ("historyRoot", command.option_text("history-root")),
            ("stateRoot", command.option_text("state-root")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(crate::domain::targets::add_target(
        &params,
    )?))
}

pub(super) fn handle_targets_inspect(command: AdmittedCommand) -> Result<CliExecution> {
    let target = command.required_text("target");
    let mut params = admitted_params(
        &[("stateRoot", command.option_text("state-root"))],
        &[],
        &[],
    );
    if let Some(object) = params.as_object_mut() {
        object.insert("target".to_string(), Value::String(target.to_string()));
    }
    Ok(CliExecution::Json(
        crate::domain::targets::inspect_target_with_params(&params)?,
    ))
}
