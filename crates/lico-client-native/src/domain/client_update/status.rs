use std::fs;

use anyhow::{Result, ensure};
use serde_json::{Value, json};

use super::{
    constants::CLIENT_UPDATE_MODE,
    params::{channel_name, product_version, staging_root},
};

pub fn status(params: &Value) -> Result<Value> {
    let staging = staging_root(params)?;
    let mut staged_artifact_count = 0_u64;
    let mut staged_bytes = 0_u64;
    if staging.is_dir() {
        for entry in fs::read_dir(&staging)? {
            let entry = entry?;
            let metadata = fs::symlink_metadata(entry.path())?;
            ensure!(
                !metadata.file_type().is_symlink(),
                "client update staging state contains a symbolic link"
            );
            if metadata.is_file() {
                staged_artifact_count = staged_artifact_count.saturating_add(1);
                staged_bytes = staged_bytes.saturating_add(metadata.len());
            }
        }
    }
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "idle",
        "channel": channel_name(params)?,
        "currentVersion": product_version(),
        "productionReady": false,
        "publicMetadataOnly": true,
        "storeCredentialsRequired": false,
        "stagingRootRedacted": true,
        "stagedArtifactCount": staged_artifact_count,
        "stagedBytes": staged_bytes,
        "policy": {
            "manualCheck": true,
            "automaticDownload": false,
            "automaticInstall": false
        }
    }))
}
