use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub const SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION: &str = "licolite.secure-mesh.device-trust.v1";
pub const SECURE_MESH_DEVICE_TRUST_STATUS: &str =
    "fingerprint_cross_signing_sas_qr_policy_cli_gui_available";

const DEVICE_IDENTITY_MAGIC: &[u8] = b"LCOSM-DID-v1";
const CROSS_SIGNATURE_MAGIC: &[u8] = b"LCOSM-XSG-v1";
const SAS_MAGIC: &[u8] = b"LCOSM-SAS-v1";
const QR_MAGIC: &[u8] = b"LCOSM-QR-v1";
const PUBLIC_KEY_LEN: usize = 32;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DeviceTrustState {
    Unverified,
    Verified,
    CrossSigned,
    KeyChanged,
    Revoked,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceTrustPublicIdentity {
    pub endpoint_id: String,
    pub identity_public_key: [u8; PUBLIC_KEY_LEN],
    pub signing_public_key: [u8; PUBLIC_KEY_LEN],
    pub rotation_epoch: u64,
}

impl DeviceTrustPublicIdentity {
    pub fn new(
        endpoint_id: impl Into<String>,
        identity_public_key: [u8; PUBLIC_KEY_LEN],
        signing_public_key: [u8; PUBLIC_KEY_LEN],
        rotation_epoch: u64,
    ) -> Result<Self> {
        let value = Self {
            endpoint_id: endpoint_id.into(),
            identity_public_key,
            signing_public_key,
            rotation_epoch,
        };
        value.validate()?;
        Ok(value)
    }

    pub fn signing_verifying_key(&self) -> Result<VerifyingKey> {
        VerifyingKey::from_bytes(&self.signing_public_key)
            .map_err(|error| anyhow!("secure mesh signing public key is invalid: {error:?}"))
    }

    pub fn fingerprint(&self) -> Result<String> {
        Ok(hash_bytes(&self.canonical_bytes()?))
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            !self.endpoint_id.trim().is_empty(),
            "secure mesh endpoint id is required"
        );
        ensure!(
            self.endpoint_id.len() <= 255,
            "secure mesh endpoint id is too large"
        );
        Ok(())
    }

    fn canonical_bytes(&self) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        out.extend_from_slice(DEVICE_IDENTITY_MAGIC);
        append_len_prefixed_bytes(
            &mut out,
            SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION.as_bytes(),
        )?;
        append_len_prefixed_bytes(&mut out, self.endpoint_id.as_bytes())?;
        out.extend_from_slice(&self.rotation_epoch.to_be_bytes());
        append_len_prefixed_bytes(&mut out, &self.identity_public_key)?;
        append_len_prefixed_bytes(&mut out, &self.signing_public_key)?;
        Ok(out)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceCrossSignature {
    pub protocol_version: String,
    pub signer_endpoint_id: String,
    pub subject_endpoint_id: String,
    pub subject_fingerprint: String,
    pub roster_epoch: u64,
    pub signature: String,
}

pub fn sign_device_cross_signature(
    signer_key: &SigningKey,
    signer_identity: &DeviceTrustPublicIdentity,
    subject: &DeviceTrustPublicIdentity,
    roster_epoch: u64,
) -> Result<DeviceCrossSignature> {
    signer_identity.validate()?;
    subject.validate()?;
    let payload = cross_signature_payload(
        &signer_identity.endpoint_id,
        &subject.endpoint_id,
        &subject.fingerprint()?,
        roster_epoch,
    )?;
    let signature = signer_key.sign(&payload);
    Ok(DeviceCrossSignature {
        protocol_version: SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION.to_string(),
        signer_endpoint_id: signer_identity.endpoint_id.clone(),
        subject_endpoint_id: subject.endpoint_id.clone(),
        subject_fingerprint: subject.fingerprint()?,
        roster_epoch,
        signature: general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes()),
    })
}

