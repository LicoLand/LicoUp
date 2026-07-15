use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha256, Sha512};

pub const SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION: &str = "licolite.secure-mesh.device-trust.v2";
pub const SECURE_MESH_DEVICE_TRUST_STATUS: &str = "fingerprint_60_digit_safety_number_qr_policy_cli_gui_available_cross_signing_diagnostic_only_requires_durable_epoch_and_revocation_validation";

const DEVICE_IDENTITY_MAGIC: &[u8] = b"LCOSM-DID-v1";
const CROSS_SIGNATURE_MAGIC: &[u8] = b"LCOSM-XSG-v1";
const TRUST_RECORD_MAGIC: &[u8] = b"LCOSM-TRR-v1";
const SAS_MAGIC: &[u8] = b"LCOSM-SAFETY-NUMBER-v2";
const QR_MAGIC: &[u8] = b"LCOSM-QR-v2";
const PUBLIC_KEY_LEN: usize = 32;
const SAFETY_NUMBER_CHUNK_COUNT: usize = 12;
const SAFETY_NUMBER_DIGITS_PER_CHUNK: usize = 5;
const SAFETY_NUMBER_CHUNK_MODULUS: u32 = 100_000;

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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceTrustRecord {
    pub protocol_version: String,
    pub signer_endpoint_id: String,
    pub peer_endpoint_id: String,
    pub peer_fingerprint: String,
    pub trust_state: DeviceTrustState,
    pub roster_epoch: u64,
    pub verification_method: String,
    pub issued_at_epoch_seconds: u64,
    pub expires_at_epoch_seconds: u64,
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
        .verify_strict(&payload, &signature)
        .map_err(|_| anyhow!("secure mesh device cross-signature verification failed"))?;
    Ok(DeviceTrustState::CrossSigned)
}

pub fn sign_device_trust_record(
    signer_key: &SigningKey,
    signer_identity: &DeviceTrustPublicIdentity,
    peer_identity: &DeviceTrustPublicIdentity,
    trust_state: DeviceTrustState,
    roster_epoch: u64,
    verification_method: impl Into<String>,
    issued_at_epoch_seconds: u64,
    expires_at_epoch_seconds: u64,
) -> Result<DeviceTrustRecord> {
    signer_identity.validate()?;
    peer_identity.validate()?;
    ensure!(
        trusted_for_sensitive_use(&trust_state),
        "secure mesh device trust record must be verified or cross-signed"
    );
    ensure!(
        expires_at_epoch_seconds > issued_at_epoch_seconds,
        "secure mesh device trust record expiry must be after issue time"
    );
    let verification_method = verification_method.into();
    ensure!(
        !verification_method.trim().is_empty() && verification_method.len() <= 80,
        "secure mesh device trust record verification method is invalid"
    );
    let peer_fingerprint = peer_identity.fingerprint()?;
    let payload = trust_record_payload(
        &signer_identity.endpoint_id,
        &peer_identity.endpoint_id,
        &peer_fingerprint,
        trust_state_label(&trust_state),
        roster_epoch,
        verification_method.trim(),
        issued_at_epoch_seconds,
        expires_at_epoch_seconds,
    )?;
    let signature = signer_key.sign(&payload);
    Ok(DeviceTrustRecord {
        protocol_version: SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION.to_string(),
        signer_endpoint_id: signer_identity.endpoint_id.clone(),
        peer_endpoint_id: peer_identity.endpoint_id.clone(),
        peer_fingerprint,
        trust_state,
        roster_epoch,
        verification_method: verification_method.trim().to_string(),
        issued_at_epoch_seconds,
        expires_at_epoch_seconds,
        signature: general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes()),
    })
}

