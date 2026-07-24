#[cfg(not(target_os = "macos"))]
use {
    super::model::VerifiedUpdateSelection,
    anyhow::{Result, bail},
    serde_json::Value,
    std::path::Path,
};

#[cfg(target_os = "macos")]
mod archive;
#[cfg(target_os = "macos")]
mod filesystem;
#[cfg(target_os = "macos")]
mod lifecycle;
#[cfg(target_os = "macos")]
mod platform;

#[cfg(target_os = "macos")]
pub(super) use lifecycle::{apply_macos_app_bundle, rollback_macos_app_bundle};

#[cfg(not(target_os = "macos"))]
pub(super) fn apply_macos_app_bundle(
    _selection: &VerifiedUpdateSelection,
    _staged_path: &Path,
) -> Result<Value> {
    bail!("client update app-bundle-replacement apply requires macOS")
}

#[cfg(not(target_os = "macos"))]
pub(super) fn rollback_macos_app_bundle(
    _selection: &VerifiedUpdateSelection,
    _staged_path: &Path,
) -> Result<Value> {
    bail!("client update app-bundle-replacement rollback requires macOS")
}

#[cfg(all(test, target_os = "macos"))]
pub(super) use archive::validate_archive_path_for_test;
#[cfg(all(test, target_os = "macos"))]
pub(super) use lifecycle::{apply_for_test, rollback_for_test};