pub fn verify_device_cross_signature(
    signer: &DeviceTrustPublicIdentity,
    subject: &DeviceTrustPublicIdentity,
    cross_signature: &DeviceCrossSignature,
) -> Result<DeviceTrustState> {
    ensure!(
        cross_signature.protocol_version == SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION,
        "secure mesh device cross-signature protocol is unsupported"
    );
    ensure!(
        cross_signature.signer_endpoint_id == signer.endpoint_id,
        "secure mesh device cross-signature signer mismatch"
    );
    ensure!(
        cross_signature.subject_endpoint_id == subject.endpoint_id,
        "secure mesh device cross-signature subject mismatch"
    );
    ensure!(
        cross_signature.subject_fingerprint == subject.fingerprint()?,
        "secure mesh device cross-signature fingerprint mismatch"
    );
    let payload = cross_signature_payload(
        &cross_signature.signer_endpoint_id,
        &cross_signature.subject_endpoint_id,
        &cross_signature.subject_fingerprint,
        cross_signature.roster_epoch,
    )?;
    let signature_bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(&cross_signature.signature)
        .context("secure mesh device cross-signature is not base64url")?;
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|error| anyhow!("secure mesh device cross-signature is invalid: {error:?}"))?;
    signer
        .signing_verifying_key()?
        .verify(&payload, &signature)
        .map_err(|_| anyhow!("secure mesh device cross-signature verification failed"))?;
    Ok(DeviceTrustState::CrossSigned)
}

pub fn sas_decimal_chunks(
    first: &DeviceTrustPublicIdentity,
    second: &DeviceTrustPublicIdentity,
) -> Result<[String; 3]> {
    let (left, right) = ordered_pair(first, second)?;
    let mut canonical = Vec::new();
    canonical.extend_from_slice(SAS_MAGIC);
    append_len_prefixed_bytes(&mut canonical, left.fingerprint()?.as_bytes())?;
    append_len_prefixed_bytes(&mut canonical, right.fingerprint()?.as_bytes())?;
    let digest = Sha256::digest(&canonical);
    Ok([
        format!("{:04}", u16::from_be_bytes([digest[0], digest[1]]) % 10_000),
        format!("{:04}", u16::from_be_bytes([digest[2], digest[3]]) % 10_000),
        format!("{:04}", u16::from_be_bytes([digest[4], digest[5]]) % 10_000),
    ])
}

pub fn qr_verification_payload(
    first: &DeviceTrustPublicIdentity,
    second: &DeviceTrustPublicIdentity,
    roster_epoch: u64,
) -> Result<String> {
    let (left, right) = ordered_pair(first, second)?;
    let mut payload = Vec::new();
    payload.extend_from_slice(QR_MAGIC);
    append_len_prefixed_bytes(
        &mut payload,
        SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION.as_bytes(),
    )?;
    payload.extend_from_slice(&roster_epoch.to_be_bytes());
    append_len_prefixed_bytes(&mut payload, left.endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut payload, left.fingerprint()?.as_bytes())?;
    append_len_prefixed_bytes(&mut payload, right.endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut payload, right.fingerprint()?.as_bytes())?;
    append_len_prefixed_bytes(
        &mut payload,
        sas_decimal_chunks(left, right)?.join("-").as_bytes(),
    )?;
    Ok(format!(
        "{}:{}",
        SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION,
        general_purpose::URL_SAFE_NO_PAD.encode(payload)
    ))
}

pub fn detect_identity_key_change(
    previous: &DeviceTrustPublicIdentity,
    current: &DeviceTrustPublicIdentity,
) -> Result<DeviceTrustState> {
    ensure!(
        previous.endpoint_id == current.endpoint_id,
        "secure mesh device key-change check endpoint mismatch"
    );
    if previous.fingerprint()? == current.fingerprint()? {
        Ok(DeviceTrustState::Verified)
    } else {
        Ok(DeviceTrustState::KeyChanged)
    }
}

