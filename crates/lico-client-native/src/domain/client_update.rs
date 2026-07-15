//! In-app signed client update: discover / download / verify / apply.
//!
//! Public metadata only. Store credentials and private signing keys are never
//! required. `productionReady` stays false until a real release channel with
//! offline-root + online-channel custody exists outside this module. macOS
//! app-bundle apply/rollback runners may execute locally without claiming
//! production readiness.

use anyhow::{Context, Result, anyhow, bail, ensure};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

pub const CLIENT_UPDATE_MANIFEST_SCHEMA: &str = "v0.0.1:client-update:manifest-1";
pub const CLIENT_UPDATE_MODE: &str = "client-update";

fn product_version() -> String {
    // Keep aligned with tools/client-version.json until packaging injects a build constant.
    option_env!("LICO_CLIENT_PRODUCT_VERSION")
        .unwrap_or("0.0.1-alpha")
        .to_string()
}

fn json_text(params: &Value, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(value) = params.get(*key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn staging_root(params: &Value) -> Result<PathBuf> {
    if let Some(path) = json_text(params, &["stagingRoot", "staging-root", "stageRoot"]) {
        return Ok(PathBuf::from(path));
    }
    let state_root = json_text(params, &["stateRoot", "state-root"])
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(".lico-client-update-staging"));
    Ok(state_root.join("client-update-staging"))
}

fn channel_name(params: &Value) -> String {
    json_text(params, &["channel"]).unwrap_or_else(|| "stable".to_string())
}

fn compare_versions(left: &str, right: &str) -> i32 {
    let left_parts: Vec<i64> = left
        .split(|c: char| !c.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse().ok())
        .collect();
    let right_parts: Vec<i64> = right
        .split(|c: char| !c.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse().ok())
        .collect();
    let length = left_parts.len().max(right_parts.len());
    for index in 0..length {
        let l = left_parts.get(index).copied().unwrap_or(0);
        let r = right_parts.get(index).copied().unwrap_or(0);
        if l != r {
            return if l > r { 1 } else { -1 };
        }
    }
    0
}

fn stable_stringify(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(flag) => if *flag { "true" } else { "false" }.to_string(),
        Value::Number(number) => number.to_string(),
        Value::String(text) => serde_json::to_string(text).unwrap_or_else(|_| "\"\"".to_string()),
        Value::Array(items) => {
            let body = items
                .iter()
                .map(stable_stringify)
                .collect::<Vec<_>>()
                .join(",");
            format!("[{body}]")
        }
        Value::Object(map) => {
            let mut keys = map.keys().cloned().collect::<Vec<_>>();
            keys.sort();
            let body = keys
                .into_iter()
                .map(|key| {
                    let encoded_key = serde_json::to_string(&key).unwrap_or_else(|_| "\"\"".into());
                    format!("{encoded_key}:{}", stable_stringify(&map[&key]))
                })
                .collect::<Vec<_>>()
                .join(",");
            format!("{{{body}}}")
        }
    }
}

fn unsigned_manifest(manifest: &Value) -> Value {
    let mut clone = manifest.clone();
    if let Some(object) = clone.as_object_mut() {
        object.remove("signatures");
    }
    clone
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("sha256:{}", hex_encode(&Sha256::digest(bytes)))
}

fn sha256_file(path: &Path) -> Result<String> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    Ok(sha256_hex(&bytes))
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn decode_public_key(value: &str) -> Result<VerifyingKey> {
    let trimmed = value.trim();
    let bytes = if let Ok(decoded) = general_purpose::STANDARD.decode(trimmed) {
        decoded
    } else if let Ok(decoded) = general_purpose::URL_SAFE_NO_PAD.decode(trimmed) {
        decoded
    } else {
        // Accept SPKI PEM-ish raw 32-byte hex as last resort.
        let hex = trimmed.strip_prefix("sha256:").unwrap_or(trimmed);
        if hex.len() == 64 && hex.chars().all(|c| c.is_ascii_hexdigit()) {
            bail!("client update public key must be raw Ed25519 key bytes, not a fingerprint")
        }
        bail!("client update public key encoding is unsupported")
    };
    ensure!(
        bytes.len() == 32,
        "client update public key must be 32 raw Ed25519 bytes"
    );
    let array: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("client update public key length is invalid"))?;
    VerifyingKey::from_bytes(&array).map_err(|_| anyhow!("client update public key is invalid"))
}

