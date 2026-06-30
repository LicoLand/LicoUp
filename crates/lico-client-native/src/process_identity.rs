use crate::client_state::ClientStateStore;
use crate::file_security::atomic_write_private_text;
use anyhow::{Result, anyhow};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use rand::rngs::OsRng;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::path::Path;
#[cfg(target_os = "macos")]
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const STATE_SCHEMA_VERSION: &str = "v0.0.1:schema:definition-1";
const PROCESS_IDENTITY_PROTOCOL_VERSION: &str = "v0.0.1:risk-control:process-identity-1";
const CLIENT_FINGERPRINT_VERSION: &str = "v0.0.1:client:fingerprint-1";
const CLIENT_FINGERPRINT_FILE: &str = "client-fingerprint.json";
const CANONICAL_REQUEST_VERSION: &str = "LICO-PROCESS-IDENTITY-V1";
const MACOS_KEYCHAIN_SERVICE: &str = "com.licolite.client.process-identity";
const ED25519_SPKI_PREFIX: &[u8] = &[
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
];

struct ClaimToken {
    value: String,
    file_path: Option<String>,
}

pub fn bootstrap_claim(params: &Value) -> Result<Value> {
    let server_url = normalize_server_url(
        text_param(params, &["serverUrl", "server-url", "url", "baseUrl"])
            .ok_or_else(|| anyhow!("process identity bootstrap claim requires --server-url"))?,
    );
    let claim_token = claim_token(params)?;
    let default_identity_hash =
        text_param(params, &["defaultIdentityHash", "default-identity-hash"])
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| {
                anyhow!("process identity bootstrap claim requires --default-identity-hash")
            })?;
    let signing_key = SigningKey::generate(&mut OsRng);
    let verifying_key = VerifyingKey::from(&signing_key);
    let public_spki = ed25519_spki(verifying_key.as_bytes());
    let client_id = text_param(params, &["clientId", "client-id"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("client_{}", Uuid::new_v4()));
    let installation_id = text_param(params, &["installationId", "installation-id"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("install_{}", Uuid::new_v4()));
    let client_fingerprint = client_fingerprint(params)?;
    let body = json!({
        "claimToken": claim_token.value.clone(),
        "clientId": client_id,
        "installationId": installation_id,
        "clientFingerprint": client_fingerprint,
        "processPublicKeySpkiBase64": general_purpose::STANDARD.encode(&public_spki),
        "defaultIdentityHash": default_identity_hash,
        "nonce": format!("nonce_{}", Uuid::new_v4())
    });
    let response = post_json(
        &format!("{}/api/process-identity/bootstrap/claim", server_url),
        &body,
    )?;
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        return Ok(json!({
            "ok": false,
            "status": "claim_failed",
            "response": response
        }));
    }
    let package = response
        .get("clientIdentityPackage")
        .cloned()
        .ok_or_else(|| anyhow!("claim response is missing clientIdentityPackage"))?;
    let record = identity_record(
        &server_url,
        &signing_key,
        &public_spki,
        &package,
        response
            .get("serverIdentity")
            .cloned()
            .unwrap_or_else(|| json!({})),
    )?;
    save_identity_record(record.clone())?;
    remove_claim_token_file(&claim_token)?;
    Ok(json!({
        "ok": true,
        "protocolVersion": PROCESS_IDENTITY_PROTOCOL_VERSION,
        "status": "claimed",
        "identity": public_identity_record(&record),
        "clientIdentityPackage": redacted_identity_package(&package),
        "serverIdentity": response.get("serverIdentity").cloned().unwrap_or_else(|| json!({}))
    }))
}

