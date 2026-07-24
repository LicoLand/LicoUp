use std::{fs, path::Path};

use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};

use super::super::{
    apply::rollback_plan, constants::CLIENT_UPDATE_MODE, model::VerifiedUpdateSelection,
};
use super::{
    archive::extract_signed_archive,
    filesystem::{
        checked_app_directory, copy_tree, remove_generated_directory, validate_tree_without_links,
    },
    platform::{quit_running_client, register_application},
};

pub(in crate::domain::client_update) fn apply_macos_app_bundle(
    selection: &VerifiedUpdateSelection,
    staged_path: &Path,
) -> Result<Value> {
    apply_with_install_root(selection, staged_path, Path::new("/Applications"), false)
}

pub(in crate::domain::client_update) fn rollback_macos_app_bundle(
    selection: &VerifiedUpdateSelection,
    staged_path: &Path,
) -> Result<Value> {
    rollback_with_install_root(
        selection,
        Path::new("/Applications"),
        staged_path
            .parent()
            .context("client update staged artifact root is invalid")?,
        false,
    )
}

fn apply_with_install_root(
    selection: &VerifiedUpdateSelection,
    staged_path: &Path,
    install_root: &Path,
    skip_platform_actions: bool,
) -> Result<Value> {
    let application_name = selection
        .artifact
        .application_name
        .as_deref()
        .context("client update signed applicationName is required")?;
    let bundle_id = selection
        .artifact
        .bundle_id
        .as_deref()
        .context("client update signed bundleId is required")?;
    let staging_root = staged_path
        .parent()
        .context("client update staged artifact root is invalid")?;
    let binding_id = binding_suffix(selection)?;
    let extraction_root = staging_root.join(format!(".expanded-{binding_id}"));
    remove_generated_directory(&extraction_root)?;
    fs::create_dir(&extraction_root).context("failed to create update extraction root")?;
    extract_signed_archive(selection, staged_path, &extraction_root)?;
    let staged_app = checked_app_directory(&extraction_root, application_name)?;

    fs::create_dir_all(install_root).context("failed to create client application root")?;
    let canonical_install_root =
        fs::canonicalize(install_root).context("failed to canonicalize client application root")?;
    let target_app = canonical_install_root.join(application_name);
    ensure!(
        target_app.parent() == Some(canonical_install_root.as_path()),
        "client update application path escapes its install root"
    );
    let snapshot_root = staging_root.join(format!(".rollback-{binding_id}"));
    remove_generated_directory(&snapshot_root)?;
    fs::create_dir(&snapshot_root).context("failed to create client update rollback root")?;
    let snapshot_app = snapshot_root.join(application_name);
    let snapshot_recorded = if target_app.exists() {
        validate_tree_without_links(&target_app)?;
        copy_tree(&target_app, &snapshot_app)?;
        true
    } else {
        false
    };
    quit_running_client(bundle_id, skip_platform_actions)?;
    if target_app.exists() {
        fs::remove_dir_all(&target_app).context("failed to remove current client application")?;
    }
    copy_tree(&staged_app, &target_app)?;
    if !skip_platform_actions {
        register_application(&target_app);
    }
    remove_generated_directory(&extraction_root)?;
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "applied",
        "availableVersion": selection.version,
        "targetId": selection.artifact.target_id,
        "installerStrategy": selection.artifact.installer_strategy,
        "installedArtifactId": selection.receipt()["receiptId"],
        "artifactSha256": selection.artifact.sha256,
        "artifactReceipt": selection.receipt(),
        "executed": true,
        "restartRequired": true,
        "rollback": rollback_plan("app-bundle-replacement", snapshot_recorded),
        "preUpdateStateRecord": {
            "currentVersion": selection.current_version,
            "recorded": true,
            "snapshotRecorded": snapshot_recorded,
            "pathRedacted": true,
        },
        "productionReady": false,
        "publicMetadataOnly": true,
        "storeCredentialsRequired": false,
    }))
}

fn rollback_with_install_root(
    selection: &VerifiedUpdateSelection,
    install_root: &Path,
    staging_root: &Path,
    skip_platform_actions: bool,
) -> Result<Value> {
    let application_name = selection
        .artifact
        .application_name
        .as_deref()
        .context("client update signed applicationName is required")?;
    let bundle_id = selection
        .artifact
        .bundle_id
        .as_deref()
        .context("client update signed bundleId is required")?;
    let canonical_install_root =
        fs::canonicalize(install_root).context("failed to canonicalize client application root")?;
    let target_app = canonical_install_root.join(application_name);
    let snapshot_root = staging_root.join(format!(".rollback-{}", binding_suffix(selection)?));
    let snapshot_app = snapshot_root.join(application_name);
    validate_tree_without_links(&snapshot_app)
        .context("client update rollback snapshot is unavailable")?;
    quit_running_client(bundle_id, skip_platform_actions)?;
    if target_app.exists() {
        validate_tree_without_links(&target_app)?;
        fs::remove_dir_all(&target_app).context("failed to remove failed client application")?;
    }
    copy_tree(&snapshot_app, &target_app)?;
    if !skip_platform_actions {
        register_application(&target_app);
    }
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "rolledBack",
        "availableVersion": selection.version,
        "targetId": selection.artifact.target_id,
        "installerStrategy": selection.artifact.installer_strategy,
        "restoredArtifactId": selection.receipt()["receiptId"],
        "artifactSha256": selection.artifact.sha256,
        "artifactReceipt": selection.receipt(),
        "executed": true,
        "restartRequired": true,
        "pathRedacted": true,
        "productionReady": false,
        "publicMetadataOnly": true,
        "storeCredentialsRequired": false,
    }))
}

fn binding_suffix(selection: &VerifiedUpdateSelection) -> Result<String> {
    let receipt = selection.receipt();
    let receipt_id = receipt["receiptId"]
        .as_str()
        .context("client update artifact receiptId is missing")?;
    receipt_id
        .strip_prefix("sha256:")
        .map(ToOwned::to_owned)
        .context("client update artifact receiptId is invalid")
}

#[cfg(test)]
pub(in crate::domain::client_update) fn apply_for_test(
    selection: &VerifiedUpdateSelection,
    staged_path: &Path,
    install_root: &Path,
) -> Result<Value> {
    apply_with_install_root(selection, staged_path, install_root, true)
}

#[cfg(test)]
pub(in crate::domain::client_update) fn rollback_for_test(
    selection: &VerifiedUpdateSelection,
    install_root: &Path,
    staging_root: &Path,
) -> Result<Value> {
    let application_name = selection
        .artifact
        .application_name
        .as_deref()
        .context("client update signed applicationName is required")?;
    let canonical_install_root = fs::canonicalize(install_root)?;
    let target_app = canonical_install_root.join(application_name);
    let snapshot_app = staging_root
        .join(format!(".rollback-{}", binding_suffix(selection)?))
        .join(application_name);
    validate_tree_without_links(&snapshot_app)?;
    if target_app.exists() {
        fs::remove_dir_all(&target_app)?;
    }
    copy_tree(&snapshot_app, &target_app)?;
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "rolledBack",
        "restoredArtifactId": selection.receipt()["receiptId"],
        "pathRedacted": true,
        "productionReady": false,
    }))
}
