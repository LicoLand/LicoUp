use std::path::{Component, Path, PathBuf};

use anyhow::{Result, bail, ensure};
use serde_json::Value;

pub(super) fn product_version() -> String {
    option_env!("LICO_CLIENT_PRODUCT_VERSION")
        .unwrap_or("0.0.1-alpha")
        .to_string()
}

pub(super) fn json_text(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        params
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    })
}

pub(super) fn channel_name(params: &Value) -> Result<String> {
    let channel = json_text(params, &["channel"]).unwrap_or_else(|| "stable".to_string());
    ensure!(
        channel.len() <= 64
            && channel
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-')),
        "client update channel is invalid"
    );
    Ok(channel)
}

pub(super) fn staging_root(params: &Value) -> Result<PathBuf> {
    if let Some(path) = json_text(params, &["stagingRoot", "staging-root", "stageRoot"]) {
        return Ok(PathBuf::from(path));
    }
    let state_root = json_text(params, &["stateRoot", "state-root"])
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(".lico-client-update-staging"));
    Ok(state_root.join("client-update-staging"))
}

pub(super) fn selected_target_id(params: &Value) -> Result<String> {
    if let Some(target_id) = json_text(params, &["targetId", "target-id"]) {
        validate_public_identifier(&target_id, "client update targetId")?;
        return Ok(target_id);
    }
    default_target_id()
}

fn default_target_id() -> Result<String> {
    let target = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "macos-arm64",
        ("macos", "x86_64") => "macos-x64",
        ("windows", "aarch64") => "windows-arm64",
        ("windows", "x86_64") => "windows-x64",
        ("linux", "aarch64") => "linux-glibc-arm64",
        ("linux", "x86_64") => "linux-glibc-x64",
        ("android", "aarch64") => "android-arm64",
        ("ios", "aarch64") => "ios-arm64",
        _ => bail!("client update target is unsupported on this build"),
    };
    Ok(target.to_string())
}

pub(super) fn validate_public_identifier(value: &str, label: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-')),
        "{label} is invalid"
    );
    Ok(())
}

pub(super) fn validate_relative_file_name(value: &str, label: &str) -> Result<String> {
    ensure!(
        !value.contains('/') && !value.contains('\\'),
        "{label} must be a single relative file name"
    );
    let path = Path::new(value);
    let mut components = path.components();
    let first = components.next();
    ensure!(
        matches!(first, Some(Component::Normal(_))) && components.next().is_none(),
        "{label} must be a single relative file name"
    );
    Ok(value.to_string())
}

pub(super) fn validate_bundle_id(value: &str) -> Result<String> {
    ensure!(
        value.len() <= 255
            && value.split('.').count() >= 2
            && value.split('.').all(|part| {
                !part.is_empty()
                    && part.len() <= 63
                    && part
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
            }),
        "client update bundleId is invalid"
    );
    Ok(value.to_string())
}