pub fn sign_request(params: &Value) -> Result<Value> {
    let server_url = text_param(params, &["serverUrl", "server-url", "url", "baseUrl"]);
    let package_id = text_param(params, &["packageId", "package-id"]);
    let record = find_identity_record(server_url.as_deref(), package_id.as_deref())?;
    let package = record
        .get("clientIdentityPackage")
        .ok_or_else(|| anyhow!("identity record is missing clientIdentityPackage"))?;
    let secret = identity_secret_from_record(&record)?;
    let method = text_param(params, &["method"])
        .unwrap_or_else(|| "POST".to_string())
        .to_uppercase();
    let url = text_param(params, &["requestUrl", "request-url", "url", "path"])
        .ok_or_else(|| anyhow!("process identity request sign requires --request-url"))?;
    let body = request_body(params);
    let body_hash = sha256_hex(body.as_bytes());
    let timestamp = unix_seconds().to_string();
    let nonce =
        text_param(params, &["nonce"]).unwrap_or_else(|| format!("nonce_{}", Uuid::new_v4()));
    let process_key = package
        .get("processKey")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("identity package is missing processKey"))?;
    let process_key_id = process_key
        .get("processKeyId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let client_fingerprint = package.get("clientFingerprint").unwrap_or(&Value::Null);
    let canonical = canonical_request(
        &method,
        &path_with_query(&url),
        &body_hash,
        &timestamp,
        &nonce,
        package
            .get("clientId")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        package
            .get("packageId")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        process_key_id,
        client_fingerprint,
    );
    let signature = secret.signing_key.sign(canonical.as_bytes());
    let headers = json!({
        "X-LicoLite-Client-Id": package.get("clientId").cloned().unwrap_or_else(|| json!("")),
        "X-LicoLite-Identity-Package-Id": package.get("packageId").cloned().unwrap_or_else(|| json!("")),
        "X-LicoLite-Process-Key-Id": process_key_id,
        "X-LicoLite-Timestamp": timestamp,
        "X-LicoLite-Nonce": nonce,
        "X-LicoLite-Body-SHA256": body_hash,
        "X-LicoLite-Client-Fingerprint-Id": fingerprint_field(client_fingerprint, "fingerprintId"),
        "X-LicoLite-Machine-Instance-Id": fingerprint_field(client_fingerprint, "machineInstanceId"),
        "X-LicoLite-App-Instance-Id": fingerprint_field(client_fingerprint, "appInstanceId"),
        "X-LicoLite-Runtime-Instance-Id": fingerprint_field(client_fingerprint, "runtimeInstanceId"),
        "X-LicoLite-Client-Fingerprint-Hash": fingerprint_field(client_fingerprint, "fingerprintHash"),
        "X-LicoLite-Signature": general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes()),
        "X-LicoLite-Capability-Key": secret.capability_key
    });
    Ok(json!({
        "ok": true,
        "protocolVersion": PROCESS_IDENTITY_PROTOCOL_VERSION,
        "packageId": package.get("packageId").cloned().unwrap_or_else(|| json!("")),
        "pathWithQuery": path_with_query(&url),
        "bodySha256": body_hash,
        "headers": headers
    }))
}

pub fn status(params: &Value) -> Result<Value> {
    let server_url = text_param(params, &["serverUrl", "server-url", "url", "baseUrl"]);
    let package_id = text_param(params, &["packageId", "package-id"]);
    let record = find_identity_record(server_url.as_deref(), package_id.as_deref())?;
    Ok(json!({
        "ok": true,
        "protocolVersion": PROCESS_IDENTITY_PROTOCOL_VERSION,
        "identity": public_identity_record(&record)
    }))
}

fn claim_token(params: &Value) -> Result<ClaimToken> {
    if let Some(value) = text_param(params, &["claimToken", "claim-token"]) {
        if !value.trim().is_empty() {
            return Ok(ClaimToken {
                value: value.trim().to_string(),
                file_path: None,
            });
        }
    }
    if let Some(file_path) = text_param(params, &["claimTokenFile", "claim-token-file"]) {
        return claim_token_from_file(file_path);
    }
    if let Ok(value) = env::var("LICO_PROCESS_IDENTITY_CLAIM_TOKEN") {
        if !value.trim().is_empty() {
            return Ok(ClaimToken {
                value: value.trim().to_string(),
                file_path: None,
            });
        }
    }
    if let Ok(file_path) = env::var("LICO_PROCESS_IDENTITY_CLAIM_TOKEN_FILE") {
        return claim_token_from_file(file_path);
    }
    Err(anyhow!(
        "process identity bootstrap claim requires --claim-token or --claim-token-file"
    ))
}

