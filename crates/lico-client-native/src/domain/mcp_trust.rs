use anyhow::{Result, anyhow};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use ed25519_dalek::{Signature, SigningKey, Verifier, VerifyingKey};
use serde::Deserialize;
use serde_json::{Value, json};
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

const RECEIPT_KIND: &str = "lico.mcp.trust-receipt.v1";

#[derive(Debug, PartialEq, Clone)]
pub enum VerificationStatus {
    Verified,
    Unverified,
    Missing,
    VerificationRequired,
    InvalidReceipt,
    ExpiredReceipt,
    EndpointMismatch,
    UntrustedPublicKey,
}

impl VerificationStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            VerificationStatus::Verified => "verified",
            VerificationStatus::Unverified => "unverified",
            VerificationStatus::Missing => "missing",
            VerificationStatus::VerificationRequired => "verification_required",
            VerificationStatus::InvalidReceipt => "invalid_receipt",
            VerificationStatus::ExpiredReceipt => "expired_receipt",
            VerificationStatus::EndpointMismatch => "endpoint_mismatch",
            VerificationStatus::UntrustedPublicKey => "untrusted_public_key",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustReceipt {
    pub schema_version: u32,
    pub kind: String,
    pub endpoint: String,
    pub mcp_url: String,
    pub server_identity: ServerIdentity,
    pub issued_at: String,
    pub expires_at: String,
    pub handshake: HandshakeData,
    pub signature: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerIdentity {
    pub key_id: String,
    pub public_key_ed25519: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HandshakeData {
    pub nonce: String,
    pub service: String,
    pub version: String,
}

pub struct EndpointVerification {
    pub endpoint: String,
    pub source: String,
    pub status: VerificationStatus,
    pub reason: String,
}

#[derive(Clone)]
pub struct VerifyEnv {
    pub dev_allow_unverified_mcp: Option<String>,
    pub pinned_public_key: Option<String>,
}

impl VerifyEnv {
    pub fn from_real_env() -> Self {
        Self {
            dev_allow_unverified_mcp: std::env::var("LICO_CLIENT_DEV_ALLOW_UNVERIFIED_MCP").ok(),
            pinned_public_key: None,
        }
    }

    pub fn empty() -> Self {
        Self {
            dev_allow_unverified_mcp: None,
            pinned_public_key: None,
        }
    }

    pub fn with_pinned_key(key: String) -> Self {
        Self {
            dev_allow_unverified_mcp: None,
            pinned_public_key: Some(key),
        }
    }

    pub fn dev_bypass_enabled(&self) -> bool {
        self.dev_allow_unverified_mcp.as_deref() == Some("1")
    }
}

pub fn resolve_and_verify_endpoint(params: &Value) -> Result<EndpointVerification> {
    resolve_and_verify_endpoint_with_env(params, &VerifyEnv::from_real_env())
}

pub fn resolve_and_verify_endpoint_with_env(
    params: &Value,
    env: &VerifyEnv,
) -> Result<EndpointVerification> {
    let endpoint = extract_endpoint(params);

    if endpoint.is_empty() {
        return Ok(EndpointVerification {
            endpoint: "http://127.0.0.1:7228".to_string(),
            source: "default".to_string(),
            status: VerificationStatus::Missing,
            reason: "No MCP endpoint configured; use --base-url, --discovery-file, --registry-file, or environment".to_string(),
        });
    }

    let status = verify_endpoint_trust_with_env(&endpoint, params, env);
    let source = endpoint_source(params);

    Ok(EndpointVerification {
        endpoint,
        source,
        status,
        reason: String::new(),
    })
}

// Pure function for testing - does not read env directly
pub fn verify_endpoint_trust_with_env(
    endpoint: &str,
    params: &Value,
    env: &VerifyEnv,
) -> VerificationStatus {
    if env.dev_bypass_enabled() {
        return VerificationStatus::Unverified;
    }

    if let Some(status) = verify_endpoint_via_receipt(endpoint, params, env) {
        return status;
    }

    VerificationStatus::VerificationRequired
}

fn verify_endpoint_via_receipt(
    endpoint: &str,
    params: &Value,
    env: &VerifyEnv,
) -> Option<VerificationStatus> {
    let pinned_key = resolve_pinned_key(params, env);

    let check_file = |path_key: &str| -> Option<VerificationStatus> {
        let file_path = params.get(path_key).and_then(Value::as_str)?;
        let json_str = fs::read_to_string(file_path).ok()?;
        let json: Value = serde_json::from_str(&json_str).ok()?;

        let receipt = extract_receipt_from_json(&json)?;
        verify_trust_receipt(endpoint, &receipt, pinned_key.as_deref())
    };

    if let Some(status) = check_file("discoveryFile") {
        return Some(status);
    }

    if let Some(status) = check_file("registryFile") {
        return Some(status);
    }

    None
}

fn resolve_pinned_key(params: &Value, env: &VerifyEnv) -> Option<String> {
    if let Some(key) = &env.pinned_public_key {
        let trimmed = key.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    if let Some(key) = params.get("pinnedKey").and_then(Value::as_str) {
        let trimmed = key.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    let read_pinned_from_file = |path_key: &str| -> Option<String> {
        let file_path = params.get(path_key).and_then(Value::as_str)?;
        let json_str = fs::read_to_string(file_path).ok()?;
        let json: Value = serde_json::from_str(&json_str).ok()?;
        json.get("pinnedPublicKey")
            .and_then(Value::as_str)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    };
    if let Some(key) = read_pinned_from_file("discoveryFile") {
        return Some(key);
    }
    if let Some(key) = read_pinned_from_file("registryFile") {
        return Some(key);
    }
    None
}

fn extract_receipt_from_json(json: &Value) -> Option<TrustReceipt> {
    if let Some(receipt) = json.get("trustReceipt") {
        if let Ok(receipt) = serde_json::from_value::<TrustReceipt>(receipt.clone()) {
            return Some(receipt);
        }
    }
    serde_json::from_value::<TrustReceipt>(json.clone()).ok()
}

fn verify_trust_receipt(
    endpoint: &str,
    receipt: &TrustReceipt,
    pinned_key: Option<&str>,
) -> Option<VerificationStatus> {
    if receipt.kind != RECEIPT_KIND {
        return Some(VerificationStatus::InvalidReceipt);
    }

    if receipt.schema_version != 1 {
        return Some(VerificationStatus::InvalidReceipt);
    }

    let normalized_endpoint = normalize_endpoint(endpoint);
    let receipt_endpoint = normalize_endpoint(&receipt.endpoint);
    let receipt_mcp_url = normalize_endpoint(&receipt.mcp_url);

    if normalized_endpoint != receipt_endpoint && normalized_endpoint != receipt_mcp_url {
        return Some(VerificationStatus::EndpointMismatch);
    }

    if is_expired(&receipt.expires_at) {
        return Some(VerificationStatus::ExpiredReceipt);
    }

    let public_key_bytes = match BASE64.decode(&receipt.server_identity.public_key_ed25519) {
        Ok(bytes) if bytes.len() == 32 => bytes,
        _ => return Some(VerificationStatus::InvalidReceipt),
    };

    if let Some(pinned) = pinned_key {
        if pinned != receipt.server_identity.public_key_ed25519.trim() {
            return Some(VerificationStatus::UntrustedPublicKey);
        }
    } else {
        return Some(VerificationStatus::UntrustedPublicKey);
    }

    let verifying_key = VerifyingKey::from_bytes(&public_key_bytes[..32].try_into().ok()?).ok()?;

    let signature_bytes = match BASE64.decode(&receipt.signature) {
        Ok(bytes) if bytes.len() == 64 => bytes,
        _ => return Some(VerificationStatus::InvalidReceipt),
    };

    let signature = Signature::from_bytes(&signature_bytes[..64].try_into().ok()?);

    let canonical_payload = build_canonical_payload(receipt);
    if verifying_key
        .verify(canonical_payload.as_bytes(), &signature)
        .is_ok()
    {
        Some(VerificationStatus::Verified)
    } else {
        Some(VerificationStatus::InvalidReceipt)
    }
}

fn build_canonical_payload(receipt: &TrustReceipt) -> String {
    format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        receipt.endpoint,
        receipt.mcp_url,
        receipt.server_identity.key_id,
        receipt.issued_at,
        receipt.expires_at,
        receipt.handshake.nonce,
        receipt.handshake.service,
        receipt.handshake.version,
    )
}

fn is_expired(expires_at: &str) -> bool {
    if let Ok(expires) = chrono_like_parse(expires_at) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        now > expires
    } else {
        false
    }
}

fn chrono_like_parse(s: &str) -> Result<u64> {
    if s.len() >= 19 && s.as_bytes().get(4) == Some(&b'-') {
        let year: u64 = s[0..4].parse().map_err(|_| anyhow!("bad year"))?;
        let month: u64 = s[5..7].parse().map_err(|_| anyhow!("bad month"))?;
        let day: u64 = s[8..10].parse().map_err(|_| anyhow!("bad day"))?;
        let hour: u64 = s[11..13].parse().map_err(|_| anyhow!("bad hour"))?;
        let minute: u64 = s[14..16].parse().map_err(|_| anyhow!("bad minute"))?;
        let second: u64 = s[17..19].parse().map_err(|_| anyhow!("bad second"))?;
        let days_before_month = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
        let leap = if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
            1
        } else {
            0
        };
        let day_of_year = days_before_month
            .get((month as usize).saturating_sub(1))
            .unwrap_or(&0)
            + day
            + if month > 2 { leap } else { 0 }
            - 1;
        let days =
            (year - 1970) * 365 + ((year - 1) / 4 - (year - 1) / 100 + (year - 1) / 400) - 477;
        Ok((days + day_of_year) * 86400 + hour * 3600 + minute * 60 + second)
    } else {
        Err(anyhow!("bad timestamp format"))
    }
}

fn extract_endpoint(params: &Value) -> String {
    if let Some(url) = params.get("baseUrl").and_then(Value::as_str) {
        return url.to_string();
    }

    if let Ok(url) = std::env::var("LICO_CLIENT_MCP_URL") {
        if !url.trim().is_empty() {
            return url.trim().to_string();
        }
    }

    let check_file_endpoint = |path_key: &str| -> Option<String> {
        let file_path = params.get(path_key).and_then(Value::as_str)?;
        let json_str = fs::read_to_string(file_path).ok()?;
        let json: Value = serde_json::from_str(&json_str).ok()?;
        extract_url_from_json(&json)
    };

    if let Some(url) = check_file_endpoint("discoveryFile") {
        return url;
    }

    if let Some(url) = check_file_endpoint("registryFile") {
        return url;
    }

    String::new()
}

fn extract_url_from_json(json: &Value) -> Option<String> {
    for key in ["httpUrl", "mcpUrl", "url", "baseUrl", "endpoint"] {
        if let Some(url) = json.get(key).and_then(Value::as_str) {
            let trimmed = url.trim().trim_end_matches('/');
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    if let Some(active_server) = json.get("activeServer").and_then(Value::as_str) {
        if let Some(server) = json.get("servers").and_then(|s| s.get(active_server)) {
            if let Some(url) = extract_url_from_json(server) {
                return Some(url);
            }
        }
    }
    None
}

fn endpoint_source(params: &Value) -> String {
    if params.get("baseUrl").is_some() {
        "params".to_string()
    } else if params.get("discoveryFile").is_some() {
        "discovery-file".to_string()
    } else if params.get("registryFile").is_some() {
        "registry-file".to_string()
    } else if std::env::var("LICO_CLIENT_MCP_URL").is_ok() {
        "environment".to_string()
    } else {
        "default".to_string()
    }
}

fn normalize_endpoint(endpoint: &str) -> String {
    let trimmed = endpoint.trim().trim_end_matches('/');
    if let Some(stripped) = trimmed.strip_suffix("/mcp") {
        stripped.to_string()
    } else {
        trimmed.to_string()
    }
}

#[doc(hidden)]
pub fn test_signed_receipt(
    endpoint: &str,
    mcp_url: &str,
    key_id: &str,
    issued_at: &str,
    expires_at: &str,
    secret_bytes: &[u8; 32],
) -> (Value, String) {
    use ed25519_dalek::Signer;

    let secret = ed25519_dalek::SecretKey::from(*secret_bytes);
    let signing_key = SigningKey::from_bytes(&secret);
    let verifying_key = signing_key.verifying_key();
    let public_key_b64 = BASE64.encode(verifying_key.as_bytes());

    let handshake = json!({
        "nonce": "test-nonce",
        "service": "lico-mcp",
        "version": "1.0.0"
    });

    let canonical = format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        endpoint, mcp_url, key_id, issued_at, expires_at, "test-nonce", "lico-mcp", "1.0.0"
    );

    let signature = signing_key.sign(canonical.as_bytes());
    let signature_b64 = BASE64.encode(signature.to_bytes());

    let receipt = json!({
        "schemaVersion": 1,
        "kind": "lico.mcp.trust-receipt.v1",
        "endpoint": endpoint,
        "mcpUrl": mcp_url,
        "serverIdentity": {
            "keyId": key_id,
            "publicKeyEd25519": public_key_b64
        },
        "issuedAt": issued_at,
        "expiresAt": expires_at,
        "handshake": handshake,
        "signature": signature_b64
    });
    (receipt, public_key_b64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;
    use std::fs;
    use std::path::PathBuf;

    fn temp_test_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("lico-trust-tests-{}", name));
        let _ = fs::create_dir_all(&dir);
        dir
    }

    fn test_signing_key() -> SigningKey {
        use ed25519_dalek::SecretKey;
        use rand::RngCore;
        let mut bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);
        let secret = SecretKey::from(bytes);
        SigningKey::from_bytes(&secret)
    }

    #[test]
    fn resolve_missing_endpoint_returns_missing_status() {
        let env = VerifyEnv::empty();
        let result = resolve_and_verify_endpoint_with_env(&json!({}), &env).unwrap();
        assert_eq!(result.status, VerificationStatus::Missing);
        assert_eq!(result.source, "default");
    }

    #[test]
    fn resolve_with_base_url_returns_verification_required() {
        let env = VerifyEnv::empty();
        let result = resolve_and_verify_endpoint_with_env(
            &json!({"baseUrl": "http://127.0.0.1:8888"}),
            &env,
        )
        .unwrap();
        assert_eq!(result.status, VerificationStatus::VerificationRequired);
        assert_eq!(result.endpoint, "http://127.0.0.1:8888");
        assert_eq!(result.source, "params");
    }

    #[test]
    fn forged_handshake_verified_bool_is_not_trusted() {
        let dir = temp_test_dir("forged-handshake");
        let discovery_path = dir.join("discovery.json");
        fs::write(
            &discovery_path,
            r#"{"url": "http://127.0.0.1:9999", "hsVerified": true}"#,
        )
        .unwrap();

        let env = VerifyEnv::empty();
        let result = resolve_and_verify_endpoint_with_env(
            &json!({"discoveryFile": discovery_path.to_string_lossy().to_string()}),
            &env,
        )
        .unwrap();

        assert_eq!(result.status, VerificationStatus::VerificationRequired);
        assert_eq!(result.endpoint, "http://127.0.0.1:9999");
    }

    #[test]
    fn forged_metadata_signature_is_not_trusted() {
        let dir = temp_test_dir("forged-signature");
        let discovery_path = dir.join("discovery.json");
        fs::write(
            &discovery_path,
            r#"{"url": "http://127.0.0.1:7777", "metadata": {"signature": "fake-base64"}}"#,
        )
        .unwrap();

        let env = VerifyEnv::empty();
        let result = resolve_and_verify_endpoint_with_env(
            &json!({"registryFile": discovery_path.to_string_lossy().to_string()}),
            &env,
        )
        .unwrap();

        assert_eq!(result.status, VerificationStatus::VerificationRequired);
    }

    #[test]
    fn valid_signed_receipt_is_verified() {
        let dir = temp_test_dir("valid-receipt");
        let discovery_path = dir.join("discovery.json");

        let signing_key = test_signing_key();
        let secret_bytes = signing_key.to_bytes();

        let (receipt, public_key_b64) = test_signed_receipt(
            "http://127.0.0.1:7228",
            "http://127.0.0.1:7228/mcp",
            "lico-server-key-1",
            "2026-06-09T00:00:00Z",
            "2099-01-01T00:00:00Z",
            &secret_bytes,
        );

        let doc = json!({
            "url": "http://127.0.0.1:7228",
            "trustReceipt": receipt
        });
        fs::write(&discovery_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

        let env = VerifyEnv::with_pinned_key(public_key_b64);
        let result = resolve_and_verify_endpoint_with_env(
            &json!({"discoveryFile": discovery_path.to_string_lossy().to_string()}),
            &env,
        )
        .unwrap();

        assert_eq!(result.status, VerificationStatus::Verified);
        assert_eq!(result.endpoint, "http://127.0.0.1:7228");
        assert_eq!(result.source, "discovery-file");
    }

    #[test]
    fn receipt_without_pinned_key_returns_untrusted_public_key() {
        let dir = temp_test_dir("no-pinned-key");
        let discovery_path = dir.join("discovery.json");

        let signing_key = test_signing_key();
        let secret_bytes = signing_key.to_bytes();

        let (receipt, _public_key) = test_signed_receipt(
            "http://127.0.0.1:7228",
            "http://127.0.0.1:7228/mcp",
            "lico-server-key-1",
            "2026-06-09T00:00:00Z",
            "2099-01-01T00:00:00Z",
            &secret_bytes,
        );

        let doc = json!({
            "url": "http://127.0.0.1:7228",
            "trustReceipt": receipt
        });
        fs::write(&discovery_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

        let env = VerifyEnv::empty();
        let result = resolve_and_verify_endpoint_with_env(
            &json!({"discoveryFile": discovery_path.to_string_lossy().to_string()}),
            &env,
        )
        .unwrap();

        assert_eq!(result.status, VerificationStatus::UntrustedPublicKey);
    }

    #[test]
    fn receipt_with_wrong_pinned_key_returns_untrusted() {
        let dir = temp_test_dir("wrong-pinned");
        let discovery_path = dir.join("discovery.json");

        let signing_key = test_signing_key();
        let secret_bytes = signing_key.to_bytes();

        let (receipt, _public_key) = test_signed_receipt(
            "http://127.0.0.1:7228",
            "http://127.0.0.1:7228/mcp",
            "lico-server-key-1",
            "2026-06-09T00:00:00Z",
            "2099-01-01T00:00:00Z",
            &secret_bytes,
        );

        let doc = json!({
            "url": "http://127.0.0.1:7228",
            "trustReceipt": receipt
        });
        fs::write(&discovery_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

        let env = VerifyEnv::with_pinned_key("not-the-real-key-base64-encoded".to_string());
        let result = resolve_and_verify_endpoint_with_env(
            &json!({"discoveryFile": discovery_path.to_string_lossy().to_string()}),
            &env,
        )
        .unwrap();

        assert_eq!(result.status, VerificationStatus::UntrustedPublicKey);
    }

    #[test]
    fn receipt_with_pinned_key_from_params_is_verified() {
        let dir = temp_test_dir("pinned-key-params");
        let discovery_path = dir.join("discovery.json");

        let signing_key = test_signing_key();
        let secret_bytes = signing_key.to_bytes();

        let (receipt, public_key_b64) = test_signed_receipt(
            "http://127.0.0.1:7228",
            "http://127.0.0.1:7228/mcp",
            "lico-server-key-1",
            "2026-06-09T00:00:00Z",
            "2099-01-01T00:00:00Z",
            &secret_bytes,
        );

        let doc = json!({
            "url": "http://127.0.0.1:7228",
            "trustReceipt": receipt
        });
        fs::write(&discovery_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

        let env = VerifyEnv::empty();
        let result = resolve_and_verify_endpoint_with_env(
            &json!({
                "discoveryFile": discovery_path.to_string_lossy().to_string(),
                "pinnedKey": public_key_b64
            }),
            &env,
        )
        .unwrap();

        assert_eq!(result.status, VerificationStatus::Verified);
    }

    #[test]
    fn receipt_endpoint_mismatch_returns_endpoint_mismatch() {
        let dir = temp_test_dir("endpoint-mismatch");
        let discovery_path = dir.join("discovery.json");

        let signing_key = test_signing_key();
        let secret_bytes = signing_key.to_bytes();

        let (receipt, public_key) = test_signed_receipt(
            "http://other.local:7228",
            "http://other.local:7228/mcp",
            "lico-server-key-1",
            "2026-06-09T00:00:00Z",
            "2099-01-01T00:00:00Z",
            &secret_bytes,
        );

        let doc = json!({
            "url": "http://127.0.0.1:7228",
            "trustReceipt": receipt
        });
        fs::write(&discovery_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

        let env = VerifyEnv::with_pinned_key(public_key);
        let result = resolve_and_verify_endpoint_with_env(
            &json!({"discoveryFile": discovery_path.to_string_lossy().to_string()}),
            &env,
        )
        .unwrap();

        assert_eq!(result.status, VerificationStatus::EndpointMismatch);
    }

    #[test]
    fn expired_receipt_returns_expired_receipt() {
        let dir = temp_test_dir("expired-receipt");
        let discovery_path = dir.join("discovery.json");

        let signing_key = test_signing_key();
        let secret_bytes = signing_key.to_bytes();

        let (receipt, public_key) = test_signed_receipt(
            "http://127.0.0.1:7228",
            "http://127.0.0.1:7228/mcp",
            "lico-server-key-1",
            "2020-01-01T00:00:00Z",
            "2020-01-02T00:00:00Z",
            &secret_bytes,
        );

        let doc = json!({
            "url": "http://127.0.0.1:7228",
            "trustReceipt": receipt
        });
        fs::write(&discovery_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

        let env = VerifyEnv::with_pinned_key(public_key);
        let result = resolve_and_verify_endpoint_with_env(
            &json!({"discoveryFile": discovery_path.to_string_lossy().to_string()}),
            &env,
        )
        .unwrap();

        assert_eq!(result.status, VerificationStatus::ExpiredReceipt);
    }

    #[test]
    fn corrupted_signature_returns_invalid_receipt() {
        let dir = temp_test_dir("corrupt-sig");
        let discovery_path = dir.join("discovery.json");

        let signing_key = test_signing_key();
        let secret_bytes = signing_key.to_bytes();

        let (mut receipt, public_key) = test_signed_receipt(
            "http://127.0.0.1:7228",
            "http://127.0.0.1:7228/mcp",
            "lico-server-key-1",
            "2026-06-09T00:00:00Z",
            "2099-01-01T00:00:00Z",
            &secret_bytes,
        );

        receipt["signature"] = json!("AAAA");

        let doc = json!({
            "url": "http://127.0.0.1:7228",
            "trustReceipt": receipt
        });
        fs::write(&discovery_path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

        let env = VerifyEnv::with_pinned_key(public_key);
        let result = resolve_and_verify_endpoint_with_env(
            &json!({"discoveryFile": discovery_path.to_string_lossy().to_string()}),
            &env,
        )
        .unwrap();

        assert_eq!(result.status, VerificationStatus::InvalidReceipt);
    }

    #[test]
    fn dev_override_returns_unverified_but_never_verified() {
        let env = VerifyEnv {
            dev_allow_unverified_mcp: Some("1".to_string()),
            pinned_public_key: None,
        };
        let result = verify_endpoint_trust_with_env("http://127.0.0.1:7228", &json!({}), &env);
        assert_eq!(result, VerificationStatus::Unverified);
    }
}
