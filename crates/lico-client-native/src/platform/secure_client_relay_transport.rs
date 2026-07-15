//! Canonical HTTP adapter for the five server-visible Secure Client Relay operations.
//!
//! The adapter owns every relay path, request header, and outer request shape. Callers cannot
//! provide an arbitrary path or append server-visible fields to an opaque envelope request.

use std::sync::OnceLock;
use std::time::Duration;

use anyhow::{Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use serde::Serialize;
use serde_json::{Map, Value, json};

use super::secure_client_relay_response::{
    read_error_response, read_success_response, validate_ack_response_binding,
    validate_challenge_response_binding, validate_registration_response_binding,
    validate_send_response_binding, validate_sync_response_binding,
};
use crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope;

pub const SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST: &str =
    "sha256:133d084f0cfeb464a03f217ae2d24ff23758a7c10537027c80932bd930d2dab3";
pub const SECURE_CLIENT_RELAY_CORE_CONFORMANCE_DIGEST: &str =
    "sha256:d942d81fc07023c9c83903efed9d82f2f5b21fad9ad17f31b90fd77896019764";
pub const SECURE_CLIENT_RELAY_PROTOCOL_VERSION: &str = "licolite.secure-mesh.v1";
pub const SECURE_CLIENT_RELAY_CORE_CONTRACT: &str =
    include_str!("../../resources/secure-client-relay-core-contract.json");
pub const SECURE_CLIENT_RELAY_CORE_CONFORMANCE: &str =
    include_str!("../../resources/secure-client-relay-core-conformance.json");

const SESSION_COOKIE_NAME: &str = "lico_console_session";
const MAX_AUTH_VALUE_BYTES: usize = 4 * 1024;
const MAX_IDENTIFIER_BYTES: usize = 255;
const MAX_OPAQUE_SEQUENCE_LABEL_BYTES: usize = 255;
const JSON_SAFE_INTEGER_MAX: u64 = 9_007_199_254_740_991;
const SYNC_LIMIT_MIN: u64 = 1;
const SYNC_LIMIT_MAX: u64 = 100;
const LEASE_MS_MIN: u64 = 5_000;
const LEASE_MS_MAX: u64 = 600_000;

static CORE_CONTRACT_VALUE: OnceLock<Value> = OnceLock::new();

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureClientRelayHttpError {
    pub operation: &'static str,
    pub status: u16,
    pub code: String,
    pub retryable: bool,
    pub retry_strategy: String,
    pub retry_after_seconds: Option<u64>,
}

impl std::fmt::Display for SecureClientRelayHttpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "secure client relay {} failed with status {} and code {}",
            self.operation, self.status, self.code
        )
    }
}

impl std::error::Error for SecureClientRelayHttpError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SecureClientRelayOperation {
    EndpointChallenge,
    EndpointRegister,
    EnvelopeSend,
    EnvelopeSync,
    EnvelopeAck,
}

impl SecureClientRelayOperation {
    pub const ALL: [Self; 5] = [
        Self::EndpointChallenge,
        Self::EndpointRegister,
        Self::EnvelopeSend,
        Self::EnvelopeSync,
        Self::EnvelopeAck,
    ];

    pub const fn key(self) -> &'static str {
        match self {
            Self::EndpointChallenge => "endpointChallenge",
            Self::EndpointRegister => "endpointRegister",
            Self::EnvelopeSend => "envelopeSend",
            Self::EnvelopeSync => "envelopeSync",
            Self::EnvelopeAck => "envelopeAck",
        }
    }

    pub const fn path(self) -> &'static str {
        match self {
            Self::EndpointChallenge => "/api/secure-mesh/v1/endpoints/challenge",
            Self::EndpointRegister => "/api/secure-mesh/v1/endpoints/register",
            Self::EnvelopeSend => "/api/secure-mesh/v1/envelopes/send",
            Self::EnvelopeSync => "/api/secure-mesh/v1/envelopes/sync",
            Self::EnvelopeAck => "/api/secure-mesh/v1/envelopes/ack",
        }
    }

    pub(super) const fn success_fields(self) -> &'static [&'static str] {
        match self {
            Self::EndpointChallenge => &[
                "ok",
                "schemaVersion",
                "protocolVersion",
                "challengeId",
                "challenge",
                "challengeEncoding",
                "signatureAlgorithm",
                "expiresAt",
            ],
            Self::EndpointRegister => &["ok", "schemaVersion", "protocolVersion", "endpoint"],
            Self::EnvelopeSend => &[
                "ok",
                "schemaVersion",
                "protocolVersion",
                "queued",
                "persisted",
                "queueMode",
            ],
            Self::EnvelopeSync => &[
                "ok",
                "schemaVersion",
                "protocolVersion",
                "queueMode",
                "mailbox",
                "cursor",
                "gapRanges",
                "envelopes",
            ],
            Self::EnvelopeAck => &[
                "ok",
                "schemaVersion",
                "protocolVersion",
                "ack",
                "receipt",
                "mailbox",
            ],
        }
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct SecureClientRelayAuth {
    session_token: String,
    csrf_token: String,
}

impl SecureClientRelayAuth {
    pub fn new(session_token: impl Into<String>, csrf_token: impl Into<String>) -> Result<Self> {
        let session_token = session_token.into();
        let csrf_token = csrf_token.into();
        validate_header_value("relay session token", &session_token, false)?;
        validate_header_value("relay CSRF token", &csrf_token, true)?;
        Ok(Self {
            session_token,
            csrf_token,
        })
    }
}

impl std::fmt::Display for SecureClientRelayAuth {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SecureClientRelayAuth([redacted])")
    }
}