fn claim_token_from_file(file_path: String) -> Result<ClaimToken> {
    let value = fs::read_to_string(&file_path)?.trim().to_string();
    if value.is_empty() {
        return Err(anyhow!("process identity claim token file is empty"));
    }
    Ok(ClaimToken {
        value,
        file_path: Some(file_path),
    })
}

fn remove_claim_token_file(claim_token: &ClaimToken) -> Result<()> {
    let Some(file_path) = claim_token.file_path.as_deref() else {
        return Ok(());
    };
    match fs::remove_file(file_path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(anyhow!(
            "failed to delete process identity claim token file {}: {}",
            file_path,
            error
        )),
    }
}

fn client_fingerprint(params: &Value) -> Result<Value> {
    if let Some(explicit) = params
        .get("clientFingerprint")
        .or_else(|| params.get("client-fingerprint"))
        .or_else(|| params.get("fingerprint"))
        .filter(|value| value.is_object())
    {
        return normalize_client_fingerprint(explicit, params);
    }

    let store = ClientStateStore::portable()?;
    let path = store.root().join(CLIENT_FINGERPRINT_FILE);
    let existing = read_json_or_empty(&path)?;
    let fingerprint = normalize_client_fingerprint(&existing, params)?;
    write_json_private(&path, &fingerprint)?;
    Ok(fingerprint)
}

fn normalize_client_fingerprint(source: &Value, params: &Value) -> Result<Value> {
    let created_at = source
        .get("createdAtUnix")
        .and_then(Value::as_u64)
        .unwrap_or_else(unix_seconds);
    let fingerprint_id = text_value(source, &["fingerprintId", "fingerprint-id"])
        .or_else(|| text_param(params, &["fingerprintId", "fingerprint-id"]))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("fp_{}", Uuid::new_v4()));
    let machine_instance_id = text_value(source, &["machineInstanceId", "machine-instance-id"])
        .or_else(|| text_param(params, &["machineInstanceId", "machine-instance-id"]))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("machine_{}", Uuid::new_v4()));
    let app_instance_id = text_value(source, &["appInstanceId", "app-instance-id"])
        .or_else(|| text_param(params, &["appInstanceId", "app-instance-id"]))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("app_{}", Uuid::new_v4()));
    let runtime_instance_id = text_param(params, &["runtimeInstanceId", "runtime-instance-id"])
        .or_else(|| text_value(source, &["runtimeInstanceId", "runtime-instance-id"]))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("runtime_{}", Uuid::new_v4()));
    let fingerprint_hash = client_fingerprint_hash(
        &fingerprint_id,
        &machine_instance_id,
        &app_instance_id,
        &runtime_instance_id,
    );

    Ok(json!({
        "schemaVersion": STATE_SCHEMA_VERSION,
        "protocolVersion": PROCESS_IDENTITY_PROTOCOL_VERSION,
        "fingerprintVersion": CLIENT_FINGERPRINT_VERSION,
        "fingerprintId": fingerprint_id,
        "machineInstanceId": machine_instance_id,
        "appInstanceId": app_instance_id,
        "runtimeInstanceId": runtime_instance_id,
        "fingerprintHash": fingerprint_hash,
        "createdAtUnix": created_at,
        "updatedAtUnix": unix_seconds()
    }))
}

fn client_fingerprint_hash(
    fingerprint_id: &str,
    machine_instance_id: &str,
    app_instance_id: &str,
    runtime_instance_id: &str,
) -> String {
    let payload = [
        CLIENT_FINGERPRINT_VERSION,
        fingerprint_id,
        machine_instance_id,
        app_instance_id,
        runtime_instance_id,
    ]
    .join("\n");
    format!("sha256:{}", sha256_base64url(payload.as_bytes()))
}

fn read_json_or_empty(path: &Path) -> Result<Value> {
    if !path.exists() {
        return Ok(json!({}));
    }
    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(json!({}));
    }
    Ok(serde_json::from_str(&raw)?)
}

fn write_json_private(path: &Path, value: &Value) -> Result<()> {
    atomic_write_private_text(path, &format!("{}\n", serde_json::to_string_pretty(value)?))
}