fn verify_manifest_signatures(
    manifest: &Value,
    public_keys_by_id: &BTreeMap<String, VerifyingKey>,
) -> Result<Vec<String>> {
    let signatures = manifest
        .get("signatures")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("client update manifest signatures are required"))?;
    ensure!(
        !signatures.is_empty(),
        "client update manifest has no signatures"
    );
    let payload = stable_stringify(&unsigned_manifest(manifest));
    let payload_bytes = payload.as_bytes();
    let mut verified_keys = Vec::new();
    for signature_entry in signatures {
        let key_id = signature_entry
            .get("keyId")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("client update signature keyId is required"))?;
        let algorithm = signature_entry
            .get("algorithm")
            .and_then(Value::as_str)
            .unwrap_or("");
        ensure!(
            algorithm == "Ed25519",
            "client update signature algorithm must be Ed25519"
        );
        let signature_b64 = signature_entry
            .get("signature")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("client update signature is required"))?;
        let key = public_keys_by_id
            .get(key_id)
            .ok_or_else(|| anyhow!("client update signature key is unknown"))?;
        let signature_bytes = general_purpose::STANDARD
            .decode(signature_b64)
            .or_else(|_| general_purpose::URL_SAFE_NO_PAD.decode(signature_b64))
            .context("client update signature is not valid base64")?;
        ensure!(
            signature_bytes.len() == 64,
            "client update signature length is invalid"
        );
        let array: [u8; 64] = signature_bytes
            .as_slice()
            .try_into()
            .map_err(|_| anyhow!("client update signature length is invalid"))?;
        let signature = Signature::from_bytes(&array);
        key.verify(payload_bytes, &signature)
            .map_err(|_| anyhow!("client update manifest signature verification failed"))?;
        verified_keys.push(key_id.to_string());
    }
    Ok(verified_keys)
}

fn load_public_keys(params: &Value) -> Result<BTreeMap<String, VerifyingKey>> {
    let mut keys = BTreeMap::new();
    if let Some(path) = json_text(params, &["publicKeysPath", "public-keys-path", "keysPath"]) {
        let raw = fs::read_to_string(&path)
            .with_context(|| format!("failed to read public keys at {path}"))?;
        let parsed: Value = serde_json::from_str(&raw)?;
        let map = parsed
            .as_object()
            .or_else(|| parsed.get("keys").and_then(Value::as_object))
            .ok_or_else(|| anyhow!("client update public keys must be a JSON object"))?;
        for (key_id, value) in map {
            let encoded = value
                .as_str()
                .or_else(|| value.get("publicKey").and_then(Value::as_str))
                .ok_or_else(|| anyhow!("client update public key value is invalid"))?;
            keys.insert(key_id.clone(), decode_public_key(encoded)?);
        }
    }
    if let Some(inline) = params.get("publicKeys").and_then(Value::as_object) {
        for (key_id, value) in inline {
            let encoded = value
                .as_str()
                .or_else(|| value.get("publicKey").and_then(Value::as_str))
                .ok_or_else(|| anyhow!("client update public key value is invalid"))?;
            keys.insert(key_id.clone(), decode_public_key(encoded)?);
        }
    }
    ensure!(
        !keys.is_empty(),
        "client update public keys are required for verification"
    );
    Ok(keys)
}

fn load_manifest(params: &Value) -> Result<Value> {
    if let Some(path) = json_text(params, &["manifestPath", "manifest-path", "manifest"]) {
        let raw = fs::read_to_string(&path)
            .with_context(|| format!("failed to read update manifest at {path}"))?;
        return serde_json::from_str(&raw).context("client update manifest is not valid JSON");
    }
    if let Some(inline) = params.get("manifestJson").cloned() {
        if let Some(text) = inline.as_str() {
            return serde_json::from_str(text).context("client update manifest is not valid JSON");
        }
        return Ok(inline);
    }
    bail!("client update check requires --manifest-path or --manifest-json")
}

fn load_revocation_list(params: &Value) -> Result<Option<Value>> {
    if let Some(path) = json_text(params, &["revocationPath", "revocation-path"]) {
        let raw = fs::read_to_string(&path)
            .with_context(|| format!("failed to read revocation list at {path}"))?;
        return Ok(Some(serde_json::from_str(&raw)?));
    }
    Ok(params.get("revocationList").cloned())
}