pub fn evaluate_device_trust_policy_json(params: &Value) -> Result<Value> {
    let identity_value = params
        .get("identity")
        .or_else(|| params.get("deviceIdentity"))
        .or_else(|| params.get("currentIdentity"))
        .ok_or_else(|| anyhow!("secure mesh device trust identity is required"))?;
    let identity = device_identity_from_json(identity_value)?;
    let previous_identity = params
        .get("previousIdentity")
        .and_then(|value| {
            if value.is_null() {
                None
            } else {
                Some(device_identity_from_json(value))
            }
        })
        .transpose()?;
    let requested_trust_state = trust_state_from_json(params)?;
    let key_change_state = previous_identity
        .as_ref()
        .map(|previous| detect_identity_key_change(previous, &identity))
        .transpose()?;
    let effective_trust_state = match key_change_state.as_ref() {
        Some(DeviceTrustState::KeyChanged) => DeviceTrustState::KeyChanged,
        _ => requested_trust_state.clone(),
    };
    let require_verified_device = read_bool(params, "requireVerifiedDevice", true);
    let allow_unverified_read_only = read_bool(params, "allowUnverifiedReadOnly", false);
    let allowed_for_prekey = if require_verified_device {
        trusted_for_sensitive_use(&effective_trust_state)
    } else {
        usable_for_read_only(&effective_trust_state, allow_unverified_read_only)
    };
    let allowed_for_high_risk = trusted_for_sensitive_use(&effective_trust_state);
    let allowed_for_read_only =
        usable_for_read_only(&effective_trust_state, allow_unverified_read_only);
    let decision_code = device_trust_decision_code(
        &effective_trust_state,
        require_verified_device,
        allow_unverified_read_only,
    );
    Ok(json!({
        "ok": true,
        "protocolVersion": SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION,
        "endpointId": identity.endpoint_id,
        "fingerprint": identity.fingerprint()?,
        "trustState": trust_state_label(&effective_trust_state),
        "requestedTrustState": trust_state_label(&requested_trust_state),
        "keyChangeDetected": key_change_state == Some(DeviceTrustState::KeyChanged),
        "policy": {
            "requireVerifiedDevice": require_verified_device,
            "allowUnverifiedReadOnly": allow_unverified_read_only
        },
        "decision": {
            "allowedForPrekey": allowed_for_prekey,
            "allowedForHighRiskCommand": allowed_for_high_risk,
            "allowedForReadOnlyCommand": allowed_for_read_only,
            "requiresUserVerification": !allowed_for_high_risk,
            "code": decision_code
        }
    }))
}

fn cross_signature_payload(
    signer_endpoint_id: &str,
    subject_endpoint_id: &str,
    subject_fingerprint: &str,
    roster_epoch: u64,
) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(CROSS_SIGNATURE_MAGIC);
    append_len_prefixed_bytes(
        &mut out,
        SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION.as_bytes(),
    )?;
    append_len_prefixed_bytes(&mut out, signer_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, subject_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, subject_fingerprint.as_bytes())?;
    out.extend_from_slice(&roster_epoch.to_be_bytes());
    Ok(out)
}

fn ordered_pair<'a>(
    first: &'a DeviceTrustPublicIdentity,
    second: &'a DeviceTrustPublicIdentity,
) -> Result<(&'a DeviceTrustPublicIdentity, &'a DeviceTrustPublicIdentity)> {
    ensure!(
        first.endpoint_id != second.endpoint_id,
        "secure mesh device verification requires two distinct endpoints"
    );
    if first.endpoint_id <= second.endpoint_id {
        Ok((first, second))
    } else {
        Ok((second, first))
    }
}

fn append_len_prefixed_bytes(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len = u32::try_from(value.len())
        .map_err(|_| anyhow!("secure mesh device trust field is too large"))?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

fn hash_bytes(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    format!("sha256:{}", general_purpose::URL_SAFE_NO_PAD.encode(digest))
}

fn device_identity_from_json(value: &Value) -> Result<DeviceTrustPublicIdentity> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("secure mesh device trust identity must be an object"))?;
    DeviceTrustPublicIdentity::new(
        read_text_field(object, &["endpointId", "endpoint_id"])?,
        read_public_key_field(object, &["identityPublicKey", "identity_public_key"])?,
        read_public_key_field(object, &["signingPublicKey", "signing_public_key"])?,
        read_u64_field(object, &["rotationEpoch", "rotation_epoch"], 0)?,
    )
}

fn read_text_field(object: &serde_json::Map<String, Value>, keys: &[&str]) -> Result<String> {
    let value = keys
        .iter()
        .find_map(|key| object.get(*key))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    ensure!(
        !value.is_empty(),
        "secure mesh device trust text field is required"
    );
    Ok(value)
}

fn read_u64_field(
    object: &serde_json::Map<String, Value>,
    keys: &[&str],
    default_value: u64,
) -> Result<u64> {
    let Some(value) = keys.iter().find_map(|key| object.get(*key)) else {
        return Ok(default_value);
    };
    if let Some(number) = value.as_u64() {
        return Ok(number);
    }
    value
        .as_str()
        .unwrap_or_default()
        .trim()
        .parse::<u64>()
        .map_err(|_| anyhow!("secure mesh device trust integer field is invalid"))
}