fn post_json(url: &str, body: &Value) -> Result<Value> {
    let response = ureq::post(url)
        .set("Content-Type", "application/json")
        .send_string(&serde_json::to_string(body)?)?;
    Ok(response.into_json::<Value>()?)
}

fn identity_record(
    server_url: &str,
    signing_key: &SigningKey,
    public_spki: &[u8],
    package: &Value,
    server_identity: Value,
) -> Result<Value> {
    let process_key = package
        .get("processKey")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("identity package is missing processKey"))?;
    let package_id = package
        .get("packageId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("identity package is missing packageId"))?;
    let secret_ref = store_identity_secret(package_id, signing_key, package)?;
    Ok(json!({
        "schemaVersion": STATE_SCHEMA_VERSION,
        "protocolVersion": PROCESS_IDENTITY_PROTOCOL_VERSION,
        "serverUrl": server_url,
        "serverId": package.get("serverId").cloned().unwrap_or_else(|| json!("")),
        "serverTrustPin": package.get("serverTrustPin").cloned().unwrap_or_else(|| json!("")),
        "clientId": package.get("clientId").cloned().unwrap_or_else(|| json!("")),
        "installationId": package.get("installationId").cloned().unwrap_or_else(|| json!("")),
        "clientFingerprint": package.get("clientFingerprint").cloned().unwrap_or_else(|| json!({})),
        "packageId": package.get("packageId").cloned().unwrap_or_else(|| json!("")),
        "processKeyId": process_key.get("processKeyId").cloned().unwrap_or_else(|| json!("")),
        "processPublicKeyHash": process_key.get("publicKeyHash").cloned().unwrap_or_else(|| json!("")),
        "processPublicKeySpkiBase64": general_purpose::STANDARD.encode(public_spki),
        "secretStorage": secret_ref,
        "clientIdentityPackage": redacted_identity_package(package),
        "serverIdentity": server_identity,
        "active": true,
        "importedAtUnix": unix_seconds()
    }))
}

fn save_identity_record(record: Value) -> Result<()> {
    let store = ClientStateStore::portable()?;
    let mut document = store.read_collection("identities")?;
    let items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|item| {
            if item.get("serverUrl") == record.get("serverUrl") {
                let mut old = item.as_object().cloned().unwrap_or_default();
                old.insert("active".to_string(), json!(false));
                Value::Object(old)
            } else {
                item
            }
        })
        .chain(std::iter::once(record.clone()))
        .collect::<Vec<_>>();
    document["schemaVersion"] = json!(STATE_SCHEMA_VERSION);
    document["collection"] = json!("identities");
    document["activePackageId"] = record
        .get("packageId")
        .cloned()
        .unwrap_or_else(|| json!(""));
    document["items"] = Value::Array(items);
    store.write_collection("identities", document)?;
    store.activity_log().append(
        "process_identity.package.imported",
        json!({
            "target": record.get("serverUrl").and_then(Value::as_str).unwrap_or(""),
            "packageId": record.get("packageId").cloned().unwrap_or_else(|| json!(""))
        }),
    )?;
    Ok(())
}

fn find_identity_record(server_url: Option<&str>, package_id: Option<&str>) -> Result<Value> {
    let store = ClientStateStore::portable()?;
    let document = store.read_collection("identities")?;
    let normalized_url = server_url.map(normalize_server_url);
    let active_package_id = document
        .get("activePackageId")
        .and_then(Value::as_str)
        .unwrap_or("");
    let items = document
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("client identity store is empty"))?;
    items
        .iter()
        .find(|item| {
            let package_matches = package_id
                .map(|expected| item.get("packageId").and_then(Value::as_str) == Some(expected))
                .unwrap_or_else(|| {
                    active_package_id.is_empty()
                        || item.get("packageId").and_then(Value::as_str) == Some(active_package_id)
                });
            let server_matches = normalized_url
                .as_deref()
                .map(|expected| item.get("serverUrl").and_then(Value::as_str) == Some(expected))
                .unwrap_or(true);
            package_matches
                && server_matches
                && item.get("active").and_then(Value::as_bool).unwrap_or(false)
        })
        .cloned()
        .ok_or_else(|| anyhow!("matching process identity package was not found"))
}

