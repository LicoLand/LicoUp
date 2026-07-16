use super::identity_generation::{derive_identity_public, signing_material};
use super::prekey_generation::{curve_prekey_material, mlkem_prekey_material};
use crate::core::secure_mesh_prekey::SecureMeshPreKeyKind;
use crate::core::secure_mesh_trust::DeviceTrustPublicIdentity;
use crate::domain::mobile_relay::support::MOBILE_RELAY_E2EE_PROTOCOL_VERSION;
use anyhow::{Result, anyhow};
use serde_json::{Map, Value, json};

pub(in crate::domain::mobile_relay) fn ensure_mobile_relay_pqxdh_material(
    config: &mut Value,
) -> Result<()> {
    let object = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let endpoint_id = required_text(object, "endpointId", "mobile relay endpoint id is missing")?;
    let private_key = required_text(
        object,
        "privateKeyBase64url",
        "mobile relay local private key is missing",
    )?;
    let (identity_public, public_key, fingerprint) = derive_identity_public(&private_key)?;
    object.insert("publicKeyBase64url".to_string(), json!(public_key));
    object.insert("fingerprint".to_string(), json!(fingerprint));

    let existing_signing_key = optional_text(object, "signingKeyBase64url");
    let signing = signing_material(existing_signing_key.as_deref())?;
    if existing_signing_key.is_none() {
        object.insert(
            "signingKeyBase64url".to_string(),
            json!(signing.private_key),
        );
    }
    object.insert(
        "signingPublicKeyBase64url".to_string(),
        json!(signing.public_key),
    );
    let rotation_epoch = object
        .get("rotationEpoch")
        .and_then(Value::as_u64)
        .unwrap_or(1);
    object.insert("rotationEpoch".to_string(), json!(rotation_epoch));
    let publication_version = object
        .get("prekeyPublicationVersion")
        .and_then(Value::as_u64)
        .unwrap_or(1);
    object.insert(
        "prekeyPublicationVersion".to_string(),
        json!(publication_version),
    );
    object.insert(
        "protocolVersion".to_string(),
        json!(MOBILE_RELAY_E2EE_PROTOCOL_VERSION),
    );
    let identity = DeviceTrustPublicIdentity::new(
        endpoint_id,
        identity_public,
        signing.key.verifying_key().to_bytes(),
        rotation_epoch,
    )?;
    ensure_curve_prekey(
        object,
        &signing.key,
        &identity,
        SecureMeshPreKeyKind::SignedPreKey,
        CurveFields {
            id: "signedPrekeyId",
            private_key: "signedPrekeyPrivateKeyBase64url",
            public_key: "signedPrekeyPublicKeyBase64url",
            signature: "signedPrekeySignatureBase64url",
            created_at: "signedPrekeyCreatedAt",
            expires_at: "signedPrekeyExpiresAt",
        },
        "spk",
    )?;
    ensure_curve_prekey(
        object,
        &signing.key,
        &identity,
        SecureMeshPreKeyKind::OneTimePreKey,
        CurveFields {
            id: "oneTimePrekeyId",
            private_key: "oneTimePrekeyPrivateKeyBase64url",
            public_key: "oneTimePrekeyPublicKeyBase64url",
            signature: "oneTimePrekeySignatureBase64url",
            created_at: "oneTimePrekeyCreatedAt",
            expires_at: "oneTimePrekeyExpiresAt",
        },
        "otpk",
    )?;
    ensure_mlkem_prekey(object, &signing.key, &identity)
}

struct CurveFields {
    id: &'static str,
    private_key: &'static str,
    public_key: &'static str,
    signature: &'static str,
    created_at: &'static str,
    expires_at: &'static str,
}

fn ensure_curve_prekey(
    object: &mut Map<String, Value>,
    signing_key: &ed25519_dalek::SigningKey,
    identity: &DeviceTrustPublicIdentity,
    kind: SecureMeshPreKeyKind,
    fields: CurveFields,
    id_prefix: &str,
) -> Result<()> {
    let material = curve_prekey_material(
        optional_text(object, fields.private_key).as_deref(),
        optional_text(object, fields.id).as_deref(),
        optional_text(object, fields.created_at).as_deref(),
        optional_text(object, fields.expires_at).as_deref(),
        signing_key,
        identity,
        kind,
        id_prefix,
    )?;
    object.insert(fields.id.to_string(), json!(material.id));
    object.insert(fields.private_key.to_string(), json!(material.private_key));
    object.insert(fields.public_key.to_string(), json!(material.public_key));
    object.insert(fields.signature.to_string(), json!(material.signature));
    object.insert(fields.created_at.to_string(), json!(material.created_at));
    object.insert(fields.expires_at.to_string(), json!(material.expires_at));
    Ok(())
}

fn ensure_mlkem_prekey(
    object: &mut Map<String, Value>,
    signing_key: &ed25519_dalek::SigningKey,
    identity: &DeviceTrustPublicIdentity,
) -> Result<()> {
    let material = mlkem_prekey_material(
        optional_text(object, "oneTimeMlKem1024PrekeySeedBase64url").as_deref(),
        optional_text(object, "oneTimeMlKem1024PrekeyId").as_deref(),
        optional_text(object, "oneTimeMlKem1024PrekeyCreatedAt").as_deref(),
        optional_text(object, "oneTimeMlKem1024PrekeyExpiresAt").as_deref(),
        signing_key,
        identity,
    )?;
    object.insert("oneTimeMlKem1024PrekeyId".to_string(), json!(material.id));
    object.insert(
        "oneTimeMlKem1024PrekeySeedBase64url".to_string(),
        json!(material.seed),
    );
    object.insert(
        "oneTimeMlKem1024PrekeyPublicKeyBase64url".to_string(),
        json!(material.public_key),
    );
    object.insert(
        "oneTimeMlKem1024PrekeySignatureBase64url".to_string(),
        json!(material.signature),
    );
    object.insert(
        "oneTimeMlKem1024PrekeyCreatedAt".to_string(),
        json!(material.created_at),
    );
    object.insert(
        "oneTimeMlKem1024PrekeyExpiresAt".to_string(),
        json!(material.expires_at),
    );
    Ok(())
}

fn optional_text(object: &Map<String, Value>, field: &str) -> Option<String> {
    object
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn required_text(object: &Map<String, Value>, field: &str, error: &'static str) -> Result<String> {
    optional_text(object, field).ok_or_else(|| anyhow!("{error}"))
}