pub fn verify_device_trust_record(
    signer_identity: &DeviceTrustPublicIdentity,
    peer_identity: &DeviceTrustPublicIdentity,
    record: &DeviceTrustRecord,
    now_epoch_seconds: u64,
) -> Result<DeviceTrustState> {
    ensure!(
        record.protocol_version == SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION,
        "secure mesh device trust record protocol is unsupported"
    );
    ensure!(
        record.signer_endpoint_id == signer_identity.endpoint_id,
        "secure mesh device trust record signer mismatch"
    );
    ensure!(
        record.peer_endpoint_id == peer_identity.endpoint_id,
        "secure mesh device trust record peer mismatch"
    );
    ensure!(
        record.peer_fingerprint == peer_identity.fingerprint()?,
        "secure mesh device trust record fingerprint mismatch"
    );
    ensure!(
        trusted_for_sensitive_use(&record.trust_state),
        "secure mesh device trust record is not trusted for sensitive use"
    );
    ensure!(
        record.issued_at_epoch_seconds <= now_epoch_seconds,
        "secure mesh device trust record is not valid yet"
    );
    ensure!(
        now_epoch_seconds < record.expires_at_epoch_seconds,
        "secure mesh device trust record has expired"
    );
    let payload = trust_record_payload(
        &record.signer_endpoint_id,
        &record.peer_endpoint_id,
        &record.peer_fingerprint,
        trust_state_label(&record.trust_state),
        record.roster_epoch,
        &record.verification_method,
        record.issued_at_epoch_seconds,
        record.expires_at_epoch_seconds,
    )?;
    let signature_bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(&record.signature)
        .context("secure mesh device trust record signature is not base64url")?;
    let signature = Signature::from_slice(&signature_bytes).map_err(|error| {
        anyhow!("secure mesh device trust record signature is invalid: {error:?}")
    })?;
    signer_identity
        .signing_verifying_key()?
        .verify_strict(&payload, &signature)
        .map_err(|_| anyhow!("secure mesh device trust record verification failed"))?;
    Ok(record.trust_state.clone())
}

pub fn device_trust_record_to_json(record: &DeviceTrustRecord) -> Value {
    json!({
        "protocolVersion": record.protocol_version,
        "signerEndpointId": record.signer_endpoint_id,
        "peerEndpointId": record.peer_endpoint_id,
        "peerFingerprint": record.peer_fingerprint,
        "trustState": trust_state_label(&record.trust_state),
        "rosterEpoch": record.roster_epoch,
        "verificationMethod": record.verification_method,
        "issuedAtEpochSeconds": record.issued_at_epoch_seconds,
        "expiresAtEpochSeconds": record.expires_at_epoch_seconds,
        "signatureBase64url": record.signature
    })
}

pub fn device_trust_record_from_json(value: &Value) -> Result<DeviceTrustRecord> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("secure mesh device trust record must be an object"))?;
    Ok(DeviceTrustRecord {
        protocol_version: read_text_field(object, &["protocolVersion", "protocol_version"])?,
        signer_endpoint_id: read_text_field(object, &["signerEndpointId", "signer_endpoint_id"])?,
        peer_endpoint_id: read_text_field(object, &["peerEndpointId", "peer_endpoint_id"])?,
        peer_fingerprint: read_text_field(object, &["peerFingerprint", "peer_fingerprint"])?,
        trust_state: trust_state_from_label(
            object
                .get("trustState")
                .or_else(|| object.get("trust_state"))
                .and_then(Value::as_str)
                .unwrap_or_default(),
        )?,
        roster_epoch: read_u64_field(object, &["rosterEpoch", "roster_epoch"], 0)?,
        verification_method: read_text_field(
            object,
            &["verificationMethod", "verification_method"],
        )?,
        issued_at_epoch_seconds: read_u64_field(
            object,
            &["issuedAtEpochSeconds", "issued_at_epoch_seconds"],
            0,
        )?,
        expires_at_epoch_seconds: read_u64_field(
            object,
            &["expiresAtEpochSeconds", "expires_at_epoch_seconds"],
            0,
        )?,
        signature: read_text_field(object, &["signatureBase64url", "signature"])?,
    })
}

pub fn verify_device_trust_record_json(
    signer_identity: &DeviceTrustPublicIdentity,
    peer_identity: &DeviceTrustPublicIdentity,
    record: &Value,
    now_epoch_seconds: u64,
) -> Result<DeviceTrustState> {
    verify_device_trust_record(
        signer_identity,
        peer_identity,
        &device_trust_record_from_json(record)?,
        now_epoch_seconds,
    )
}