fn public_identity_record(record: &Value) -> Value {
    json!({
        "serverUrl": record.get("serverUrl").cloned().unwrap_or_else(|| json!("")),
        "serverId": record.get("serverId").cloned().unwrap_or_else(|| json!("")),
        "serverTrustPin": record.get("serverTrustPin").cloned().unwrap_or_else(|| json!("")),
        "clientId": record.get("clientId").cloned().unwrap_or_else(|| json!("")),
        "installationId": record.get("installationId").cloned().unwrap_or_else(|| json!("")),
        "clientFingerprint": record.get("clientFingerprint").cloned().unwrap_or_else(|| json!({})),
        "packageId": record.get("packageId").cloned().unwrap_or_else(|| json!("")),
        "processKeyId": record.get("processKeyId").cloned().unwrap_or_else(|| json!("")),
        "processPublicKeyHash": record.get("processPublicKeyHash").cloned().unwrap_or_else(|| json!("")),
        "secretStorage": public_secret_storage(record.get("secretStorage").unwrap_or(&Value::Null)),
        "active": record.get("active").cloned().unwrap_or_else(|| json!(false)),
        "importedAtUnix": record.get("importedAtUnix").cloned().unwrap_or_else(|| json!(0))
    })
}

fn redacted_identity_package(package: &Value) -> Value {
    let mut redacted = package.as_object().cloned().unwrap_or_default();
    if let Some(capability) = redacted
        .get_mut("capability")
        .and_then(Value::as_object_mut)
    {
        if capability.get("key").is_some() {
            capability.insert("key".to_string(), json!("[redacted]"));
        }
    }
    Value::Object(redacted)
}

struct IdentitySecret {
    signing_key: SigningKey,
    capability_key: String,
}

fn identity_secret_from_record(record: &Value) -> Result<IdentitySecret> {
    if let Some(secret_ref) = record.get("secretStorage").and_then(Value::as_object) {
        if secret_ref.get("backend").and_then(Value::as_str) == Some("macos-keychain") {
            #[cfg(target_os = "macos")]
            {
                let service = secret_ref
                    .get("service")
                    .and_then(Value::as_str)
                    .unwrap_or(MACOS_KEYCHAIN_SERVICE);
                let account = secret_ref
                    .get("account")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("macOS keychain secret ref is missing account"))?;
                let raw = read_macos_keychain_secret(service, account)?;
                return parse_secret_payload(&raw);
            }
            #[cfg(not(target_os = "macos"))]
            {
                return Err(anyhow!(
                    "macOS keychain process identity secret is not readable on this platform"
                ));
            }
        }
        if secret_ref.get("backend").and_then(Value::as_str) == Some("portable-state-file") {
            if let Some(payload) = secret_ref.get("payload").and_then(Value::as_str) {
                return parse_secret_payload(payload);
            }
        }
    }
    let raw_private = record
        .get("processPrivateKeyRawBase64")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("identity record is missing process private key"))?;
    let capability_key = record
        .get("clientIdentityPackage")
        .and_then(|value| value.get("capability"))
        .and_then(|value| value.get("key"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    signing_key_from_raw_base64(raw_private).map(|signing_key| IdentitySecret {
        signing_key,
        capability_key,
    })
}

fn parse_secret_payload(raw: &str) -> Result<IdentitySecret> {
    let payload: Value = serde_json::from_str(raw)?;
    let private_raw = payload
        .get("processPrivateKeyRawBase64")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("process identity secret is missing private key"))?;
    let capability_key = payload
        .get("capabilityKey")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let signing_key = signing_key_from_raw_base64(private_raw)?;
    Ok(IdentitySecret {
        signing_key,
        capability_key,
    })
}

fn signing_key_from_raw_base64(raw: &str) -> Result<SigningKey> {
    let bytes = general_purpose::STANDARD.decode(raw)?;
    let array: [u8; 32] = bytes
        .try_into()
        .map_err(|_| anyhow!("process private key must be 32 bytes"))?;
    Ok(SigningKey::from_bytes(&array))
}