impl std::fmt::Debug for SecureClientRelayAuth {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SecureClientRelayAuth([redacted])")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureClientRelayScope {
    pub tenant_id: String,
    pub account_id: String,
    pub workspace_id: Option<String>,
}

impl SecureClientRelayScope {
    pub fn new(
        tenant_id: impl Into<String>,
        account_id: impl Into<String>,
        workspace_id: Option<String>,
    ) -> Result<Self> {
        let scope = Self {
            tenant_id: tenant_id.into(),
            account_id: account_id.into(),
            workspace_id,
        };
        validate_identifier("tenant id", &scope.tenant_id)?;
        validate_identifier("account id", &scope.account_id)?;
        if let Some(workspace_id) = &scope.workspace_id {
            validate_identifier("workspace id", workspace_id)?;
        }
        Ok(scope)
    }

    fn insert_into(&self, body: &mut Map<String, Value>) {
        body.insert("tenantId".to_string(), json!(self.tenant_id));
        body.insert("accountId".to_string(), json!(self.account_id));
        if let Some(workspace_id) = &self.workspace_id {
            body.insert("workspaceId".to_string(), json!(workspace_id));
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SecureClientRelayPublicJwk {
    pub kty: &'static str,
    pub crv: &'static str,
    pub x: String,
}

impl SecureClientRelayPublicJwk {
    pub fn x25519(x: impl Into<String>) -> Result<Self> {
        Self::new("X25519", x.into())
    }

    pub fn ed25519(x: impl Into<String>) -> Result<Self> {
        Self::new("Ed25519", x.into())
    }

    fn new(crv: &'static str, x: String) -> Result<Self> {
        validate_canonical_base64url("relay public JWK x", &x, 43)?;
        Ok(Self { kty: "OKP", crv, x })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureClientRelayEndpointRegistration {
    pub endpoint_id: String,
    pub endpoint_kind: String,
    pub identity_public_key: SecureClientRelayPublicJwk,
    pub signing_public_key: SecureClientRelayPublicJwk,
    pub mailbox_token: String,
    pub rotation_epoch: Option<u64>,
    pub challenge_id: String,
    pub challenge_signature: String,
}

impl SecureClientRelayEndpointRegistration {
    fn validate(&self) -> Result<()> {
        validate_identifier("endpoint id", &self.endpoint_id)?;
        ensure!(
            matches!(
                self.endpoint_kind.as_str(),
                "desktop_gui"
                    | "desktop_sidecar"
                    | "mobile"
                    | "cli"
                    | "client_local_runtime"
                    | "agent_host"
                    | "web_limited"
            ),
            "secure client relay endpoint kind is unsupported"
        );
        ensure!(
            self.identity_public_key.crv == "X25519" && self.signing_public_key.crv == "Ed25519",
            "secure client relay endpoint key profile is invalid"
        );
        validate_canonical_base64url("mailbox token", &self.mailbox_token, 43)?;
        validate_identifier("challenge id", &self.challenge_id)?;
        validate_canonical_base64url("challenge signature", &self.challenge_signature, 86)?;
        if let Some(rotation_epoch) = self.rotation_epoch {
            ensure!(
                rotation_epoch <= JSON_SAFE_INTEGER_MAX,
                "secure client relay rotation epoch is outside the supported range"
            );
        }
        Ok(())
    }
}

pub struct SecureClientRelayTransport {
    base_url: String,
    auth: SecureClientRelayAuth,
}

impl SecureClientRelayTransport {
    pub fn new(base_url: impl Into<String>, auth: SecureClientRelayAuth) -> Result<Self> {
        let base_url = base_url.into();
        ensure!(
            !base_url.trim().is_empty() && !base_url.ends_with('/'),
            "secure client relay base URL is invalid"
        );
        Ok(Self { base_url, auth })
    }

    pub fn endpoint_challenge(
        &self,
        scope: &SecureClientRelayScope,
        endpoint_id: &str,
        signing_public_key: &SecureClientRelayPublicJwk,
    ) -> Result<Value> {
        validate_identifier("endpoint id", endpoint_id)?;
        ensure!(
            signing_public_key.crv == "Ed25519",
            "secure client relay challenge signing key profile is invalid"
        );
        let mut body = Map::new();
        scope.insert_into(&mut body);
        body.insert("endpointId".to_string(), json!(endpoint_id));
        body.insert(
            "signingPublicKey".to_string(),
            serde_json::to_value(signing_public_key)?,
        );
        let response = self.post(
            SecureClientRelayOperation::EndpointChallenge,
            Value::Object(body),
        )?;
        validate_challenge_response_binding(&response, scope, endpoint_id)?;
        Ok(response)
    }

    pub fn endpoint_register(
        &self,
        scope: &SecureClientRelayScope,
        registration: &SecureClientRelayEndpointRegistration,
    ) -> Result<Value> {
        registration.validate()?;
        let mut body = Map::new();
        scope.insert_into(&mut body);
        body.insert("endpointId".to_string(), json!(registration.endpoint_id));
        body.insert(
            "endpointKind".to_string(),
            json!(registration.endpoint_kind),
        );
        body.insert(
            "identityPublicKey".to_string(),
            serde_json::to_value(&registration.identity_public_key)?,
        );
        body.insert(
            "signingPublicKey".to_string(),
            serde_json::to_value(&registration.signing_public_key)?,
        );
        body.insert(
            "mailboxToken".to_string(),
            json!(registration.mailbox_token),
        );
        body.insert(
            "proof".to_string(),
            json!({
                "challengeId": registration.challenge_id,
                "signature": registration.challenge_signature,
            }),
        );
        if let Some(rotation_epoch) = registration.rotation_epoch {
            body.insert("rotationEpoch".to_string(), json!(rotation_epoch));
        }
        let response = self.post(
            SecureClientRelayOperation::EndpointRegister,
            Value::Object(body),
        )?;
        validate_registration_response_binding(&response, scope, registration)?;
        Ok(response)
    }

    pub fn envelope_send(
        &self,
        scope: &SecureClientRelayScope,
        envelope: &SecureMeshRelayEnvelope,
        transport: Option<&str>,
        opaque_sequence_label: Option<&str>,
    ) -> Result<Value> {
        envelope.validate()?;
        if let Some(transport) = transport {
            ensure!(
                matches!(
                    transport,
                    "cloud_relay"
                        | "mobile_relay"
                        | "lan_direct"
                        | "webrtc_data_channel"
                        | "loopback_local"
                ),
                "secure client relay transport is unsupported"
            );
        }
        if let Some(label) = opaque_sequence_label {
            ensure!(
                label.len() <= MAX_OPAQUE_SEQUENCE_LABEL_BYTES,
                "secure client relay opaque sequence label is too large"
            );
        }
        let mut body = Map::new();
        scope.insert_into(&mut body);
        body.insert(
            "envelope".to_string(),
            serde_json::from_str(&envelope.to_json()?)?,
        );
        if let Some(transport) = transport {
            body.insert("transport".to_string(), json!(transport));
        }
        if let Some(label) = opaque_sequence_label {
            body.insert("opaqueSequenceLabel".to_string(), json!(label));
        }
        let response = self.post(
            SecureClientRelayOperation::EnvelopeSend,
            Value::Object(body),
        )?;
        validate_send_response_binding(
            &response,
            scope,
            envelope,
            transport,
            opaque_sequence_label,
        )?;
        Ok(response)
    }

    pub fn envelope_sync(
        &self,
        scope: &SecureClientRelayScope,
        mailbox_token: &str,
        after_delivery_sequence: Option<u64>,
        limit: Option<u64>,
        lease_ms: Option<u64>,
    ) -> Result<Value> {
        validate_canonical_base64url("mailbox token", mailbox_token, 43)?;
        if let Some(sequence) = after_delivery_sequence {
            ensure!(
                sequence <= JSON_SAFE_INTEGER_MAX,
                "secure client relay sync cursor is outside the supported range"
            );
        }
        if let Some(limit) = limit {
            ensure!(
                (SYNC_LIMIT_MIN..=SYNC_LIMIT_MAX).contains(&limit),
                "secure client relay sync limit is outside the supported range"
            );
        }
        if let Some(lease_ms) = lease_ms {
            ensure!(
                (LEASE_MS_MIN..=LEASE_MS_MAX).contains(&lease_ms),
                "secure client relay lease duration is outside the supported range"
            );
        }
        let mut body = Map::new();
        scope.insert_into(&mut body);
        body.insert("mailboxToken".to_string(), json!(mailbox_token));
        if let Some(sequence) = after_delivery_sequence {
            body.insert("afterDeliverySequence".to_string(), json!(sequence));
        }
        if let Some(limit) = limit {
            body.insert("limit".to_string(), json!(limit));
        }
        if let Some(lease_ms) = lease_ms {
            body.insert("leaseMs".to_string(), json!(lease_ms));
        }
        let response = self.post(
            SecureClientRelayOperation::EnvelopeSync,
            Value::Object(body),
        )?;
        validate_sync_response_binding(&response, scope, mailbox_token, after_delivery_sequence)?;
        Ok(response)
    }

    pub fn envelope_ack(
        &self,
        scope: &SecureClientRelayScope,
        mailbox_token: &str,
        delivery_id: &str,
        lease_id: &str,
        lease_generation: u64,
    ) -> Result<Value> {
        validate_canonical_base64url("mailbox token", mailbox_token, 43)?;
        validate_canonical_base64url("delivery id", delivery_id, 32)?;
        validate_identifier("lease id", lease_id)?;
        ensure!(
            (1..=JSON_SAFE_INTEGER_MAX).contains(&lease_generation),
            "secure client relay lease generation is outside the supported range"
        );
        let mut body = Map::new();
        scope.insert_into(&mut body);
        body.insert("mailboxToken".to_string(), json!(mailbox_token));
        body.insert("deliveryId".to_string(), json!(delivery_id));
        body.insert("leaseId".to_string(), json!(lease_id));
        body.insert("leaseGeneration".to_string(), json!(lease_generation));
        let response = self.post(SecureClientRelayOperation::EnvelopeAck, Value::Object(body))?;
        validate_ack_response_binding(&response, scope, mailbox_token, delivery_id)?;
        Ok(response)
    }

    fn post(&self, operation: SecureClientRelayOperation, body: Value) -> Result<Value> {
        let url = format!("{}{}", self.base_url, operation.path());
        let cookie = format!("{SESSION_COOKIE_NAME}={}", self.auth.session_token);
        let request = ureq::post(&url)
            .timeout(Duration::from_secs(30))
            .set("accept", "application/json")
            .set("content-type", "application/json")
            .set("cookie", &cookie)
            .set("x-lico-csrf", &self.auth.csrf_token)
            .set("x-lico-safety-confirm", "true");
        match request.send_json(body) {
            Ok(response) => read_success_response(operation, response),
            Err(ureq::Error::Status(status, response)) => {
                let retry_after_seconds = response
                    .header("retry-after")
                    .and_then(|value| value.parse::<u64>().ok());
                let error = read_error_response(response).ok();
                let code = error
                    .as_ref()
                    .and_then(|value| value.get("code"))
                    .and_then(Value::as_str)
                    .unwrap_or("secure_client_relay_http_error");
                let (retryable, retry_strategy) =
                    core_error_policy(operation, code, status, retry_after_seconds.is_some());
                Err(anyhow::Error::new(SecureClientRelayHttpError {
                    operation: operation.key(),
                    status,
                    code: code.to_string(),
                    retryable,
                    retry_strategy,
                    retry_after_seconds,
                }))
            }
            Err(ureq::Error::Transport(_)) => Err(anyhow!(
                "secure client relay {} transport failed",
                operation.key()
            )),
        }
    }
}

fn core_error_policy(
    operation: SecureClientRelayOperation,
    code: &str,
    status: u16,
    has_retry_after: bool,
) -> (bool, String) {
    let contract = CORE_CONTRACT_VALUE.get_or_init(|| {
        serde_json::from_str(SECURE_CLIENT_RELAY_CORE_CONTRACT)
            .expect("embedded Secure Client Relay core contract must be valid JSON")
    });
    let policy =
        contract["contract"]["coreOperations"][operation.key()]["errors"][code].as_object();
    if let Some(policy) = policy {
        if policy["status"].as_u64() == Some(u64::from(status)) {
            let retry = &policy["retry"];
            return (
                retry["retryable"].as_bool().unwrap_or(false),
                retry["strategy"]
                    .as_str()
                    .unwrap_or("do_not_retry")
                    .to_string(),
            );
        }
    }
    if status == 429 && has_retry_after {
        return (true, "retry_after_header".to_string());
    }
    (false, "do_not_retry".to_string())
}

fn validate_identifier(label: &str, value: &str) -> Result<()> {
    ensure!(
        !value.trim().is_empty() && value.len() <= MAX_IDENTIFIER_BYTES,
        "secure client relay {label} is invalid"
    );
    ensure!(
        !value.chars().any(char::is_control),
        "secure client relay {label} contains control characters"
    );
    Ok(())
}

fn validate_header_value(label: &str, value: &str, allow_semicolon: bool) -> Result<()> {
    ensure!(
        !value.trim().is_empty() && value.len() <= MAX_AUTH_VALUE_BYTES,
        "secure client relay {label} is invalid"
    );
    ensure!(
        !value.chars().any(char::is_control) && (allow_semicolon || !value.contains(';')),
        "secure client relay {label} contains invalid header characters"
    );
    Ok(())
}

fn validate_canonical_base64url(label: &str, value: &str, encoded_len: usize) -> Result<()> {
    ensure!(
        value.len() == encoded_len
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'),
        "secure client relay {label} is not canonical base64url"
    );
    let decoded = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| anyhow!("secure client relay {label} is not canonical base64url"))?;
    ensure!(
        general_purpose::URL_SAFE_NO_PAD.encode(decoded) == value,
        "secure client relay {label} is not canonical base64url"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::{Arc, Mutex};
    use std::thread;

    use crate::core::secure_mesh_relay_envelope::SecureMeshMailboxToken;

    #[derive(Clone, Debug)]
    struct CapturedRequest {
        path: String,
        headers: Map<String, Value>,
        body: Value,
    }

    #[test]
    fn operation_registry_is_exact_and_has_no_arbitrary_path_surface() {
        let artifact: Value = serde_json::from_str(SECURE_CLIENT_RELAY_CORE_CONTRACT).unwrap();
        let contract = artifact["contract"].as_object().unwrap();
        let operations = contract["coreOperations"].as_object().unwrap();
        assert_eq!(operations.len(), SecureClientRelayOperation::ALL.len());
        for operation in SecureClientRelayOperation::ALL {
            let pinned = &operations[operation.key()];
            assert_eq!(pinned["method"], "POST");
            assert_eq!(pinned["path"], operation.path());
            let required = pinned["success"]["responseSchema"]["required"]
                .as_array()
                .unwrap()
                .iter()
                .map(|field| field.as_str().unwrap())
                .collect::<BTreeSet<_>>();
            assert_eq!(
                required,
                operation
                    .success_fields()
                    .iter()
                    .copied()
                    .collect::<BTreeSet<_>>()
            );
        }
        assert_eq!(contract["limits"]["syncPage"]["minimum"], SYNC_LIMIT_MIN);
        assert_eq!(contract["limits"]["syncPage"]["maximum"], SYNC_LIMIT_MAX);
        assert_eq!(contract["limits"]["leaseMs"]["minimum"], LEASE_MS_MIN);
        assert_eq!(contract["limits"]["leaseMs"]["maximum"], LEASE_MS_MAX);
        assert_eq!(
            contract["envelope"]["fields"],
            serde_json::to_value(
                crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_OUTER_FIELDS
            )
            .unwrap()
        );
    }

    #[test]
    fn vendored_core_conformance_is_digest_bound_to_the_core_contract() {
        let contract: Value = serde_json::from_str(SECURE_CLIENT_RELAY_CORE_CONTRACT).unwrap();
        let conformance: Value =
            serde_json::from_str(SECURE_CLIENT_RELAY_CORE_CONFORMANCE).unwrap();
        assert_eq!(
            contract["canonicalDigest"],
            Value::String(SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST.to_string())
        );
        assert_eq!(
            conformance["canonicalDigest"],
            Value::String(SECURE_CLIENT_RELAY_CORE_CONFORMANCE_DIGEST.to_string())
        );
        assert_eq!(
            conformance["contractDigest"],
            Value::String(SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST.to_string())
        );
        assert_eq!(
            conformance["protocolVersion"],
            Value::String(SECURE_CLIENT_RELAY_PROTOCOL_VERSION.to_string())
        );
    }

    #[test]
    fn auth_rejects_header_injection_and_debug_output_is_redacted() {
        assert!(SecureClientRelayAuth::new("session\r\nforged", "csrf").is_err());
        assert!(SecureClientRelayAuth::new("session;forged=1", "csrf").is_err());
        let auth = SecureClientRelayAuth::new("session", "csrf").unwrap();
        assert_eq!(auth.to_string(), "SecureClientRelayAuth([redacted])");
        assert!(!format!("{auth:?}").contains("session"));
    }

    #[test]
    fn application_error_preserves_core_retry_policy_without_server_detail() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _request = read_request(&mut stream);
            let body = serde_json::to_vec(&json!({
                "ok": false,
                "schemaVersion": "licolite.secure-mesh.store-schema.v2",
                "protocolVersion": SECURE_CLIENT_RELAY_PROTOCOL_VERSION,
                "code": "secure_mesh_mailbox_backpressure",
                "error": "server detail must not cross the adapter"
            }))
            .unwrap();
            write!(
                stream,
                "HTTP/1.1 429 Too Many Requests\r\ncontent-type: application/json\r\nretry-after: 3\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                body.len()
            )
            .unwrap();
            stream.write_all(&body).unwrap();
        });
        let transport = SecureClientRelayTransport::new(
            format!("http://{address}"),
            SecureClientRelayAuth::new("test-session", "test-csrf").unwrap(),
        )
        .unwrap();
        let scope = SecureClientRelayScope::new("tenant", "account", None).unwrap();
        let mailbox = SecureMeshMailboxToken::from_base64url(
            general_purpose::URL_SAFE_NO_PAD.encode([7u8; 32]),
        )
        .unwrap();
        let envelope = SecureMeshRelayEnvelope::new(&mailbox, &[0u8; 4096], &[0u8; 256]).unwrap();
        let error = transport
            .envelope_send(&scope, &envelope, None, None)
            .unwrap_err();
        server.join().unwrap();
        let relay_error = error.downcast_ref::<SecureClientRelayHttpError>().unwrap();
        assert_eq!(relay_error.operation, "envelopeSend");
        assert_eq!(relay_error.status, 429);
        assert_eq!(relay_error.code, "secure_mesh_mailbox_backpressure");
        assert!(relay_error.retryable);
        assert_eq!(
            relay_error.retry_strategy,
            "exponential_backoff_with_jitter"
        );
        assert_eq!(relay_error.retry_after_seconds, Some(3));
        assert!(!error.to_string().contains("server detail"));
    }

    #[test]
    fn adapter_emits_only_canonical_paths_headers_and_request_fields() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let captured = Arc::new(Mutex::new(Vec::<CapturedRequest>::new()));
        let thread_captured = Arc::clone(&captured);
        let server = thread::spawn(move || {
            for stream in listener.incoming().take(5) {
                let mut stream = stream.unwrap();
                let request = read_request(&mut stream);
                let response = success_fixture(&request);
                thread_captured.lock().unwrap().push(request);
                let bytes = serde_json::to_vec(&response).unwrap();
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    bytes.len()
                )
                .unwrap();
                stream.write_all(&bytes).unwrap();
            }
        });

        let transport = SecureClientRelayTransport::new(
            format!("http://{address}"),
            SecureClientRelayAuth::new("test-session", "test-csrf").unwrap(),
        )
        .unwrap();
        let scope = SecureClientRelayScope::new("tenant", "account", None).unwrap();
        let signing_key = general_purpose::URL_SAFE_NO_PAD.encode([1u8; 32]);
        let identity_key = general_purpose::URL_SAFE_NO_PAD.encode([2u8; 32]);
        let mailbox_token = general_purpose::URL_SAFE_NO_PAD.encode([3u8; 32]);
        let challenge_signature = general_purpose::URL_SAFE_NO_PAD.encode([4u8; 64]);
        let signing = SecureClientRelayPublicJwk::ed25519(signing_key).unwrap();
        transport
            .endpoint_challenge(&scope, "endpoint", &signing)
            .unwrap();
        transport
            .endpoint_register(
                &scope,
                &SecureClientRelayEndpointRegistration {
                    endpoint_id: "endpoint".to_string(),
                    endpoint_kind: "cli".to_string(),
                    identity_public_key: SecureClientRelayPublicJwk::x25519(identity_key).unwrap(),
                    signing_public_key: signing,
                    mailbox_token: mailbox_token.clone(),
                    rotation_epoch: Some(1),
                    challenge_id: "challenge".to_string(),
                    challenge_signature,
                },
            )
            .unwrap();
        let mailbox = SecureMeshMailboxToken::from_base64url(mailbox_token).unwrap();
        let envelope = SecureMeshRelayEnvelope::new(&mailbox, &[0u8; 4096], &[0u8; 256]).unwrap();
        transport
            .envelope_send(&scope, &envelope, Some("mobile_relay"), None)
            .unwrap();
        transport
            .envelope_sync(&scope, mailbox.as_str(), Some(0), Some(10), Some(30_000))
            .unwrap();
        transport
            .envelope_ack(&scope, mailbox.as_str(), envelope.delivery_id(), "lease", 1)
            .unwrap();
        server.join().unwrap();

        let captured = captured.lock().unwrap();
        assert_eq!(captured.len(), 5);
        assert_eq!(
            captured
                .iter()
                .map(|request| request.path.as_str())
                .collect::<Vec<_>>(),
            SecureClientRelayOperation::ALL
                .iter()
                .map(|operation| operation.path())
                .collect::<Vec<_>>()
        );
        for request in captured.iter() {
            assert_eq!(
                request.headers["cookie"],
                "lico_console_session=test-session"
            );
            assert_eq!(request.headers["x-lico-csrf"], "test-csrf");
            assert_eq!(request.headers["x-lico-safety-confirm"], "true");
            assert_eq!(request.headers["content-type"], "application/json");
            assert!(!request.body.to_string().contains("pairingId"));
            assert!(!request.body.to_string().contains("commandId"));
            assert!(!request.body.to_string().contains("plaintext"));
        }
        assert_eq!(
            object_keys(&captured[0].body),
            set(&["tenantId", "accountId", "endpointId", "signingPublicKey"])
        );
        assert_eq!(
            object_keys(&captured[1].body),
            set(&[
                "tenantId",
                "accountId",
                "endpointId",
                "endpointKind",
                "identityPublicKey",
                "signingPublicKey",
                "mailboxToken",
                "proof",
                "rotationEpoch",
            ])
        );
        assert_eq!(
            object_keys(&captured[2].body),
            set(&["tenantId", "accountId", "envelope", "transport"])
        );
        assert_eq!(
            object_keys(&captured[2].body["envelope"]),
            set(&[
                "schema",
                "deliveryId",
                "mailboxToken",
                "encryptedHeader",
                "ciphertextBucket",
                "ciphertext",
            ])
        );
        assert_eq!(
            object_keys(&captured[3].body),
            set(&[
                "tenantId",
                "accountId",
                "mailboxToken",
                "afterDeliverySequence",
                "limit",
                "leaseMs",
            ])
        );
        assert_eq!(
            object_keys(&captured[4].body),
            set(&[
                "tenantId",
                "accountId",
                "mailboxToken",
                "deliveryId",
                "leaseId",
                "leaseGeneration",
            ])
        );
    }

