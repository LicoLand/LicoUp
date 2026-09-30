//! Peer trust read from this endpoint's persisted device-trust authority.
//!
//! The authority lives in the endpoint configuration document the composition
//! above this crate owns: `mobileRelayE2ee.peerTrustAuthority` holds the
//! verified peer records, keyed by the stable directory label the Key
//! Transparency scope derives. The reader takes that document as an argument
//! and performs no IO of its own, so nothing here reaches upward for it.

use anyhow::{Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use serde_json::Value;
use time::OffsetDateTime;

use crate::core::secure_mesh_transparency::stable_directory_label;

use super::identity::DeviceTrustPublicIdentity;
use super::model::DeviceTrustState;
use super::record::verify_device_trust_record_json;

/// The schema of the persisted peer trust authority.
const SECURE_MESH_PEER_TRUST_AUTHORITY_SCHEMA: &str = "licomesh.secure-mesh.peer-trust-authority.v1";
/// Bound on the persisted authority's entry count.
const MAX_SECURE_MESH_PEER_TRUST_ENTRIES: usize = 256;
const KEY_BYTES: usize = 32;

/// Resolves the caller-supplied peer's trust from the persisted authority.
///
/// The caller supplies an identity to bind the protocol message, but cannot
/// supply or promote its trust state: only a peer whose locally signed,
/// persisted record verifies against the same directory scope is eligible.
pub fn persisted_peer_trust_state(
    config: &Value,
    local_identity: &DeviceTrustPublicIdentity,
    peer_identity: &DeviceTrustPublicIdentity,
) -> Result<DeviceTrustState> {
    crate::core::secure_mesh_transparency::ensure_secure_mesh_protected_operation_allowed()?;
    ensure!(
        local_public_device_identity(config)? == *local_identity,
        "secure mesh MLS persisted local trust identity differs"
    );
    let scope = configured_directory_scope_commitment(config)?;
    let stable_label = stable_directory_label(scope, &peer_identity.endpoint_id);
    let authority = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("peerTrustAuthority"))
        .filter(|value| value.is_object())
        .ok_or_else(|| anyhow!("secure mesh MLS persisted trust authority is unavailable"))?;
    ensure!(
        authority.get("schemaVersion").and_then(Value::as_str)
            == Some(SECURE_MESH_PEER_TRUST_AUTHORITY_SCHEMA),
        "secure mesh MLS persisted trust authority schema is invalid"
    );
    let entries = authority
        .get("entries")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("secure mesh MLS persisted trust authority entries are missing"))?;
    ensure!(
        entries.len() <= MAX_SECURE_MESH_PEER_TRUST_ENTRIES,
        "secure mesh MLS persisted trust authority exceeds its bound"
    );
    let entry = entries
        .get(&stable_label)
        .filter(|value| value.is_object())
        .ok_or_else(|| {
            anyhow!("secure mesh MLS peer is absent from the persisted trust authority")
        })?;
    ensure!(
        entry.get("stableLabel").and_then(Value::as_str) == Some(stable_label.as_str()),
        "secure mesh MLS persisted peer trust label binding is invalid"
    );
    let identity_value = entry
        .get("identity")
        .filter(|value| value.is_object())
        .ok_or_else(|| anyhow!("secure mesh MLS persisted peer identity is missing"))?;
    let persisted_identity = DeviceTrustPublicIdentity::new(
        descriptor_text(identity_value, "endpointId")?,
        decode_key_32(
            &descriptor_text(identity_value, "identityPublicKeyBase64url")?,
            "secure mesh persisted peer identity public key",
        )?,
        decode_key_32(
            &descriptor_text(identity_value, "signingPublicKeyBase64url")?,
            "secure mesh persisted peer signing public key",
        )?,
        identity_value
            .get("rotationEpoch")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("secure mesh persisted peer rotation epoch is missing"))?,
    )?;
    ensure!(
        persisted_identity == *peer_identity,
        "secure mesh MLS persisted peer identity binding differs"
    );
    let record = entry
        .get("trustRecord")
        .ok_or_else(|| anyhow!("secure mesh MLS persisted peer trust record is missing"))?;
    let trust_state = verify_device_trust_record_json(
        local_identity,
        peer_identity,
        record,
        trust_record_now_epoch()?,
    )?;
    ensure!(
        trust_state == DeviceTrustState::Verified,
        "secure mesh MLS persisted peer trust is not verified"
    );
    Ok(trust_state)
}

/// The persisted public identity of the endpoint this configuration describes.
fn local_public_device_identity(config: &Value) -> Result<DeviceTrustPublicIdentity> {
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    DeviceTrustPublicIdentity::new(
        descriptor_text(state, "endpointId")?,
        decode_key_32(
            &descriptor_text(state, "publicKeyBase64url")?,
            "mobile relay identity public key",
        )?,
        decode_key_32(
            &descriptor_text(state, "signingPublicKeyBase64url")?,
            "mobile relay signing public key",
        )?,
        state
            .get("rotationEpoch")
            .and_then(Value::as_u64)
            .unwrap_or(1),
    )
}

/// The opaque directory scope commitment every stable label is derived under.
fn configured_directory_scope_commitment(config: &Value) -> Result<&str> {
    let scope = config
        .get("secureMeshDirectoryScopeCommitment")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            anyhow!("secure mesh opaque directory scope commitment is not configured")
        })?;
    ensure!(
        scope.len() == 64
            && scope
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "secure mesh opaque directory scope commitment is not canonical lowercase SHA-256 hex"
    );
    Ok(scope)
}

fn trust_record_now_epoch() -> Result<u64> {
    u64::try_from(OffsetDateTime::now_utc().unix_timestamp())
        .map_err(|_| anyhow!("secure mesh trust record clock is before unix epoch"))
}

fn descriptor_text(value: &Value, key: &str) -> Result<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("secure mesh descriptor missing {key}"))
}

fn decode_key_32(value: &str, label: &str) -> Result<[u8; KEY_BYTES]> {
    let bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| anyhow!("{label} is not base64url"))?;
    ensure!(
        general_purpose::URL_SAFE_NO_PAD.encode(&bytes) == value,
        "{label} must use canonical unpadded base64url"
    );
    bytes
        .try_into()
        .map_err(|_| anyhow!("{label} must be {KEY_BYTES} bytes"))
}