fn select_release<'a>(
    manifest: &'a Value,
    current_version: &str,
    target_id: Option<&str>,
) -> Result<&'a Value> {
    let releases = manifest
        .get("releases")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("client update manifest releases are required"))?;
    ensure!(
        !releases.is_empty(),
        "client update manifest has no releases"
    );
    let allow_downgrade = manifest
        .pointer("/channelPolicy/allowDowngrade")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut selected = None;
    for release in releases {
        let version = release
            .get("version")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("client update release version is required"))?;
        if !allow_downgrade && compare_versions(version, current_version) <= 0 {
            continue;
        }
        if let Some(target) = target_id {
            let artifacts = release
                .get("artifacts")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if !artifacts
                .iter()
                .any(|artifact| artifact.get("targetId").and_then(Value::as_str) == Some(target))
            {
                continue;
            }
        }
        selected = Some(release);
    }
    selected.ok_or_else(|| anyhow!("client update has no newer signed release for this client"))
}

fn is_version_revoked(revocation: &Value, version: &str) -> bool {
    revocation
        .get("revokedVersions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .any(|entry| entry.as_str() == Some(version))
}

/// Report current client update status without network side effects.
pub fn status(params: &Value) -> Result<Value> {
    let staging = staging_root(params)?;
    let staged = if staging.is_dir() {
        fs::read_dir(&staging)
            .map(|entries| {
                entries
                    .filter_map(|entry| entry.ok())
                    .filter(|entry| entry.path().is_file())
                    .map(|entry| {
                        json!({
                            "fileName": entry.file_name().to_string_lossy(),
                            "size": entry.metadata().ok().map(|meta| meta.len()).unwrap_or(0),
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "idle",
        "channel": channel_name(params),
        "currentVersion": product_version(),
        "productionReady": false,
        "publicMetadataOnly": true,
        "storeCredentialsRequired": false,
        "stagingRootRedacted": true,
        "stagedArtifacts": staged,
        "policy": {
            "manualCheck": true,
            "automaticDownload": false,
            "automaticInstall": false
        }
    }))
}

/// Discover and verify a signed update manifest.
pub fn check(params: &Value) -> Result<Value> {
    let current_version = product_version();
    let channel = channel_name(params);
    let manifest = load_manifest(params)?;
    let schema = manifest
        .get("schemaVersion")
        .or_else(|| manifest.get("schema"))
        .and_then(Value::as_str)
        .unwrap_or("");
    ensure!(
        schema == CLIENT_UPDATE_MANIFEST_SCHEMA || schema.is_empty(),
        "client update manifest schema is unsupported"
    );
    let offline_root = manifest
        .pointer("/channelPolicy/offlineRootKeyId")
        .and_then(Value::as_str)
        .unwrap_or("");
    let online_channel = manifest
        .pointer("/channelPolicy/onlineChannelKeyId")
        .and_then(Value::as_str)
        .unwrap_or("");
    ensure!(
        !offline_root.is_empty() && !online_channel.is_empty() && offline_root != online_channel,
        "client update channel policy must separate offline root and online channel keys"
    );
    let public_keys = load_public_keys(params)?;
    let verified_keys = verify_manifest_signatures(&manifest, &public_keys)?;
    let revocation = load_revocation_list(params)?;
    let target_id = json_text(params, &["targetId", "target-id"]);
    let release = match select_release(&manifest, &current_version, target_id.as_deref()) {
        Ok(release) => release,
        Err(_) => {
            return Ok(json!({
                "ok": true,
                "mode": CLIENT_UPDATE_MODE,
                "phase": "upToDate",
                "channel": channel,
                "currentVersion": current_version,
                "updateAvailable": false,
                "verifiedKeyIds": verified_keys,
                "productionReady": false,
                "publicMetadataOnly": true,
            }));
        }
    };
    let version = release.get("version").and_then(Value::as_str).unwrap_or("");
    if let Some(revocation) = &revocation {
        ensure!(
            !is_version_revoked(revocation, version),
            "client update release version is revoked"
        );
    }
    let artifacts = release
        .get("artifacts")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "updateAvailable",
        "channel": channel,
        "currentVersion": current_version,
        "updateAvailable": true,
        "availableVersion": version,
        "classification": release.get("classification").cloned().unwrap_or(Value::Null),
        "releaseNotesUrl": release.get("releaseNotesUrl").cloned().unwrap_or(Value::Null),
        "migrationNotes": release.get("migrationNotes").cloned().unwrap_or_else(|| json!([])),
        "artifacts": artifacts.into_iter().map(|artifact| {
            json!({
                "targetId": artifact.get("targetId"),
                "platform": artifact.get("platform"),
                "osFamily": artifact.get("osFamily"),
                "arch": artifact.get("arch"),
                "installerStrategy": artifact.get("installerStrategy"),
                "url": artifact.get("url"),
                "size": artifact.get("size"),
                "sha256": artifact.get("sha256"),
            })
        }).collect::<Vec<_>>(),
        "verifiedKeyIds": verified_keys,
        "productionReady": false,
        "publicMetadataOnly": true,
        "storeCredentialsRequired": false,
    }))
}

/// Stage an artifact into the local update staging directory (resume-capable copy).
pub fn download(params: &Value) -> Result<Value> {
    let source =
        json_text(params, &["sourcePath", "source-path", "artifactPath"]).ok_or_else(|| {
            anyhow!("client update download requires --source-path for local staging")
        })?;
    let source_path = PathBuf::from(&source);
    ensure!(
        source_path.is_file(),
        "client update artifact source is missing"
    );
    let staging = staging_root(params)?;
    fs::create_dir_all(&staging)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&staging)?.permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&staging, permissions)?;
    }
    let file_name = source_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("client-update-artifact");
    let destination = staging.join(file_name);
    let expected_size = params
        .get("size")
        .and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
        })
        .unwrap_or_else(|| {
            fs::metadata(&source_path)
                .map(|meta| meta.len())
                .unwrap_or(0)
        });
    let mut staged_size = if destination.is_file() {
        fs::metadata(&destination)
            .map(|meta| meta.len())
            .unwrap_or(0)
    } else {
        0
    };
    if staged_size > expected_size {
        fs::remove_file(&destination)?;
        staged_size = 0;
    }
    if staged_size < expected_size {
        let mut source_file = fs::File::open(&source_path)?;
        if staged_size > 0 {
            use std::io::Seek;
            source_file.seek(std::io::SeekFrom::Start(staged_size))?;
        }
        let mut destination_file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&destination)?;
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let read = source_file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            destination_file.write_all(&buffer[..read])?;
            staged_size += read as u64;
        }
    }
    ensure!(
        staged_size == expected_size || expected_size == 0,
        "client update staged artifact size mismatch"
    );
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "downloaded",
        "stagedFileName": file_name,
        "stagedBytes": staged_size,
        "totalBytes": expected_size,
        "stagingRootRedacted": true,
        "resumed": staged_size > 0,
        "productionReady": false,
    }))
}