pub fn sas_decimal_chunks(
    first: &DeviceTrustPublicIdentity,
    second: &DeviceTrustPublicIdentity,
) -> Result<[String; SAFETY_NUMBER_CHUNK_COUNT]> {
    let (left, right) = ordered_pair(first, second)?;
    let mut canonical = Vec::new();
    canonical.extend_from_slice(SAS_MAGIC);
    append_len_prefixed_bytes(&mut canonical, left.fingerprint()?.as_bytes())?;
    append_len_prefixed_bytes(&mut canonical, right.fingerprint()?.as_bytes())?;
    let digest = Sha512::digest(&canonical);
    Ok(std::array::from_fn(|index| {
        let offset = index * 4;
        let value = u32::from_be_bytes([
            digest[offset],
            digest[offset + 1],
            digest[offset + 2],
            digest[offset + 3],
        ]);
        format!(
            "{:0width$}",
            value % SAFETY_NUMBER_CHUNK_MODULUS,
            width = SAFETY_NUMBER_DIGITS_PER_CHUNK
        )
    }))
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

/// Protected payload classes gated by Decision D5 verify-before-send.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProtectedSendPayloadKind {
    Command,
    Result,
    File,
    Lifecycle,
    Group,
    Acp,
    Prekey,
}

impl ProtectedSendPayloadKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Command => "command",
            Self::Result => "result",
            Self::File => "file",
            Self::Lifecycle => "lifecycle",
            Self::Group => "group",
            Self::Acp => "acp",
            Self::Prekey => "prekey",
        }
    }

    pub fn all() -> [Self; 7] {
        [
            Self::Command,
            Self::Result,
            Self::File,
            Self::Lifecycle,
            Self::Group,
            Self::Acp,
            Self::Prekey,
        ]
    }
}

/// Opaque token proving a peer passed verify-before-send for one protected payload kind.
/// Constructible only through [`authorize_protected_send`].
#[derive(Debug)]
pub struct ProtectedSendAuthorization {
    payload_kind: ProtectedSendPayloadKind,
    peer_endpoint_id: String,
}

impl ProtectedSendAuthorization {
    pub fn payload_kind(&self) -> ProtectedSendPayloadKind {
        self.payload_kind
    }

    pub fn peer_endpoint_id(&self) -> &str {
        &self.peer_endpoint_id
    }
}

/// Single enforcement point for Decision D5 verify-before-send.
/// Observation, relay-supplied trust labels, and cross-signing alone never authorize.
pub fn authorize_protected_send(
    peer_endpoint_id: &str,
    trust_state: &DeviceTrustState,
    payload_kind: ProtectedSendPayloadKind,
) -> Result<ProtectedSendAuthorization> {
    ensure!(
        !peer_endpoint_id.trim().is_empty(),
        "secure mesh protected send requires a peer endpoint id"
    );
    match trust_state {
        DeviceTrustState::Verified => Ok(ProtectedSendAuthorization {
            payload_kind,
            peer_endpoint_id: peer_endpoint_id.trim().to_string(),
        }),
        DeviceTrustState::Unverified => Err(anyhow!(
            "secure mesh protected {} send blocked: verification_required",
            payload_kind.as_str()
        )),
        DeviceTrustState::KeyChanged => Err(anyhow!(
            "secure mesh protected {} send blocked: identity_key_changed",
            payload_kind.as_str()
        )),
        DeviceTrustState::Revoked => Err(anyhow!(
            "secure mesh protected {} send blocked: device_revoked",
            payload_kind.as_str()
        )),
        DeviceTrustState::CrossSigned => Err(anyhow!(
            "secure mesh protected {} send blocked: cross_signature_requires_durable_epoch_validation",
            payload_kind.as_str()
        )),
    }
}