fn read_public_key_field(
    object: &serde_json::Map<String, Value>,
    keys: &[&str],
) -> Result<[u8; PUBLIC_KEY_LEN]> {
    let raw = keys
        .iter()
        .find_map(|key| object.get(*key))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    ensure!(
        !raw.is_empty(),
        "secure mesh device trust public key is required"
    );
    let bytes = decode_public_key(raw)?;
    bytes
        .try_into()
        .map_err(|_| anyhow!("secure mesh device trust public key must be 32 bytes"))
}

fn decode_public_key(raw: &str) -> Result<Vec<u8>> {
    general_purpose::URL_SAFE_NO_PAD
        .decode(raw)
        .or_else(|_| general_purpose::STANDARD.decode(raw))
        .or_else(|_| decode_hex(raw))
        .map_err(|_| anyhow!("secure mesh device trust public key is not base64url or hex"))
}

fn decode_hex(raw: &str) -> Result<Vec<u8>, ()> {
    let normalized = raw
        .chars()
        .filter(|ch| !matches!(ch, ':' | '-' | ' '))
        .collect::<String>();
    if normalized.len() % 2 != 0 {
        return Err(());
    }
    let mut out = Vec::with_capacity(normalized.len() / 2);
    for index in (0..normalized.len()).step_by(2) {
        let byte = u8::from_str_radix(&normalized[index..index + 2], 16).map_err(|_| ())?;
        out.push(byte);
    }
    Ok(out)
}

fn trust_state_from_json(params: &Value) -> Result<DeviceTrustState> {
    let value = params
        .get("trustState")
        .or_else(|| params.get("trust_state"))
        .or_else(|| {
            params
                .get("identity")
                .and_then(|identity| identity.get("trustState"))
        })
        .and_then(Value::as_str)
        .unwrap_or("unverified");
    match value.trim() {
        "unverified" => Ok(DeviceTrustState::Unverified),
        "verified" => Ok(DeviceTrustState::Verified),
        "cross_signed" | "crossSigned" => Ok(DeviceTrustState::CrossSigned),
        "key_changed" | "keyChanged" => Ok(DeviceTrustState::KeyChanged),
        "revoked" => Ok(DeviceTrustState::Revoked),
        _ => Err(anyhow!("secure mesh device trust state is unsupported")),
    }
}

fn trust_state_label(value: &DeviceTrustState) -> &'static str {
    match value {
        DeviceTrustState::Unverified => "unverified",
        DeviceTrustState::Verified => "verified",
        DeviceTrustState::CrossSigned => "cross_signed",
        DeviceTrustState::KeyChanged => "key_changed",
        DeviceTrustState::Revoked => "revoked",
    }
}

fn read_bool(params: &Value, key: &str, default_value: bool) -> bool {
    match params.get(key) {
        Some(Value::Bool(value)) => *value,
        Some(Value::String(value)) => match value.trim() {
            "true" | "1" | "yes" => true,
            "false" | "0" | "no" => false,
            _ => default_value,
        },
        _ => default_value,
    }
}

fn trusted_for_sensitive_use(value: &DeviceTrustState) -> bool {
    matches!(
        value,
        DeviceTrustState::Verified | DeviceTrustState::CrossSigned
    )
}

fn usable_for_read_only(value: &DeviceTrustState, allow_unverified_read_only: bool) -> bool {
    match value {
        DeviceTrustState::Verified | DeviceTrustState::CrossSigned => true,
        DeviceTrustState::Unverified => allow_unverified_read_only,
        DeviceTrustState::KeyChanged | DeviceTrustState::Revoked => false,
    }
}