/// Verify staged artifact digest against the signed manifest entry.
pub fn verify(params: &Value) -> Result<Value> {
    let check_result = check(params)?;
    if check_result.get("updateAvailable") != Some(&Value::Bool(true)) {
        return Ok(json!({
            "ok": true,
            "mode": CLIENT_UPDATE_MODE,
            "phase": "upToDate",
            "updateAvailable": false,
            "productionReady": false,
        }));
    }
    let expected_sha = json_text(params, &["sha256", "expectedSha256"])
        .or_else(|| {
            check_result
                .get("artifacts")
                .and_then(Value::as_array)
                .and_then(|artifacts| artifacts.first())
                .and_then(|artifact| artifact.get("sha256"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
        })
        .ok_or_else(|| anyhow!("client update artifact sha256 is required"))?;
    let staging = staging_root(params)?;
    let file_name = json_text(params, &["stagedFileName", "staged-file-name", "fileName"])
        .ok_or_else(|| anyhow!("client update staged file name is required"))?;
    let staged_path = staging.join(&file_name);
    ensure!(
        staged_path.is_file(),
        "client update staged artifact is missing"
    );
    let actual = sha256_file(&staged_path)?;
    ensure!(
        actual == expected_sha,
        "client update artifact digest mismatch"
    );
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "verified",
        "availableVersion": check_result.get("availableVersion"),
        "artifactSha256": actual,
        "manifestVerified": true,
        "digestMatched": true,
        "productionReady": false,
        "publicMetadataOnly": true,
    }))
}