pub fn authorize_protected_send_from_trust_record(
    signer_identity: &DeviceTrustPublicIdentity,
    peer_identity: &DeviceTrustPublicIdentity,
    record: &DeviceTrustRecord,
    now_epoch_seconds: u64,
    payload_kind: ProtectedSendPayloadKind,
) -> Result<ProtectedSendAuthorization> {
    let trust_state =
        verify_device_trust_record(signer_identity, peer_identity, record, now_epoch_seconds)?;
    authorize_protected_send(&peer_identity.endpoint_id, &trust_state, payload_kind)
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
    // This stateless evaluator receives caller-controlled JSON and therefore cannot establish a
    // trust root. Positive authorization is owned by the locally persisted, locally signed trust
    // record consumed by the product route. Caller input may only reduce access here.
    let effective_trust_state = match (key_change_state.as_ref(), &requested_trust_state) {
        (Some(DeviceTrustState::KeyChanged), _) | (_, DeviceTrustState::KeyChanged) => {
            DeviceTrustState::KeyChanged
        }
        (_, DeviceTrustState::Revoked) => DeviceTrustState::Revoked,
        _ => DeviceTrustState::Unverified,
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
            "allowUnverifiedReadOnly": allow_unverified_read_only,
            "positiveAuthorizationSource": "persisted_local_signed_trust_record_only",
            "callerSuppliedTrustStateIsAdvisory": true
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

pub fn evaluate_device_trust_verification_json(
    params: &Value,
    verification_method: &str,
) -> Result<Value> {
    let local = device_identity_param(params, &["localIdentity", "firstIdentity", "leftIdentity"])?;
    let peer = device_identity_param(
        params,
        &["peerIdentity", "remoteIdentity", "secondIdentity"],
    )?;
    let roster_epoch = params
        .get("rosterEpoch")
        .or_else(|| params.get("roster_epoch"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let sas = sas_decimal_chunks(&local, &peer)?;
    let sas_text = sas.join("-");
    let qr_payload = qr_verification_payload(&local, &peer, roster_epoch)?;
    let observation_matched = match verification_method {
        "qr" => params
            .get("qrPayload")
            .or_else(|| params.get("qr_payload"))
            .and_then(Value::as_str)
            .is_some_and(|provided| provided.trim() == qr_payload),
        "sas" => provided_sas_text(params).is_some_and(|provided| provided == sas_text),
        _ => false,
    };
    Ok(json!({
        "ok": true,
        "protocolVersion": SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION,
        "method": verification_method,
        "localEndpointId": local.endpoint_id,
        "peerEndpointId": peer.endpoint_id,
        "localFingerprint": local.fingerprint()?,
        "peerFingerprint": peer.fingerprint()?,
        "sas": sas,
        "qrPayload": qr_payload,
        "observationMatched": observation_matched,
        "decision": {
            "allowedForPrekey": false,
            "allowedForHighRiskCommand": false,
            "requiresUserVerification": !observation_matched,
            "requiresPersistedTrustRecord": true,
            "code": if observation_matched {
                "verification_observation_requires_persisted_trust_record"
            } else {
                "verification_required"
            }
        },
        "keyMaterial": "redacted"
    }))
}

pub fn evaluate_device_trust_lifecycle_json(params: &Value, lifecycle: &str) -> Result<Value> {
    let identity =
        device_identity_param(params, &["identity", "currentIdentity", "deviceIdentity"])?;
    let mut policy_params = params.clone();
    let object = policy_params
        .as_object_mut()
        .ok_or_else(|| anyhow!("secure mesh device trust lifecycle params must be an object"))?;
    object.insert("identity".to_string(), json!({
        "endpointId": identity.endpoint_id,
        "identityPublicKey": general_purpose::URL_SAFE_NO_PAD.encode(identity.identity_public_key),
        "signingPublicKey": general_purpose::URL_SAFE_NO_PAD.encode(identity.signing_public_key),
        "rotationEpoch": identity.rotation_epoch
    }));
    let lifecycle_status = match lifecycle {
        "rotate" => {
            object.insert("trustState".to_string(), json!("verified"));
            "rotation_reverification_required"
        }
        "revoke" => {
            object.insert("trustState".to_string(), json!("revoked"));
            "revoked"
        }
        "recover" => {
            let recovery_confirmed = read_bool(params, "recoveryConfirmed", false);
            object.insert(
                "trustState".to_string(),
                json!(if recovery_confirmed {
                    "cross_signed"
                } else {
                    "unverified"
                }),
            );
            if recovery_confirmed {
                "recovery_confirmed"
            } else {
                "recovery_confirmation_required"
            }
        }
        _ => {
            return Err(anyhow!(
                "secure mesh device trust lifecycle action is unsupported"
            ));
        }
    };
    object.insert("requireVerifiedDevice".to_string(), json!(true));
    let policy = evaluate_device_trust_policy_json(&policy_params)?;
    Ok(json!({
        "ok": true,
        "protocolVersion": SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION,
        "lifecycle": lifecycle,
        "status": lifecycle_status,
        "fingerprint": policy["fingerprint"].clone(),
        "trustState": policy["trustState"].clone(),
        "keyChangeDetected": policy["keyChangeDetected"].clone(),
        "decision": policy["decision"].clone(),
        "keyMaterial": "redacted"
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

fn trust_record_payload(
    signer_endpoint_id: &str,
    peer_endpoint_id: &str,
    peer_fingerprint: &str,
    trust_state: &str,
    roster_epoch: u64,
    verification_method: &str,
    issued_at_epoch_seconds: u64,
    expires_at_epoch_seconds: u64,
) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(TRUST_RECORD_MAGIC);
    append_len_prefixed_bytes(
        &mut out,
        SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION.as_bytes(),
    )?;
    append_len_prefixed_bytes(&mut out, signer_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, peer_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, peer_fingerprint.as_bytes())?;
    append_len_prefixed_bytes(&mut out, trust_state.as_bytes())?;
    out.extend_from_slice(&roster_epoch.to_be_bytes());
    append_len_prefixed_bytes(&mut out, verification_method.as_bytes())?;
    out.extend_from_slice(&issued_at_epoch_seconds.to_be_bytes());
    out.extend_from_slice(&expires_at_epoch_seconds.to_be_bytes());
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

fn device_identity_param(params: &Value, keys: &[&str]) -> Result<DeviceTrustPublicIdentity> {
    let value = keys
        .iter()
        .find_map(|key| params.get(*key))
        .ok_or_else(|| anyhow!("secure mesh device trust identity is required"))?;
    device_identity_from_json(value)
}

fn provided_sas_text(params: &Value) -> Option<String> {
    let value = params.get("sas").or_else(|| params.get("sasCode"))?;
    if let Some(text) = value.as_str() {
        return Some(text.trim().replace(' ', "-"));
    }
    Some(
        value
            .as_array()?
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|chunk| !chunk.is_empty())
            .collect::<Vec<_>>()
            .join("-"),
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
    trust_state_from_label(value)
}

fn trust_state_from_label(value: &str) -> Result<DeviceTrustState> {
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
    matches!(value, DeviceTrustState::Verified)
}

fn usable_for_read_only(value: &DeviceTrustState, allow_unverified_read_only: bool) -> bool {
    match value {
        DeviceTrustState::Verified => true,
        DeviceTrustState::CrossSigned => allow_unverified_read_only,
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
        DeviceTrustState::Verified => "trusted",
        DeviceTrustState::CrossSigned => "cross_signature_requires_durable_epoch_validation",
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
        let forward = sas_decimal_chunks(&alice, &bob).unwrap();
        let reverse = sas_decimal_chunks(&bob, &alice).unwrap();
        assert_eq!(forward, reverse);
        assert_eq!(forward.len(), SAFETY_NUMBER_CHUNK_COUNT);
        assert_eq!(
            SAFETY_NUMBER_CHUNK_COUNT * SAFETY_NUMBER_DIGITS_PER_CHUNK,
            60
        );
        assert!(forward.iter().all(|chunk| {
            chunk.len() == SAFETY_NUMBER_DIGITS_PER_CHUNK
                && chunk.bytes().all(|byte| byte.is_ascii_digit())
        }));
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
    fn secure_mesh_device_trust_policy_json_treats_caller_verified_as_advisory_and_blocks_key_change()
     {
        let (_alice_key, alice) = identity_fixture("desktop_gui:alice");
        let (_replacement_key, mut replacement) = identity_fixture("desktop_gui:alice");
        replacement.endpoint_id = alice.endpoint_id.clone();
        let trusted = evaluate_device_trust_policy_json(&json!({
            "identity": identity_json(&alice),
            "trustState": "verified",
            "requireVerifiedDevice": true
        }))
        .unwrap();
        assert_eq!(trusted["requestedTrustState"], "verified");
        assert_eq!(trusted["trustState"], "unverified");
        assert_eq!(trusted["decision"]["allowedForPrekey"], false);
        assert_eq!(trusted["decision"]["allowedForHighRiskCommand"], false);
        assert_eq!(trusted["decision"]["code"], "verification_required");
        assert_eq!(
            trusted["policy"]["positiveAuthorizationSource"],
            "persisted_local_signed_trust_record_only"
        );

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

    #[test]
    fn secure_mesh_device_trust_record_signature_binds_peer_and_expiry() {
        let (alice_key, alice) = identity_fixture("desktop_gui:alice");
        let (_bob_key, bob) = identity_fixture("mobile:bob");
        let record = sign_device_trust_record(
            &alice_key,
            &alice,
            &bob,
            DeviceTrustState::Verified,
            12,
            "sas",
            100,
            200,
        )
        .unwrap();
        assert_eq!(
            verify_device_trust_record(&alice, &bob, &record, 150).unwrap(),
            DeviceTrustState::Verified
        );

        let (_mallory_key, mut mallory) = identity_fixture("mobile:bob");
        mallory.endpoint_id = bob.endpoint_id.clone();
        let error = verify_device_trust_record(&alice, &mallory, &record, 150).unwrap_err();
        assert!(error.to_string().contains("fingerprint mismatch"));

        let expired = verify_device_trust_record(&alice, &bob, &record, 200).unwrap_err();
        assert!(expired.to_string().contains("expired"));

        let mut tampered = record.clone();
        tampered.verification_method = "qr".to_string();
        let error = verify_device_trust_record(&alice, &bob, &tampered, 150).unwrap_err();
        assert!(error.to_string().contains("verification failed"));
    }

    #[test]
    fn secure_mesh_authorize_protected_send_blocks_unverified_key_changed_and_revoked_for_all_kinds()
     {
        for kind in ProtectedSendPayloadKind::all() {
            let authorized =
                authorize_protected_send("mobile:bob", &DeviceTrustState::Verified, kind).unwrap();
            assert_eq!(authorized.payload_kind(), kind);
            assert_eq!(authorized.peer_endpoint_id(), "mobile:bob");

            for (state, code) in [
                (DeviceTrustState::Unverified, "verification_required"),
                (DeviceTrustState::KeyChanged, "identity_key_changed"),
                (DeviceTrustState::Revoked, "device_revoked"),
                (
                    DeviceTrustState::CrossSigned,
                    "cross_signature_requires_durable_epoch_validation",
                ),
            ] {
                let error = authorize_protected_send("mobile:bob", &state, kind).unwrap_err();
                let message = error.to_string();
                assert!(
                    message.contains(code),
                    "kind {} state {:?} missing code {code}: {message}",
                    kind.as_str(),
                    state
                );
                assert!(
                    message.contains(kind.as_str()),
                    "kind {} missing from blocked send error: {message}",
                    kind.as_str()
                );
            }
        }
    }

    #[test]
    fn secure_mesh_authorize_protected_send_from_trust_record_and_rejects_observation_alone() {
        let (alice_key, alice) = identity_fixture("desktop_gui:alice");
        let (_bob_key, bob) = identity_fixture("mobile:bob");
        let record = sign_device_trust_record(
            &alice_key,
            &alice,
            &bob,
            DeviceTrustState::Verified,
            1,
            "qr",
            100,
            200,
        )
        .unwrap();
        let authorized = authorize_protected_send_from_trust_record(
            &alice,
            &bob,
            &record,
            150,
            ProtectedSendPayloadKind::Command,
        )
        .unwrap();
        assert_eq!(authorized.payload_kind(), ProtectedSendPayloadKind::Command);

        let observation = evaluate_device_trust_verification_json(
            &json!({
                "localIdentity": identity_json(&alice),
                "peerIdentity": identity_json(&bob),
                "qrPayload": qr_verification_payload(&alice, &bob, 1).unwrap(),
                "rosterEpoch": 1
            }),
            "qr",
        )
        .unwrap();
        assert_eq!(observation["observationMatched"], true);
        assert_eq!(observation["decision"]["allowedForHighRiskCommand"], false);
        assert_eq!(
            observation["decision"]["code"],
            "verification_observation_requires_persisted_trust_record"
        );
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
