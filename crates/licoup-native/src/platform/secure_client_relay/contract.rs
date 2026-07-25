use anyhow::{Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use serde::Serialize;
use serde_json::Value;

pub const SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST: &str =
    "sha256:b8f03b866a4af4d59fca43ddb86621f3ac6dbc6d2acc5c76177d6eeef83c0439";
pub const SECURE_CLIENT_RELAY_CORE_CONFORMANCE_DIGEST: &str =
    "sha256:34b6b92259190829348f0719e4bd60c031b43d1480bcd0b49e6c37eb25abcef0";
pub const SECURE_CLIENT_RELAY_PROTOCOL_VERSION: &str = "licomesh.secure-mesh.v1";
pub const SECURE_CLIENT_RELAY_CORE_CONTRACT: &str =
    include_str!("../../../resources/secure-client-relay-core-contract.json");
pub const SECURE_CLIENT_RELAY_CORE_CONFORMANCE: &str =
    include_str!("../../../resources/secure-client-relay-core-conformance.json");

pub(super) const STORE_SCHEMA_VERSION: &str = "licomesh.secure-mesh.store-schema.v2";
pub(super) const DEVICE_TRUST_PROTOCOL_VERSION: &str = "licomesh.secure-mesh.device-trust.v2";
pub(super) const DELIVERY_PROTOCOL_VERSION: &str = "licomesh.secure-mesh.delivery.v1";
pub(super) const SESSION_COOKIE_NAME: &str = "lico_console_session";
pub(super) const MAX_AUTH_VALUE_BYTES: usize = 4 * 1024;
pub(super) const MAX_IDENTIFIER_BYTES: usize = 255;
pub(super) const MAX_OPAQUE_SEQUENCE_LABEL_BYTES: usize = 255;
pub(super) const MAX_HTTP_RESPONSE_BYTES: usize = 24 * 1024 * 1024;
pub(super) const MAX_HTTP_ERROR_RESPONSE_BYTES: usize = 16 * 1024;
pub(super) const MAX_ERROR_BYTES: usize = 4 * 1024;
pub(super) const MAX_CHALLENGE_BYTES: usize = 2 * 1024;
pub(super) const MAX_RETRY_AFTER_SECONDS: u64 = 24 * 60 * 60;
pub(super) const JSON_SAFE_INTEGER_MAX: u64 = 9_007_199_254_740_991;
pub(super) const SYNC_LIMIT_MIN: u64 = 1;
pub(super) const SYNC_LIMIT_MAX: u64 = 100;
pub(super) const LEASE_MS_MIN: u64 = 5_000;
pub(super) const LEASE_MS_MAX: u64 = 600_000;
pub(super) const HTTP_TIMEOUT_SECONDS: u64 = 30;
pub(super) const ENDPOINT_KINDS: [&str; 7] = [
    "desktop_gui",
    "desktop_sidecar",
    "mobile",
    "cli",
    "client_local_runtime",
    "agent_host",
    "web_limited",
];
pub(super) const TRANSPORT_KINDS: [&str; 5] = [
    "cloud_relay",
    "mobile_relay",
    "lan_direct",
    "webrtc_data_channel",
    "loopback_local",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureClientRelayHttpError {
    pub operation: &'static str,
    pub status: u16,
    pub code: String,
    pub retryable: bool,
    pub retry_strategy: String,
    pub retry_after_seconds: Option<u64>,
}

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
            Self::EndpointRegister => &[
                "ok",
                "schemaVersion",
                "protocolVersion",
                "endpoint",
                "registrationReceipt",
            ],
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

    pub(super) fn session_token(&self) -> &str {
        &self.session_token
    }

    pub(super) fn csrf_token(&self) -> &str {
        &self.csrf_token
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

#[derive(Debug)]
pub(super) struct SecureClientRelayRequest {
    pub operation: SecureClientRelayOperation,
    pub body: Value,
}

#[derive(Debug)]
pub(super) struct SecureClientRelayResponseHead {
    pub content_type: Option<String>,
    pub retry_after_seconds: Option<u64>,
}

pub(super) fn validate_identifier(label: &str, value: &str) -> Result<()> {
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

pub(super) fn validate_canonical_base64url(
    label: &str,
    value: &str,
    encoded_len: usize,
) -> Result<()> {
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