/// Produce an apply plan, or execute a macOS app-bundle replacement when safe.
///
/// Live apply stays non-production: `productionReady` remains false until a
/// signed release channel and complete runners exist. Store credentials are never required.
pub fn apply(params: &Value) -> Result<Value> {
    let verify_result = verify(params)?;
    ensure!(
        verify_result.get("phase").and_then(Value::as_str) == Some("verified"),
        "client update apply requires a verified staged artifact"
    );
    let strategy = json_text(params, &["installerStrategy", "installer-strategy"])
        .unwrap_or_else(|| "dry-run".to_string());
    let execute = params
        .get("execute")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let normalized_strategy = normalize_installer_strategy(&strategy);
    let staged_path = staged_artifact_path(params)?;
    let current_version = product_version();
    let pre_update = json!({
        "currentVersion": current_version,
        "recorded": true,
        "installerStrategy": normalized_strategy,
    });

    if !execute {
        return Ok(json!({
            "ok": true,
            "mode": CLIENT_UPDATE_MODE,
            "phase": "applyPlanned",
            "installerStrategy": normalized_strategy,
            "executed": false,
            "restartRequired": true,
            "rollback": rollback_plan_for_strategy(&normalized_strategy, false),
            "preUpdateStateRecord": pre_update,
            "productionReady": false,
            "publicMetadataOnly": true,
            "storeCredentialsRequired": false,
        }));
    }

    match normalized_strategy.as_str() {
        "app-bundle-replacement" => {
            let staged_app = json_text(params, &["stagedAppPath", "staged-app-path"])
                .map(PathBuf::from)
                .unwrap_or(staged_path);
            apply_macos_app_bundle_replacement(params, &staged_app, pre_update)
        }
        _ => bail!(
            "client update live apply is not enabled for installer strategy '{normalized_strategy}'"
        ),
    }
}

/// Restore a previously staged macOS app bundle snapshot.
pub fn rollback(params: &Value) -> Result<Value> {
    let strategy = json_text(params, &["installerStrategy", "installer-strategy"])
        .unwrap_or_else(|| "app-bundle-replacement".to_string());
    let normalized_strategy = normalize_installer_strategy(&strategy);
    ensure!(
        normalized_strategy == "app-bundle-replacement",
        "client update rollback currently supports app-bundle-replacement only"
    );
    #[cfg(not(target_os = "macos"))]
    {
        let _ = params;
        bail!("client update rollback for app-bundle-replacement requires macOS");
    }
    #[cfg(target_os = "macos")]
    {
        let snapshot_root = rollback_snapshot_root(params)?;
        let snapshot_app = snapshot_root.join("previous.app");
        ensure!(
            snapshot_app.is_dir(),
            "client update rollback snapshot was not found"
        );
        let target_app = macos_install_app_path(params)?;
        quit_running_macos_client(params)?;
        if target_app.exists() {
            let failed = snapshot_root.join("failed-apply.app");
            let _ = fs::remove_dir_all(&failed);
            fs::rename(&target_app, &failed).with_context(|| {
                format!(
                    "failed to move current app aside at {}",
                    target_app.display()
                )
            })?;
        }
        copy_dir_recursive(&snapshot_app, &target_app)?;
        register_macos_app(&target_app);
        Ok(json!({
            "ok": true,
            "mode": CLIENT_UPDATE_MODE,
            "phase": "rolledBack",
            "installerStrategy": normalized_strategy,
            "executed": true,
            "restartRequired": true,
            "restoredFrom": snapshot_app.display().to_string(),
            "installedAppPath": target_app.display().to_string(),
            "productionReady": false,
            "publicMetadataOnly": true,
            "storeCredentialsRequired": false,
        }))
    }
}

fn normalize_installer_strategy(strategy: &str) -> String {
    match strategy.trim() {
        "app-replace" | "app-bundle-replacement" => "app-bundle-replacement".to_string(),
        other if other.is_empty() => "dry-run".to_string(),
        other => other.to_string(),
    }
}

fn rollback_plan_for_strategy(strategy: &str, snapshot_recorded: bool) -> Value {
    match strategy {
        "app-bundle-replacement" => json!({
            "feasibility": if snapshot_recorded { "restore-previous-app-bundle" } else { "platform-dependent" },
            "note": "macOS app-bundle rollback restores the pre-update snapshot when recorded; productionReady stays false."
        }),
        _ => json!({
            "feasibility": "platform-dependent",
            "note": "Live installer runners are not claimed ready for this strategy."
        }),
    }
}

