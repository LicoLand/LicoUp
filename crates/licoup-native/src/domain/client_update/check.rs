use anyhow::Result;
use serde_json::{Value, json};

use super::{constants::CLIENT_UPDATE_MODE, selection::verify_update_selection};

pub fn check(params: &Value) -> Result<Value> {
    let verified = verify_update_selection(params)?;
    let Some(selection) = verified.selected else {
        return Ok(json!({
            "ok": true,
            "mode": CLIENT_UPDATE_MODE,
            "phase": "upToDate",
            "channel": verified.channel,
            "currentVersion": verified.current_version,
            "updateAvailable": false,
            "verifiedKeyIds": verified.verified_key_ids,
            "manifestSha256": verified.manifest_sha256,
            "productionReady": false,
            "publicMetadataOnly": true,
            "storeCredentialsRequired": false,
        }));
    };
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "updateAvailable",
        "channel": selection.channel,
        "currentVersion": selection.current_version,
        "updateAvailable": true,
        "availableVersion": selection.version,
        "classification": selection.classification,
        "releaseNotesUrl": selection.release_notes_url,
        "migrationNotes": selection.migration_notes,
        "artifact": selection.artifact.public_projection(),
        "artifactReceipt": selection.receipt(),
        "verifiedKeyIds": selection.verified_key_ids,
        "manifestSha256": selection.manifest_sha256,
        "productionReady": false,
        "publicMetadataOnly": true,
        "storeCredentialsRequired": false,
    }))
}
