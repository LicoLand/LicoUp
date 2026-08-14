use anyhow::{Result, anyhow, ensure};
use serde_json::Value;

use super::{
    constants::CLIENT_UPDATE_MANIFEST_SCHEMA,
    keys::load_public_keys,
    metadata::{load_manifest, load_revocation_list},
    model::VerifiedManifest,
    params::{channel_name, product_version, selected_target_id, validate_public_identifier},
    release::select_highest_release,
    revocation::enforce_revocation_policy,
    signature::verify_manifest_role_signatures,
};

pub(super) fn verify_update_selection(params: &Value) -> Result<VerifiedManifest> {
    let channel = channel_name(params)?;
    let current_version = product_version(params)?;
    let target_id = selected_target_id(params)?;
    let manifest = load_manifest(params)?;
    ensure!(
        manifest.is_object(),
        "client update manifest must be an object"
    );
    ensure!(
        manifest.get("schemaVersion").and_then(Value::as_str)
            == Some(CLIENT_UPDATE_MANIFEST_SCHEMA),
        "client update manifest schema is unsupported"
    );
    ensure!(
        manifest.get("channel").and_then(Value::as_str) == Some(channel.as_str()),
        "client update manifest channel does not match the selected channel"
    );
    let offline_root_key_id = manifest
        .pointer("/channelPolicy/offlineRootKeyId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("client update offlineRootKeyId is required"))?;
    let online_channel_key_id = manifest
        .pointer("/channelPolicy/onlineChannelKeyId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("client update onlineChannelKeyId is required"))?;
    validate_public_identifier(offline_root_key_id, "client update offlineRootKeyId")?;
    validate_public_identifier(online_channel_key_id, "client update onlineChannelKeyId")?;
    ensure!(
        offline_root_key_id != online_channel_key_id,
        "client update offline root and online channel keys must be distinct"
    );
    let public_keys = load_public_keys(params)?;
    let verified_key_ids = verify_manifest_role_signatures(
        &manifest,
        &public_keys,
        offline_root_key_id,
        online_channel_key_id,
    )?;
    let selected_release = select_highest_release(&manifest, &current_version, &target_id)?;
    let verified = VerifiedManifest::from_selection(
        channel.clone(),
        current_version,
        verified_key_ids,
        &manifest,
        selected_release
            .as_ref()
            .map(|selected| (selected.artifact.clone(), selected.release)),
    );
    let revocation = load_revocation_list(params)?;
    enforce_revocation_policy(
        &manifest,
        revocation.as_ref(),
        &public_keys,
        offline_root_key_id,
        online_channel_key_id,
        &channel,
        verified.selected.as_ref(),
    )?;
    Ok(verified)
}

pub(super) fn require_available_selection(
    params: &Value,
) -> Result<super::model::VerifiedUpdateSelection> {
    verify_update_selection(params)?
        .selected
        .ok_or_else(|| anyhow!("client update has no eligible signed release for this client"))
}
