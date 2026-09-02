use super::{AdmittedCommand, CliExecution, admitted_params};
use anyhow::{Result, ensure};
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
                "enableAgentCliModelLookup",
                command.option_text("enable-agent-cli-model-lookup"),
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
    let mut params = admitted_params(
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
    if let Some(private) = command.option_json("stdin-json") {
        let private = private
            .as_object()
            .ok_or_else(|| anyhow::anyhow!("target_private_input_invalid"))?;
        let public_target = params
            .get("target")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if let Some(private_target) = private.get("target").and_then(Value::as_str) {
            ensure!(
                private_target == public_target,
                "target_private_input_mismatch"
            );
        }
        let object = params
            .as_object_mut()
            .ok_or_else(|| anyhow::anyhow!("target_private_input_invalid"))?;
        for key in ["label", "kind", "location", "runtimeConnection"] {
            if let Some(value) = private.get(key) {
                object.insert(key.to_string(), value.clone());
            }
        }
    }
    Ok(CliExecution::Json(crate::domain::targets::add_target(
        &params,
    )?))
}

pub(super) fn handle_targets_inspect(command: AdmittedCommand) -> Result<CliExecution> {
    let target = command.required_text("target");
    let mut params = admitted_params(
        &[
            ("stateRoot", command.option_text("state-root")),
            (
                "includeAccessibleEnvironments",
                command.option_text("include-accessible-environments"),
            ),
            (
                "enableAgentCliModelLookup",
                command.option_text("enable-agent-cli-model-lookup"),
            ),
        ],
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