    fn read_request(stream: &mut TcpStream) -> CapturedRequest {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut request_line = String::new();
        reader.read_line(&mut request_line).unwrap();
        let path = request_line.split_whitespace().nth(1).unwrap().to_string();
        let mut headers = Map::new();
        let mut content_length = 0usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let line = line.trim_end_matches(['\r', '\n']);
            if line.is_empty() {
                break;
            }
            if let Some((name, value)) = line.split_once(':') {
                let name = name.trim().to_ascii_lowercase();
                let value = value.trim();
                if name == "content-length" {
                    content_length = value.parse().unwrap();
                }
                headers.insert(name, json!(value));
            }
        }
        let mut body = vec![0u8; content_length];
        reader.read_exact(&mut body).unwrap();
        CapturedRequest {
            path,
            headers,
            body: serde_json::from_slice(&body).unwrap(),
        }
    }

    fn success_fixture(request: &CapturedRequest) -> Value {
        match request.path.as_str() {
            "/api/secure-mesh/v1/endpoints/challenge" => json!({
                "ok": true,
                "schemaVersion": "licolite.secure-mesh.store-schema.v2",
                "protocolVersion": "licolite.secure-mesh.device-trust.v2",
                "challengeId": "challenge",
                "challenge": format!(
                    "licolite.secure-mesh.v1:challenge:{}:{}:{}:2026-01-01T00:00:00Z",
                    request.body["tenantId"].as_str().unwrap(),
                    request.body["accountId"].as_str().unwrap(),
                    request.body["endpointId"].as_str().unwrap(),
                ),
                "challengeEncoding": "utf-8",
                "signatureAlgorithm": "Ed25519",
                "expiresAt": "2026-01-01T00:00:00Z"
            }),
            "/api/secure-mesh/v1/endpoints/register" => json!({
                "ok": true,
                "schemaVersion": "licolite.secure-mesh.store-schema.v2",
                "protocolVersion": "licolite.secure-mesh.device-trust.v2",
                "endpoint": {
                    "tenantId": request.body["tenantId"],
                    "accountId": request.body["accountId"],
                    "workspaceId": request.body.get("workspaceId").cloned().unwrap_or(json!("")),
                    "endpointId": request.body["endpointId"],
                    "endpointKind": request.body["endpointKind"],
                    "mailboxToken": request.body["mailboxToken"],
                    "identityPublicKey": request.body["identityPublicKey"],
                    "signingPublicKey": request.body["signingPublicKey"],
                    "fingerprint": "a".repeat(64),
                    "rotationEpoch": request.body.get("rotationEpoch").cloned().unwrap_or(json!(0)),
                    "createdAt": "2026-01-01T00:00:00Z",
                    "updatedAt": "2026-01-01T00:00:00Z",
                    "revokedAt": ""
                }
            }),
            "/api/secure-mesh/v1/envelopes/send" => json!({
                "ok": true,
                "schemaVersion": "licolite.secure-mesh.store-schema.v2",
                "protocolVersion": "licolite.secure-mesh.delivery.v1",
                "queued": {
                    "deliverySequence": 1,
                    "queuedAt": "2026-01-01T00:00:00Z",
                    "transport": request.body.get("transport").cloned().unwrap_or(json!("cloud_relay")),
                    "envelope": {
                        "schema": request.body["envelope"]["schema"],
                        "deliveryId": request.body["envelope"]["deliveryId"],
                        "mailboxToken": request.body["envelope"]["mailboxToken"],
                        "ciphertextBucket": request.body["envelope"]["ciphertextBucket"]
                    },
                    "opaqueSequenceLabelHash": "",
                    "opaqueSequenceLabelPresent": request.body.get("opaqueSequenceLabel").is_some(),
                    "mailbox": mailbox_fixture(
                        &request.body,
                        request.body["envelope"]["mailboxToken"].as_str().unwrap(),
                    ),
                    "metadataOnly": true
                },
                "persisted": true,
                "queueMode": "offline_queue"
            }),
            "/api/secure-mesh/v1/envelopes/sync" => json!({
                "ok": true,
                "schemaVersion": "licolite.secure-mesh.store-schema.v2",
                "protocolVersion": "licolite.secure-mesh.delivery.v1",
                "queueMode": "offline_queue",
                "mailbox": mailbox_fixture(
                    &request.body,
                    request.body["mailboxToken"].as_str().unwrap(),
                ),
                "cursor": {
                    "afterDeliverySequence": request.body.get("afterDeliverySequence").cloned().unwrap_or(json!(0)),
                    "nextDeliverySequence": request.body.get("afterDeliverySequence").cloned().unwrap_or(json!(0)),
                    "highWatermark": request.body.get("afterDeliverySequence").cloned().unwrap_or(json!(0)),
                    "hasMore": false
                },
                "gapRanges": [],
                "envelopes": []
            }),
            "/api/secure-mesh/v1/envelopes/ack" => json!({
                "ok": true,
                "schemaVersion": "licolite.secure-mesh.store-schema.v2",
                "protocolVersion": "licolite.secure-mesh.delivery.v1",
                "ack": {
                    "deliveryId": request.body["deliveryId"],
                    "idempotent": false,
                    "ackedAt": "2026-01-01T00:00:00Z",
                    "purged": true
                },
                "receipt": {
                    "deliveryId": request.body["deliveryId"],
                    "deliverySequence": 1,
                    "receiptType": "ack",
                    "acknowledgedAt": "2026-01-01T00:00:00Z",
                    "purged": true
                },
                "mailbox": mailbox_fixture(
                    &request.body,
                    request.body["mailboxToken"].as_str().unwrap(),
                )
            }),
            _ => panic!("unexpected canonical operation path"),
        }
    }

    fn mailbox_fixture(scope: &Value, mailbox_token: &str) -> Value {
        json!({
            "tenantId": scope["tenantId"],
            "accountId": scope["accountId"],
            "workspaceId": scope.get("workspaceId").cloned().unwrap_or(json!("")),
            "endpointId": "endpoint",
            "mailboxToken": mailbox_token,
            "queueBytes": 0,
            "queuedCount": 0,
            "oldestQueuedAt": "",
            "deliverySequence": 1,
            "receiptCount": 0,
            "ackedCount": 0,
            "updatedAt": "2026-01-01T00:00:00Z"
        })
    }

    fn object_keys(value: &Value) -> BTreeSet<&str> {
        value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect()
    }

    fn set<'a>(values: &'a [&'a str]) -> BTreeSet<&'a str> {
        values.iter().copied().collect()
    }
}
