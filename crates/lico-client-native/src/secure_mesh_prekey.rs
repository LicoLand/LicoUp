use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

use crate::secure_mesh_mls::SECURE_MESH_MLS_CIPHER_SUITE;
use crate::secure_mesh_trust::{DeviceTrustPublicIdentity, DeviceTrustState};

pub const SECURE_MESH_PREKEY_PROTOCOL_VERSION: &str = "licolite.secure-mesh.pairwise.v1";
pub const SECURE_MESH_KEYPACKAGE_PROTOCOL_VERSION: &str = "v0.0.1:secure-mesh:group-mls-1";
pub const SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE: &str =
    "licolite.mls-rfc9420.v1.aes128gcmsha256ed25519x25519";
pub const SECURE_MESH_PREKEY_STATUS: &str = "signed_prekey_one_time_prekey_keypackage_validation_low_water_available_pairwise_runtime_available";

const PREKEY_MAGIC: &[u8] = b"LCOSM-PREKEY-v1";
const KEYPACKAGE_MAGIC: &[u8] = b"LCOSM-KEYPACKAGE-v1";
const MAX_PREKEY_ID_LEN: usize = 128;
const MAX_PUBLIC_KEY_BYTES: usize = 4096;
const MAX_SIGNATURE_B64_LEN: usize = 256;
const MAX_CREDENTIAL_LEN: usize = 2048;
const MAX_KEYPACKAGE_BYTES: usize = 128 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPreKeyRecord {
    pub prekey_id: String,
    pub public_key: Vec<u8>,
    pub signature: String,
    pub created_at: String,
    pub expires_at: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SecureMeshPreKeyKind {
    SignedPreKey,
    OneTimePreKey,
}

impl SecureMeshPreKeyKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::SignedPreKey => "signed_prekey",
            Self::OneTimePreKey => "one_time_prekey",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPairwisePreKeyBundle {
    pub endpoint_identity: DeviceTrustPublicIdentity,
    pub trust_state: DeviceTrustState,
    pub signed_prekey: SecureMeshPreKeyRecord,
    pub one_time_prekey: Option<SecureMeshPreKeyRecord>,
    pub transparency_tree_head: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPreKeyValidationPolicy {
    pub require_verified_device: bool,
    pub require_one_time_prekey: bool,
}

impl Default for SecureMeshPreKeyValidationPolicy {
    fn default() -> Self {
        Self {
            require_verified_device: true,
            require_one_time_prekey: true,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPreKeyBundleValidation {
    pub endpoint_id: String,
    pub signed_prekey_id: String,
    pub one_time_prekey_id: Option<String>,
    pub transparency_tree_head: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshKeyPackageRecord {
    pub key_package_id: String,
    pub cipher_suite: String,
    pub credential: String,
    pub public_key_package: Vec<u8>,
    pub signature: String,
    pub created_at: String,
    pub expires_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshInventoryStatus {
    pub signed_prekey_present: bool,
    pub available_one_time_prekeys: usize,
    pub available_key_packages: usize,
    pub one_time_prekey_low_watermark: usize,
    pub key_package_low_watermark: usize,
    pub should_upload_one_time_prekeys: bool,
    pub should_upload_key_packages: bool,
}

pub fn sign_prekey_record(
    signer_key: &SigningKey,
    endpoint_identity: &DeviceTrustPublicIdentity,
    kind: SecureMeshPreKeyKind,
    prekey_id: impl Into<String>,
    public_key: impl Into<Vec<u8>>,
    created_at: impl Into<String>,
    expires_at: impl Into<String>,
) -> Result<SecureMeshPreKeyRecord> {
    let mut record = SecureMeshPreKeyRecord {
        prekey_id: prekey_id.into(),
        public_key: public_key.into(),
        signature: String::new(),
        created_at: created_at.into(),
        expires_at: expires_at.into(),
    };
    validate_prekey_shape(&record, kind, false)?;
    let payload = prekey_signature_payload(endpoint_identity, kind, &record)?;
    let signature = signer_key.sign(&payload);
    record.signature = general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes());
    Ok(record)
}

pub fn verify_prekey_record(
    endpoint_identity: &DeviceTrustPublicIdentity,
    kind: SecureMeshPreKeyKind,
    record: &SecureMeshPreKeyRecord,
    now: OffsetDateTime,
) -> Result<()> {
    validate_prekey_shape(record, kind, true)?;
    ensure_not_expired(&record.created_at, &record.expires_at, now, "prekey")?;
    verify_signature(
        endpoint_identity,
        &prekey_signature_payload(endpoint_identity, kind, record)?,
        &record.signature,
        "prekey",
    )
}

pub fn validate_pairwise_prekey_bundle(
    bundle: &SecureMeshPairwisePreKeyBundle,
    policy: &SecureMeshPreKeyValidationPolicy,
    now: OffsetDateTime,
) -> Result<SecureMeshPreKeyBundleValidation> {
    ensure!(
        !bundle.transparency_tree_head.trim().is_empty(),
        "secure mesh prekey bundle transparency tree head is required"
    );
    ensure_active_trust_state(bundle.trust_state.clone(), policy.require_verified_device)?;
    verify_prekey_record(
        &bundle.endpoint_identity,
        SecureMeshPreKeyKind::SignedPreKey,
        &bundle.signed_prekey,
        now,
    )?;
    let one_time_prekey_id = match &bundle.one_time_prekey {
        Some(record) => {
            verify_prekey_record(
                &bundle.endpoint_identity,
                SecureMeshPreKeyKind::OneTimePreKey,
                record,
                now,
            )?;
            Some(record.prekey_id.clone())
        }
        None if policy.require_one_time_prekey => {
            bail_prekey("secure mesh one-time prekey is required for a new pairwise session")?
        }
        None => None,
    };
    Ok(SecureMeshPreKeyBundleValidation {
        endpoint_id: bundle.endpoint_identity.endpoint_id.clone(),
        signed_prekey_id: bundle.signed_prekey.prekey_id.clone(),
        one_time_prekey_id,
        transparency_tree_head: bundle.transparency_tree_head.clone(),
    })
}

pub fn sign_key_package_record(
    signer_key: &SigningKey,
    endpoint_identity: &DeviceTrustPublicIdentity,
    key_package_id: impl Into<String>,
    cipher_suite: impl Into<String>,
    credential: impl Into<String>,
    public_key_package: impl Into<Vec<u8>>,
    created_at: impl Into<String>,
    expires_at: impl Into<String>,
) -> Result<SecureMeshKeyPackageRecord> {
    let mut record = SecureMeshKeyPackageRecord {
        key_package_id: key_package_id.into(),
        cipher_suite: cipher_suite.into(),
        credential: credential.into(),
        public_key_package: public_key_package.into(),
        signature: String::new(),
        created_at: created_at.into(),
        expires_at: expires_at.into(),
    };
    validate_key_package_shape(&record, false)?;
    let payload = key_package_signature_payload(endpoint_identity, &record)?;
    let signature = signer_key.sign(&payload);
    record.signature = general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes());
    Ok(record)
}

pub fn verify_key_package_record(
    endpoint_identity: &DeviceTrustPublicIdentity,
    trust_state: DeviceTrustState,
    record: &SecureMeshKeyPackageRecord,
    require_verified_device: bool,
    now: OffsetDateTime,
) -> Result<()> {
    ensure_active_trust_state(trust_state, require_verified_device)?;
    validate_key_package_shape(record, true)?;
    ensure_not_expired(
        &record.created_at,
        &record.expires_at,
        now,
        "MLS KeyPackage",
    )?;
    verify_signature(
        endpoint_identity,
        &key_package_signature_payload(endpoint_identity, record)?,
        &record.signature,
        "MLS KeyPackage",
    )
}

pub fn evaluate_prekey_inventory(
    signed_prekey_present: bool,
    available_one_time_prekeys: usize,
    available_key_packages: usize,
    one_time_prekey_low_watermark: usize,
    key_package_low_watermark: usize,
) -> SecureMeshInventoryStatus {
    SecureMeshInventoryStatus {
        signed_prekey_present,
        available_one_time_prekeys,
        available_key_packages,
        one_time_prekey_low_watermark,
        key_package_low_watermark,
        should_upload_one_time_prekeys: available_one_time_prekeys <= one_time_prekey_low_watermark,
        should_upload_key_packages: available_key_packages <= key_package_low_watermark,
    }
}

pub fn prekey_public_key_from_base64url(value: &str) -> Result<Vec<u8>> {
    let bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(value.trim())
        .context("secure mesh prekey public key is not base64url")?;
    ensure!(
        !bytes.is_empty() && bytes.len() <= MAX_PUBLIC_KEY_BYTES,
        "secure mesh prekey public key size is outside bounds"
    );
    Ok(bytes)
}

fn validate_prekey_shape(
    record: &SecureMeshPreKeyRecord,
    kind: SecureMeshPreKeyKind,
    require_signature: bool,
) -> Result<()> {
    ensure!(
        !record.prekey_id.trim().is_empty(),
        "secure mesh {} id is required",
        kind.as_str()
    );
    ensure!(
        record.prekey_id.len() <= MAX_PREKEY_ID_LEN,
        "secure mesh {} id is too large",
        kind.as_str()
    );
    ensure!(
        !record.public_key.is_empty() && record.public_key.len() <= MAX_PUBLIC_KEY_BYTES,
        "secure mesh {} public key size is outside bounds",
        kind.as_str()
    );
    if require_signature {
        ensure_signature_shape(&record.signature, kind.as_str())?;
    }
    parse_rfc3339(&record.created_at, kind.as_str())?;
    parse_rfc3339(&record.expires_at, kind.as_str())?;
    Ok(())
}

fn validate_key_package_shape(
    record: &SecureMeshKeyPackageRecord,
    require_signature: bool,
) -> Result<()> {
    ensure!(
        !record.key_package_id.trim().is_empty(),
        "secure mesh MLS KeyPackage id is required"
    );
    ensure!(
        record.key_package_id.len() <= MAX_PREKEY_ID_LEN,
        "secure mesh MLS KeyPackage id is too large"
    );
    ensure!(
        record.cipher_suite == SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE
            || record.cipher_suite == SECURE_MESH_MLS_CIPHER_SUITE,
        "secure mesh MLS KeyPackage cipher suite is unsupported"
    );
    ensure!(
        !record.credential.trim().is_empty() && record.credential.len() <= MAX_CREDENTIAL_LEN,
        "secure mesh MLS KeyPackage credential is outside bounds"
    );
    ensure!(
        !record.public_key_package.is_empty()
            && record.public_key_package.len() <= MAX_KEYPACKAGE_BYTES,
        "secure mesh MLS KeyPackage public bytes are outside bounds"
    );
    if require_signature {
        ensure_signature_shape(&record.signature, "MLS KeyPackage")?;
    }
    parse_rfc3339(&record.created_at, "MLS KeyPackage")?;
    parse_rfc3339(&record.expires_at, "MLS KeyPackage")?;
    Ok(())
}

fn ensure_active_trust_state(
    trust_state: DeviceTrustState,
    require_verified_device: bool,
) -> Result<()> {
    match trust_state {
        DeviceTrustState::Verified | DeviceTrustState::CrossSigned => Ok(()),
        DeviceTrustState::Unverified if !require_verified_device => Ok(()),
        DeviceTrustState::Unverified => {
            bail_prekey("secure mesh endpoint is not verified for prekey use")
        }
        DeviceTrustState::KeyChanged => {
            bail_prekey("secure mesh endpoint identity changed; prekey use is paused")
        }
        DeviceTrustState::Revoked => bail_prekey("secure mesh endpoint is revoked"),
    }
}

fn ensure_signature_shape(signature: &str, label: &str) -> Result<()> {
    ensure!(
        !signature.trim().is_empty(),
        "secure mesh {label} signature is required"
    );
    ensure!(
        signature.len() <= MAX_SIGNATURE_B64_LEN,
        "secure mesh {label} signature is too large"
    );
    Ok(())
}

fn ensure_not_expired(
    created_at: &str,
    expires_at: &str,
    now: OffsetDateTime,
    label: &str,
) -> Result<()> {
    let created = parse_rfc3339(created_at, label)?;
    let expires = parse_rfc3339(expires_at, label)?;
    ensure!(
        expires > created,
        "secure mesh {label} expiresAt must be after createdAt"
    );
    ensure!(expires > now, "secure mesh {label} is expired");
    Ok(())
}

fn verify_signature(
    endpoint_identity: &DeviceTrustPublicIdentity,
    payload: &[u8],
    signature: &str,
    label: &str,
) -> Result<()> {
    let signature_bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(signature)
        .with_context(|| format!("secure mesh {label} signature is not base64url"))?;
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|error| anyhow!("secure mesh {label} signature is invalid: {error:?}"))?;
    endpoint_identity
        .signing_verifying_key()?
        .verify(payload, &signature)
        .map_err(|_| anyhow!("secure mesh {label} signature verification failed"))?;
    Ok(())
}

fn prekey_signature_payload(
    endpoint_identity: &DeviceTrustPublicIdentity,
    kind: SecureMeshPreKeyKind,
    record: &SecureMeshPreKeyRecord,
) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(PREKEY_MAGIC);
    append_len_prefixed_bytes(&mut out, SECURE_MESH_PREKEY_PROTOCOL_VERSION.as_bytes())?;
    append_len_prefixed_bytes(&mut out, endpoint_identity.endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, endpoint_identity.fingerprint()?.as_bytes())?;
    append_len_prefixed_bytes(&mut out, kind.as_str().as_bytes())?;
    append_len_prefixed_bytes(&mut out, record.prekey_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, record.created_at.as_bytes())?;
    append_len_prefixed_bytes(&mut out, record.expires_at.as_bytes())?;
    append_len_prefixed_bytes(&mut out, &record.public_key)?;
    Ok(out)
}

fn key_package_signature_payload(
    endpoint_identity: &DeviceTrustPublicIdentity,
    record: &SecureMeshKeyPackageRecord,
) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(KEYPACKAGE_MAGIC);
    append_len_prefixed_bytes(&mut out, SECURE_MESH_KEYPACKAGE_PROTOCOL_VERSION.as_bytes())?;
    append_len_prefixed_bytes(&mut out, endpoint_identity.endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, endpoint_identity.fingerprint()?.as_bytes())?;
    append_len_prefixed_bytes(&mut out, record.key_package_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, record.cipher_suite.as_bytes())?;
    append_len_prefixed_bytes(&mut out, record.credential.as_bytes())?;
    append_len_prefixed_bytes(&mut out, record.created_at.as_bytes())?;
    append_len_prefixed_bytes(&mut out, record.expires_at.as_bytes())?;
    append_len_prefixed_bytes(&mut out, &record.public_key_package)?;
    Ok(out)
}

fn parse_rfc3339(value: &str, label: &str) -> Result<OffsetDateTime> {
    OffsetDateTime::parse(value, &Rfc3339)
        .map_err(|error| anyhow!("secure mesh {label} timestamp is not RFC3339: {error}"))
}

fn append_len_prefixed_bytes(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len =
        u32::try_from(value.len()).map_err(|_| anyhow!("secure mesh prekey field is too large"))?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

fn bail_prekey<T>(message: &str) -> Result<T> {
    Err(anyhow!(message.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::VerifyingKey;
    use rand::rngs::OsRng;

    const NOW: &str = "2026-01-01T00:00:00Z";
    const CREATED_AT: &str = "2026-01-01T00:00:00Z";
    const EXPIRES_AT: &str = "2026-01-02T00:00:00Z";

    #[test]
    fn secure_mesh_prekey_bundle_verifies_signed_and_one_time_prekeys() {
        let (signing_key, identity) = identity_fixture("desktop:alice");
        let signed_prekey = signed_prekey_fixture(&signing_key, &identity, "spk-1");
        let one_time_prekey = one_time_prekey_fixture(&signing_key, &identity, "otpk-1");
        let bundle = SecureMeshPairwisePreKeyBundle {
            endpoint_identity: identity.clone(),
            trust_state: DeviceTrustState::CrossSigned,
            signed_prekey,
            one_time_prekey: Some(one_time_prekey),
            transparency_tree_head: "tree-head-1".to_string(),
        };
        let validation = validate_pairwise_prekey_bundle(
            &bundle,
            &SecureMeshPreKeyValidationPolicy::default(),
            now(),
        )
        .unwrap();
        assert_eq!(validation.endpoint_id, "desktop:alice");
        assert_eq!(validation.one_time_prekey_id, Some("otpk-1".to_string()));
    }

    #[test]
    fn secure_mesh_prekey_bundle_rejects_tampered_signed_prekey_signature() {
        let (signing_key, identity) = identity_fixture("desktop:alice");
        let mut signed_prekey = signed_prekey_fixture(&signing_key, &identity, "spk-1");
        signed_prekey.public_key[0] ^= 0x01;
        let bundle = SecureMeshPairwisePreKeyBundle {
            endpoint_identity: identity,
            trust_state: DeviceTrustState::Verified,
            signed_prekey,
            one_time_prekey: None,
            transparency_tree_head: "tree-head-1".to_string(),
        };
        let error = validate_pairwise_prekey_bundle(
            &bundle,
            &SecureMeshPreKeyValidationPolicy {
                require_verified_device: true,
                require_one_time_prekey: false,
            },
            now(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("signature verification failed"));
    }

    #[test]
    fn secure_mesh_prekey_bundle_requires_one_time_prekey_and_active_trust() {
        let (signing_key, identity) = identity_fixture("desktop:alice");
        let signed_prekey = signed_prekey_fixture(&signing_key, &identity, "spk-1");
        let bundle = SecureMeshPairwisePreKeyBundle {
            endpoint_identity: identity,
            trust_state: DeviceTrustState::KeyChanged,
            signed_prekey,
            one_time_prekey: None,
            transparency_tree_head: "tree-head-1".to_string(),
        };
        let error = validate_pairwise_prekey_bundle(
            &bundle,
            &SecureMeshPreKeyValidationPolicy::default(),
            now(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("identity changed"));
    }

    #[test]
    fn secure_mesh_prekey_bundle_rejects_expired_signed_prekey() {
        let (signing_key, identity) = identity_fixture("desktop:alice");
        let signed_prekey = sign_prekey_record(
            &signing_key,
            &identity,
            SecureMeshPreKeyKind::SignedPreKey,
            "spk-expired",
            vec![7; 32],
            "2025-12-01T00:00:00Z",
            "2025-12-02T00:00:00Z",
        )
        .unwrap();
        let bundle = SecureMeshPairwisePreKeyBundle {
            endpoint_identity: identity,
            trust_state: DeviceTrustState::Verified,
            signed_prekey,
            one_time_prekey: None,
            transparency_tree_head: "tree-head-1".to_string(),
        };
        let error = validate_pairwise_prekey_bundle(
            &bundle,
            &SecureMeshPreKeyValidationPolicy {
                require_verified_device: true,
                require_one_time_prekey: false,
            },
            now(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("prekey is expired"));
    }

    #[test]
    fn secure_mesh_keypackage_verifies_signature_and_rejects_downgrade_suite() {
        let (signing_key, identity) = identity_fixture("desktop:alice");
        let record = sign_key_package_record(
            &signing_key,
            &identity,
            "kp-1",
            SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE,
            "credential:alice",
            vec![9; 128],
            CREATED_AT,
            EXPIRES_AT,
        )
        .unwrap();
        verify_key_package_record(&identity, DeviceTrustState::Verified, &record, true, now())
            .unwrap();

        let mut downgraded = record.clone();
        downgraded.cipher_suite = "licolite.mls-legacy.v0".to_string();
        let error = verify_key_package_record(
            &identity,
            DeviceTrustState::Verified,
            &downgraded,
            true,
            now(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("cipher suite is unsupported"));
    }

    #[test]
    fn secure_mesh_prekey_inventory_low_water_requests_replenishment() {
        let status = evaluate_prekey_inventory(true, 2, 0, 5, 1);
        assert!(status.signed_prekey_present);
        assert!(status.should_upload_one_time_prekeys);
        assert!(status.should_upload_key_packages);
    }

    fn signed_prekey_fixture(
        signing_key: &SigningKey,
        identity: &DeviceTrustPublicIdentity,
        prekey_id: &str,
    ) -> SecureMeshPreKeyRecord {
        sign_prekey_record(
            signing_key,
            identity,
            SecureMeshPreKeyKind::SignedPreKey,
            prekey_id,
            vec![1; 32],
            CREATED_AT,
            EXPIRES_AT,
        )
        .unwrap()
    }

    fn one_time_prekey_fixture(
        signing_key: &SigningKey,
        identity: &DeviceTrustPublicIdentity,
        prekey_id: &str,
    ) -> SecureMeshPreKeyRecord {
        sign_prekey_record(
            signing_key,
            identity,
            SecureMeshPreKeyKind::OneTimePreKey,
            prekey_id,
            vec![2; 32],
            CREATED_AT,
            EXPIRES_AT,
        )
        .unwrap()
    }

    fn identity_fixture(endpoint_id: &str) -> (SigningKey, DeviceTrustPublicIdentity) {
        let identity_key = SigningKey::generate(&mut OsRng);
        let signing_key = SigningKey::generate(&mut OsRng);
        let identity = DeviceTrustPublicIdentity::new(
            endpoint_id,
            VerifyingKey::from(&identity_key).to_bytes(),
            VerifyingKey::from(&signing_key).to_bytes(),
            1,
        )
        .unwrap();
        (signing_key, identity)
    }

    fn now() -> OffsetDateTime {
        OffsetDateTime::parse(NOW, &Rfc3339).unwrap()
    }
}
