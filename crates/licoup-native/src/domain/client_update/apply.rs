use anyhow::Result;
use serde_json::{Value, json};

use super::{
    constants::CLIENT_UPDATE_MODE, params::bool_param, staging::reject_artifact_overrides,
    verify::verify_staged_selection,
};

pub fn apply(params: &Value) -> Result<Value> {
    reject_artifact_overrides(params)?;
    let (selection, staged_path) = verify_staged_selection(params)?;
    let execute = bool_param(params, "execute")?;
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
    super::native_runner::apply_live(&selection, &staged_path, params)
}

pub fn rollback(params: &Value) -> Result<Value> {
    reject_artifact_overrides(params)?;
    let (selection, staged_path) = verify_staged_selection(params)?;
    super::native_runner::rollback_live(&selection, &staged_path, params)
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