fn store_identity_secret(
    package_id: &str,
    signing_key: &SigningKey,
    package: &Value,
) -> Result<Value> {
    let capability_key = package
        .get("capability")
        .and_then(|value| value.get("key"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let payload = json!({
        "schemaVersion": STATE_SCHEMA_VERSION,
        "protocolVersion": PROCESS_IDENTITY_PROTOCOL_VERSION,
        "packageId": package_id,
        "processPrivateKeyRawBase64": general_purpose::STANDARD.encode(signing_key.to_bytes()),
        "capabilityKey": capability_key
    });
    let payload_text = serde_json::to_string(&payload)?;
    #[cfg(target_os = "macos")]
    {
        let account = macos_keychain_account(package_id);
        match write_macos_keychain_secret(MACOS_KEYCHAIN_SERVICE, &account, &payload_text) {
            Ok(()) => {
                return Ok(json!({
                    "backend": "macos-keychain",
                    "service": MACOS_KEYCHAIN_SERVICE,
                    "account": account,
                    "degraded": false
                }));
            }
            Err(error) => {
                return Ok(json!({
                    "backend": "portable-state-file",
                    "degraded": true,
                    "reason": format!("macos-keychain-unavailable: {}", error),
                    "payload": payload_text
                }));
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(json!({
            "backend": "portable-state-file",
            "degraded": true,
            "reason": "system-keyring-backend-not-configured-for-this-platform",
            "payload": payload_text
        }))
    }
}

fn public_secret_storage(value: &Value) -> Value {
    let source = value.as_object().cloned().unwrap_or_default();
    json!({
        "backend": source.get("backend").cloned().unwrap_or_else(|| json!("portable-state-file")),
        "service": source.get("service").cloned().unwrap_or_else(|| json!("")),
        "account": source.get("account").cloned().unwrap_or_else(|| json!("")),
        "degraded": source.get("degraded").cloned().unwrap_or_else(|| json!(true)),
        "reason": source.get("reason").cloned().unwrap_or_else(|| json!(""))
    })
}

#[cfg(target_os = "macos")]
fn macos_keychain_account(package_id: &str) -> String {
    format!("lico-process-identity:{}", package_id)
}

#[cfg(target_os = "macos")]
fn write_macos_keychain_secret(service: &str, account: &str, payload: &str) -> Result<()> {
    let status = Command::new("/usr/bin/security")
        .args([
            "add-generic-password",
            "-U",
            "-a",
            account,
            "-s",
            service,
            "-w",
            payload,
        ])
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!(
            "security add-generic-password exited with {}",
            status
        ))
    }
}

#[cfg(target_os = "macos")]
fn read_macos_keychain_secret(service: &str, account: &str) -> Result<String> {
    let output = Command::new("/usr/bin/security")
        .args(["find-generic-password", "-w", "-a", account, "-s", service])
        .output()?;
    if !output.status.success() {
        return Err(anyhow!(
            "security find-generic-password exited with {}",
            output.status
        ));
    }
    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}

fn ed25519_spki(raw_public_key: &[u8; 32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(ED25519_SPKI_PREFIX.len() + raw_public_key.len());
    out.extend_from_slice(ED25519_SPKI_PREFIX);
    out.extend_from_slice(raw_public_key);
    out
}

fn canonical_request(
    method: &str,
    path_with_query: &str,
    body_hash: &str,
    timestamp: &str,
    nonce: &str,
    client_id: &str,
    package_id: &str,
    process_key_id: &str,
    client_fingerprint: &Value,
) -> String {
    let mut parts = vec![
        CANONICAL_REQUEST_VERSION.to_string(),
        method.to_string(),
        path_with_query.to_string(),
        body_hash.to_string(),
        timestamp.to_string(),
        nonce.to_string(),
        client_id.to_string(),
        package_id.to_string(),
        process_key_id.to_string(),
    ];
    let fingerprint_parts = [
        fingerprint_field(client_fingerprint, "fingerprintId"),
        fingerprint_field(client_fingerprint, "machineInstanceId"),
        fingerprint_field(client_fingerprint, "appInstanceId"),
        fingerprint_field(client_fingerprint, "runtimeInstanceId"),
        fingerprint_field(client_fingerprint, "fingerprintHash"),
    ];
    if fingerprint_parts.iter().any(|value| !value.is_empty()) {
        parts.extend(fingerprint_parts);
    }
    parts.join("\n")
}

fn request_body(params: &Value) -> String {
    if let Some(value) = text_param(params, &["bodyText", "body-text"]) {
        return value;
    }
    if let Some(value) = params.get("body") {
        return if value.is_string() {
            value.as_str().unwrap_or_default().to_string()
        } else {
            serde_json::to_string(value).unwrap_or_else(|_| "{}".to_string())
        };
    }
    "{}".to_string()
}

fn path_with_query(url: &str) -> String {
    let trimmed = url.trim();
    if trimmed.starts_with('/') {
        return trimmed.to_string();
    }
    if let Some(scheme_index) = trimmed.find("://") {
        let after_scheme = &trimmed[(scheme_index + 3)..];
        if let Some(path_index) = after_scheme.find('/') {
            return after_scheme[path_index..].to_string();
        }
    }
    "/".to_string()
}

fn normalize_server_url(value: impl AsRef<str>) -> String {
    value.as_ref().trim().trim_end_matches('/').to_string()
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str).map(str::to_string))
}

fn text_value(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str).map(str::to_string))
}

