use anyhow::{Result, bail};
use serde_json::{Value, json};

use super::{
    constants::CLIENT_UPDATE_MODE, staging::reject_artifact_overrides,
    verify::verify_staged_selection,
};

pub fn apply(params: &Value) -> Result<Value> {
    reject_artifact_overrides(params)?;
    let (selection, staged_path) = verify_staged_selection(params)?;
    let execute = params
        .get("execute")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !execute {
        return Ok(json!({
            "ok": true,
            "mode": CLIENT_UPDATE_MODE,
            "phase": "applyPlanned",
            "availableVersion": selection.version,
            "targetId": selection.artifact.target_id,
            "installerStrategy": selection.artifact.installer_strategy,
            "stagedArtifactId": selection.receipt()["receiptId"],
            "artifactSha256": selection.artifact.sha256,
            "artifactReceipt": selection.receipt(),
            "executed": false,
            "restartRequired": true,
            "rollback": rollback_plan(&selection.artifact.installer_strategy, false),
            "preUpdateStateRecord": {
                "currentVersion": selection.current_version,
                "recorded": true,
                "pathRedacted": true,
            },
            "productionReady": false,
            "publicMetadataOnly": true,
            "storeCredentialsRequired": false,
        }));
    }
    match selection.artifact.installer_strategy.as_str() {
        "app-bundle-replacement" => {
            super::macos_runner::apply_macos_app_bundle(&selection, &staged_path)
        }
        strategy => {
            bail!("client update live apply is not enabled for installer strategy '{strategy}'")
        }
    }
}

pub fn rollback(params: &Value) -> Result<Value> {
    reject_artifact_overrides(params)?;
    let (selection, staged_path) = verify_staged_selection(params)?;
    match selection.artifact.installer_strategy.as_str() {
        "app-bundle-replacement" => {
            super::macos_runner::rollback_macos_app_bundle(&selection, &staged_path)
        }
        strategy => {
            bail!("client update rollback is not enabled for installer strategy '{strategy}'")
        }
    }
}

pub(super) fn rollback_plan(strategy: &str, snapshot_recorded: bool) -> Value {
    match strategy {
        "app-bundle-replacement" => json!({
            "feasibility": if snapshot_recorded {
                "restore-previous-app-bundle"
            } else {
                "platform-dependent"
            },
            "pathRedacted": true,
        }),
        _ => json!({
            "feasibility": "platform-dependent",
            "pathRedacted": true,
        }),
    }
}