fn device_trust_decision_code(
    value: &DeviceTrustState,
    require_verified_device: bool,
    allow_unverified_read_only: bool,
) -> &'static str {
    match value {
        DeviceTrustState::Verified | DeviceTrustState::CrossSigned => "trusted",
        DeviceTrustState::Unverified if !require_verified_device && allow_unverified_read_only => {
            "read_only_unverified"
        }
        DeviceTrustState::Unverified => "verification_required",
        DeviceTrustState::KeyChanged => "identity_key_changed",
        DeviceTrustState::Revoked => "device_revoked",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::OsRng;

    #[test]
    fn secure_mesh_device_cross_signature_verifies_and_rejects_tamper() {
        let (alice_key, alice) = identity_fixture("desktop_gui:alice");
        let (_bob_key, bob) = identity_fixture("mobile:bob");
        let cross_signature = sign_device_cross_signature(&alice_key, &alice, &bob, 7).unwrap();
        assert_eq!(
            verify_device_cross_signature(&alice, &bob, &cross_signature).unwrap(),
            DeviceTrustState::CrossSigned
        );

        let mut tampered = bob.clone();
        tampered.rotation_epoch = 2;
        let error = verify_device_cross_signature(&alice, &tampered, &cross_signature).unwrap_err();
        assert!(error.to_string().contains("fingerprint mismatch"));
    }

    #[test]
    fn secure_mesh_device_sas_is_symmetric() {
        let (_alice_key, alice) = identity_fixture("desktop_gui:alice");
        let (_bob_key, bob) = identity_fixture("mobile:bob");
        assert_eq!(
            sas_decimal_chunks(&alice, &bob).unwrap(),
            sas_decimal_chunks(&bob, &alice).unwrap()
        );
    }

    #[test]
    fn secure_mesh_device_qr_payload_uses_fingerprints_not_raw_keys() {
        let (_alice_key, alice) = identity_fixture("desktop_gui:alice");
        let (_bob_key, bob) = identity_fixture("mobile:bob");
        let payload = qr_verification_payload(&alice, &bob, 9).unwrap();
        assert!(payload.starts_with(SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION));
        assert!(
            !payload.contains(&general_purpose::URL_SAFE_NO_PAD.encode(alice.identity_public_key))
        );
        assert!(
            !payload.contains(&general_purpose::URL_SAFE_NO_PAD.encode(bob.signing_public_key))
        );
    }

    #[test]
    fn secure_mesh_device_key_change_is_detected() {
        let (_alice_key, alice) = identity_fixture("desktop_gui:alice");
        let (_replacement_key, mut replacement) = identity_fixture("desktop_gui:alice");
        replacement.endpoint_id = alice.endpoint_id.clone();
        assert_eq!(
            detect_identity_key_change(&alice, &alice).unwrap(),
            DeviceTrustState::Verified
        );
        assert_eq!(
            detect_identity_key_change(&alice, &replacement).unwrap(),
            DeviceTrustState::KeyChanged
        );
    }

    #[test]
    fn secure_mesh_device_trust_policy_json_allows_verified_and_blocks_key_change() {
        let (_alice_key, alice) = identity_fixture("desktop_gui:alice");
        let (_replacement_key, mut replacement) = identity_fixture("desktop_gui:alice");
        replacement.endpoint_id = alice.endpoint_id.clone();
        let trusted = evaluate_device_trust_policy_json(&json!({
            "identity": identity_json(&alice),
            "trustState": "verified",
            "requireVerifiedDevice": true
        }))
        .unwrap();
        assert_eq!(trusted["decision"]["allowedForPrekey"], true);
        assert_eq!(trusted["decision"]["allowedForHighRiskCommand"], true);
        assert_eq!(trusted["decision"]["code"], "trusted");

        let changed = evaluate_device_trust_policy_json(&json!({
            "identity": identity_json(&replacement),
            "previousIdentity": identity_json(&alice),
            "trustState": "verified",
            "requireVerifiedDevice": true
        }))
        .unwrap();
        assert_eq!(changed["keyChangeDetected"], true);
        assert_eq!(changed["trustState"], "key_changed");
        assert_eq!(changed["decision"]["allowedForPrekey"], false);
        assert_eq!(changed["decision"]["code"], "identity_key_changed");
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

    fn identity_json(identity: &DeviceTrustPublicIdentity) -> Value {
        json!({
            "endpointId": identity.endpoint_id,
            "identityPublicKey": general_purpose::URL_SAFE_NO_PAD.encode(identity.identity_public_key),
            "signingPublicKey": general_purpose::URL_SAFE_NO_PAD.encode(identity.signing_public_key),
            "rotationEpoch": identity.rotation_epoch
        })
    }
}
