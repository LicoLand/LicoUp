use anyhow::Result;
use serde_json::{Value, json};

use super::{
    constants::CLIENT_UPDATE_MODE, selection::require_available_selection,
    staging::stage_selected_artifact,
};

pub fn download(params: &Value) -> Result<Value> {
    let selection = require_available_selection(params)?;
    let staged = stage_selected_artifact(params, &selection)?;
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "downloaded",
        "availableVersion": selection.version,
        "targetId": selection.artifact.target_id,
        "stagedArtifactId": selection.receipt()["receiptId"],
        "stagedBytes": selection.artifact.size,
        "totalBytes": selection.artifact.size,
        "artifactSha256": selection.artifact.sha256,
        "artifactReceipt": selection.receipt(),
        "stagingRootRedacted": true,
        "resumed": staged.resumed,
        "productionReady": false,
        "publicMetadataOnly": true,
    }))
}
