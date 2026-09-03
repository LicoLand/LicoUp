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
            "runningVersion": selection.running_version,
            "runningReleaseTrack": selection.running_release_track,
            "targetReleaseTrack": selection.target_release_track,
            "availableVersion": selection.version,
            "targetId": selection.artifact.target_id,
            "installerStrategy": selection.artifact.installer_strategy,
            "stagedArtifactId": selection.receipt()["receiptId"],
            "artifactSha256": selection.artifact.sha256,
            "artifactReceipt": selection.receipt(),
            "executed": false,
            "restartRequired": true,
            "preUpdateStateRecord": {
                "runningVersion": selection.running_version,
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