fn fingerprint_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn sha256_hex(value: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value);
    format!("{:x}", hasher.finalize())
}

fn sha256_base64url(value: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value);
    general_purpose::URL_SAFE_NO_PAD.encode(hasher.finalize())
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spki_prefix_matches_ed25519_public_key_length() {
        let signing_key = SigningKey::generate(&mut OsRng);
        let verifying_key = VerifyingKey::from(&signing_key);
        let spki = ed25519_spki(verifying_key.as_bytes());
        assert_eq!(spki.len(), 44);
        assert_eq!(&spki[..ED25519_SPKI_PREFIX.len()], ED25519_SPKI_PREFIX);
    }

    #[test]
    fn path_with_query_extracts_http_path() {
        assert_eq!(
            path_with_query("http://127.0.0.1:1234/api/process-identity/package/rotate?a=1"),
            "/api/process-identity/package/rotate?a=1"
        );
        assert_eq!(path_with_query("/api/local"), "/api/local");
    }

    #[test]
    fn canonical_request_keeps_current_shape_without_fingerprint() {
        let canonical = canonical_request(
            "POST",
            "/api/process-identity/package/rotate",
            "body-hash",
            "123",
            "nonce-a",
            "client-a",
            "package-a",
            "process-key-a",
            &json!({}),
        );
        assert_eq!(
            canonical,
            [
                CANONICAL_REQUEST_VERSION,
                "POST",
                "/api/process-identity/package/rotate",
                "body-hash",
                "123",
                "nonce-a",
                "client-a",
                "package-a",
                "process-key-a"
            ]
            .join("\n")
        );
    }

    #[test]
    fn canonical_request_includes_client_fingerprint_when_present() {
        let fingerprint = json!({
            "fingerprintId": "fp-a",
            "machineInstanceId": "machine-a",
            "appInstanceId": "app-a",
            "runtimeInstanceId": "runtime-a",
            "fingerprintHash": "sha256:fingerprint-a"
        });
        let canonical = canonical_request(
            "POST",
            "/api/process-identity/package/rotate",
            "body-hash",
            "123",
            "nonce-a",
            "client-a",
            "package-a",
            "process-key-a",
            &fingerprint,
        );
        assert!(
            canonical.ends_with(
                "process-key-a\nfp-a\nmachine-a\napp-a\nruntime-a\nsha256:fingerprint-a"
            )
        );
    }

    #[test]
    fn claim_token_file_is_removed_after_consumption() {
        let dir = env::temp_dir().join(format!("lico-claim-token-{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        let token_path = dir.join("claim.token");
        let token_path_string = token_path.to_string_lossy().to_string();
        fs::write(&token_path, "claim-token-test\n").unwrap();
        let token = claim_token(&json!({
            "claimTokenFile": token_path_string.clone()
        }))
        .unwrap();

        assert_eq!(token.value, "claim-token-test");
        assert_eq!(token.file_path.as_deref(), Some(token_path_string.as_str()));

        remove_claim_token_file(&token).unwrap();
        assert!(!token_path.exists());
        fs::remove_dir_all(&dir).ok();
    }
}