fn staged_artifact_path(params: &Value) -> Result<PathBuf> {
    let root = staging_root(params)?;
    let name = json_text(params, &["stagedFileName", "staged-file-name", "fileName"])
        .unwrap_or_else(|| "artifact.bin".to_string());
    Ok(root.join(name))
}

fn rollback_snapshot_root(params: &Value) -> Result<PathBuf> {
    if let Some(path) = json_text(params, &["rollbackSnapshotRoot", "rollback-snapshot-root"]) {
        return Ok(PathBuf::from(path));
    }
    Ok(staging_root(params)?.join("rollback-snapshot"))
}

#[cfg(target_os = "macos")]
fn macos_install_app_path(params: &Value) -> Result<PathBuf> {
    if let Some(path) = json_text(
        params,
        &["installAppPath", "install-app-path", "targetAppPath"],
    ) {
        return Ok(PathBuf::from(path));
    }
    let install_dir = json_text(params, &["installDir", "install-dir"])
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/Applications"));
    let app_name =
        json_text(params, &["appName", "app-name"]).unwrap_or_else(|| "Lico Arc.app".to_string());
    Ok(install_dir.join(app_name))
}

#[cfg(target_os = "macos")]
fn apply_macos_app_bundle_replacement(
    params: &Value,
    staged_path: &Path,
    mut pre_update: Value,
) -> Result<Value> {
    ensure!(
        staged_path.exists(),
        "client update staged artifact was not found"
    );
    let staged_app = resolve_staged_app_bundle(staged_path)?;
    let target_app = macos_install_app_path(params)?;
    let snapshot_root = rollback_snapshot_root(params)?;
    fs::create_dir_all(&snapshot_root)?;
    let snapshot_app = snapshot_root.join("previous.app");
    let _ = fs::remove_dir_all(&snapshot_app);
    if target_app.exists() {
        copy_dir_recursive(&target_app, &snapshot_app)?;
        if let Some(object) = pre_update.as_object_mut() {
            object.insert(
                "previousAppSnapshot".to_string(),
                Value::String(snapshot_app.display().to_string()),
            );
            object.insert("snapshotRecorded".to_string(), Value::Bool(true));
        }
    }
    quit_running_macos_client(params)?;
    if target_app.exists() {
        fs::remove_dir_all(&target_app).with_context(|| {
            format!("failed to remove existing app at {}", target_app.display())
        })?;
    }
    if let Some(parent) = target_app.parent() {
        fs::create_dir_all(parent)?;
    }
    copy_dir_recursive(&staged_app, &target_app)?;
    register_macos_app(&target_app);
    Ok(json!({
        "ok": true,
        "mode": CLIENT_UPDATE_MODE,
        "phase": "applied",
        "installerStrategy": "app-bundle-replacement",
        "executed": true,
        "restartRequired": true,
        "installedAppPath": target_app.display().to_string(),
        "stagedAppPath": staged_app.display().to_string(),
        "rollback": rollback_plan_for_strategy("app-bundle-replacement", snapshot_app.is_dir()),
        "preUpdateStateRecord": pre_update,
        "productionReady": false,
        "publicMetadataOnly": true,
        "storeCredentialsRequired": false,
        "note": "Local macOS app-bundle apply completed; signed release-channel production readiness is not claimed.",
    }))
}

#[cfg(not(target_os = "macos"))]
fn apply_macos_app_bundle_replacement(
    _params: &Value,
    _staged_path: &Path,
    _pre_update: Value,
) -> Result<Value> {
    bail!("client update app-bundle-replacement apply requires macOS")
}

#[cfg(target_os = "macos")]
fn resolve_staged_app_bundle(staged_path: &Path) -> Result<PathBuf> {
    if staged_path.is_dir()
        && staged_path.extension().and_then(|value| value.to_str()) == Some("app")
    {
        return Ok(staged_path.to_path_buf());
    }
    if staged_path.is_dir() {
        for entry in fs::read_dir(staged_path)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) == Some("app") {
                return Ok(path);
            }
        }
    }
    bail!("client update staged artifact must be a .app bundle for app-bundle-replacement")
}

#[cfg(target_os = "macos")]
fn quit_running_macos_client(params: &Value) -> Result<()> {
    if params
        .get("skipQuit")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Ok(());
    }
    let bundle_id =
        json_text(params, &["bundleId", "bundle-id"]).unwrap_or_else(|| "com.liko.arc".to_string());
    let script = format!(
        "if application id \"{bundle_id}\" is running then tell application id \"{bundle_id}\" to quit"
    );
    let _ = std::process::Command::new("osascript")
        .args(["-e", &script])
        .status();
    Ok(())
}

#[cfg(target_os = "macos")]
fn register_macos_app(app_path: &Path) {
    let lsregister = Path::new(
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    );
    if lsregister.exists() {
        let _ = std::process::Command::new(lsregister)
            .args(["-f", &app_path.to_string_lossy()])
            .status();
    }
    let _ = std::process::Command::new("mdimport")
        .arg(app_path)
        .status();
}

fn copy_dir_recursive(source: &Path, target: &Path) -> Result<()> {
    fs::create_dir_all(target)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let from = entry.path();
        let to = target.join(entry.file_name());
        if file_type.is_dir() {
            copy_dir_recursive(&from, &to)?;
        } else if file_type.is_symlink() {
            let link = fs::read_link(&from)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::symlink;
                let _ = fs::remove_file(&to);
                symlink(&link, &to)?;
            }
            #[cfg(not(unix))]
            {
                let _ = link;
                fs::copy(&from, &to)?;
            }
        } else {
            if let Some(parent) = to.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

pub fn dispatch(args: &[String], params: &Value) -> Result<Value> {
    match args.get(1).map(String::as_str).unwrap_or("status") {
        "status" => status(params),
        "check" => check(params),
        "download" => download(params),
        "verify" => verify(params),
        "apply" => apply(params),
        "rollback" => rollback(params),
        _ => bail!("client update command is unsupported"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use rand::rngs::OsRng;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir() -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("lico-client-update-{nanos}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn signed_manifest(signing_key: &SigningKey, key_id: &str, version: &str) -> Value {
        let mut manifest = json!({
            "schemaVersion": CLIENT_UPDATE_MANIFEST_SCHEMA,
            "channel": "stable",
            "channelPolicy": {
                "offlineRootKeyId": "offline-root",
                "onlineChannelKeyId": key_id,
                "allowDowngrade": false
            },
            "releases": [{
                "version": version,
                "minimumSupportedVersion": "0.0.1",
                "classification": "optional",
                "releaseNotesUrl": "https://example.invalid/notes",
                "migrationNotes": [],
                "artifacts": [{
                    "targetId": "macos-arm64",
                    "platform": "macos",
                    "osFamily": "darwin",
                    "arch": "arm64",
                    "installerStrategy": "app-replace",
                    "url": "file://artifact.bin",
                    "size": 4,
                    "sha256": sha256_hex(b"demo")
                }]
            }]
        });
        let payload = stable_stringify(&unsigned_manifest(&manifest));
        let signature = signing_key.sign(payload.as_bytes());
        manifest.as_object_mut().unwrap().insert(
            "signatures".into(),
            json!([{
                "keyId": key_id,
                "algorithm": "Ed25519",
                "signature": general_purpose::STANDARD.encode(signature.to_bytes())
            }]),
        );
        manifest
    }

    #[test]
    fn check_verifies_signed_manifest_and_rejects_downgrade() {
        let signing_key = SigningKey::generate(&mut OsRng);
        let verifying = signing_key.verifying_key();
        let key_id = "online-channel";
        let manifest = signed_manifest(&signing_key, key_id, "9.9.9");
        let public_key = general_purpose::STANDARD.encode(verifying.as_bytes());
        let result = check(&json!({
            "manifestJson": manifest,
            "publicKeys": { key_id: public_key }
        }))
        .unwrap();
        assert_eq!(result["updateAvailable"], true);
        assert_eq!(result["availableVersion"], "9.9.9");
        assert_eq!(result["productionReady"], false);

        let downgrade = signed_manifest(&signing_key, key_id, "0.0.0");
        let up_to_date = check(&json!({
            "manifestJson": downgrade,
            "publicKeys": { key_id: general_purpose::STANDARD.encode(verifying.as_bytes()) }
        }))
        .unwrap();
        assert_eq!(up_to_date["updateAvailable"], false);
        assert_eq!(up_to_date["phase"], "upToDate");
    }

    #[test]
    fn download_resume_and_verify_digest() {
        let dir = temp_dir();
        let source = dir.join("artifact.bin");
        fs::write(&source, b"demo").unwrap();
        let staging = dir.join("staging");
        let download_result = download(&json!({
            "sourcePath": source,
            "stagingRoot": staging,
            "size": 4
        }))
        .unwrap();
        assert_eq!(download_result["phase"], "downloaded");
        assert_eq!(download_result["stagedBytes"], 4);

        let signing_key = SigningKey::generate(&mut OsRng);
        let key_id = "online-channel";
        let manifest = signed_manifest(&signing_key, key_id, "9.9.9");
        let verify_result = verify(&json!({
            "manifestJson": manifest,
            "publicKeys": {
                key_id: general_purpose::STANDARD.encode(signing_key.verifying_key().as_bytes())
            },
            "stagingRoot": staging,
            "stagedFileName": "artifact.bin",
            "sha256": sha256_hex(b"demo")
        }))
        .unwrap();
        assert_eq!(verify_result["phase"], "verified");
        assert_eq!(verify_result["digestMatched"], true);

        let apply_result = apply(&json!({
            "manifestJson": manifest,
            "publicKeys": {
                key_id: general_purpose::STANDARD.encode(signing_key.verifying_key().as_bytes())
            },
            "stagingRoot": staging,
            "stagedFileName": "artifact.bin",
            "sha256": sha256_hex(b"demo"),
            "execute": false,
            "installerStrategy": "app-bundle-replacement"
        }))
        .unwrap();
        assert_eq!(apply_result["phase"], "applyPlanned");
        assert_eq!(apply_result["executed"], false);
        assert_eq!(apply_result["productionReady"], false);
        assert_eq!(apply_result["installerStrategy"], "app-bundle-replacement");
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_app_bundle_apply_and_rollback_keep_production_ready_false() {
        let dir = temp_dir();
        let staging = dir.join("staging");
        fs::create_dir_all(&staging).unwrap();
        let marker = staging.join("artifact.bin");
        fs::write(&marker, b"demo").unwrap();
        let staged_app = staging.join("Lico Arc.app");
        fs::create_dir_all(staged_app.join("Contents")).unwrap();
        fs::write(staged_app.join("Contents").join("Info.plist"), b"staged").unwrap();

        let install_dir = dir.join("Applications");
        let current_app = install_dir.join("Lico Arc.app");
        fs::create_dir_all(current_app.join("Contents")).unwrap();
        fs::write(current_app.join("Contents").join("Info.plist"), b"current").unwrap();

        let signing_key = SigningKey::generate(&mut OsRng);
        let key_id = "online-channel";
        let manifest = signed_manifest(&signing_key, key_id, "9.9.9");

        let apply_result = apply(&json!({
            "manifestJson": manifest,
            "publicKeys": {
                key_id: general_purpose::STANDARD.encode(signing_key.verifying_key().as_bytes())
            },
            "stagingRoot": staging,
            "stagedFileName": "artifact.bin",
            "stagedAppPath": staged_app,
            "sha256": sha256_hex(b"demo"),
            "execute": true,
            "installerStrategy": "app-bundle-replacement",
            "installDir": install_dir,
            "appName": "Lico Arc.app",
            "skipQuit": true,
            "rollbackSnapshotRoot": dir.join("rollback-snapshot"),
        }))
        .unwrap();
        assert_eq!(apply_result["executed"], true);
        assert_eq!(apply_result["productionReady"], false);
        assert_eq!(apply_result["phase"], "applied");
        assert_eq!(
            fs::read(
                install_dir
                    .join("Lico Arc.app")
                    .join("Contents")
                    .join("Info.plist")
            )
            .unwrap(),
            b"staged"
        );

        let rollback_result = rollback(&json!({
            "installerStrategy": "app-bundle-replacement",
            "installDir": install_dir,
            "appName": "Lico Arc.app",
            "skipQuit": true,
            "rollbackSnapshotRoot": dir.join("rollback-snapshot"),
        }))
        .unwrap();
        assert_eq!(rollback_result["phase"], "rolledBack");
        assert_eq!(rollback_result["productionReady"], false);
        assert_eq!(
            fs::read(
                install_dir
                    .join("Lico Arc.app")
                    .join("Contents")
                    .join("Info.plist")
            )
            .unwrap(),
            b"current"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
