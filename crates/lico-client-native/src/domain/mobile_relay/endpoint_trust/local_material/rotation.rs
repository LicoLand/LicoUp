#[cfg(test)]
use super::identity_generation::generate_identity_material;
use super::prekey_inventory::ensure_mobile_relay_pqxdh_material;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub(in crate::domain::mobile_relay) fn rotate_mobile_relay_one_time_prekeys(
    config: &mut Value,
) -> Result<()> {
    let object = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    for key in [
        "oneTimePrekeyId",
        "oneTimePrekeyPrivateKeyBase64url",
        "oneTimePrekeyPublicKeyBase64url",
        "oneTimePrekeySignatureBase64url",
        "oneTimePrekeyCreatedAt",
        "oneTimePrekeyExpiresAt",
        "oneTimeMlKem1024PrekeyId",
        "oneTimeMlKem1024PrekeySeedBase64url",
        "oneTimeMlKem1024PrekeySeedMaterial",
        "oneTimeMlKem1024PrekeyPublicKeyBase64url",
        "oneTimeMlKem1024PrekeySignatureBase64url",
        "oneTimeMlKem1024PrekeyCreatedAt",
        "oneTimeMlKem1024PrekeyExpiresAt",
    ] {
        object.remove(key);
    }
    let next_publication_version = object
        .get("prekeyPublicationVersion")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| anyhow!("mobile relay prekey publication version overflow"))?;
    object.insert(
        "prekeyPublicationVersion".to_string(),
        json!(next_publication_version),
    );
    object.remove("keyTransparencyResponse");
    ensure_mobile_relay_pqxdh_material(config)
}

#[cfg(test)]
pub(in crate::domain::mobile_relay) fn rotate_mobile_relay_local_identity_for_repair(
    config: &mut Value,
) -> Result<()> {
    let object = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let next_rotation_epoch = object
        .get("rotationEpoch")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| anyhow!("mobile relay identity rotation epoch overflow"))?;
    let next_publication_version = object
        .get("prekeyPublicationVersion")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| anyhow!("mobile relay prekey publication version overflow"))?;
    for key in [
        "privateKeyBase64url",
        "privateKeyMaterial",
        "publicKeyBase64url",
        "fingerprint",
        "signingKeyBase64url",
        "signingKeyMaterial",
        "signingPublicKeyBase64url",
        "signedPrekeyId",
        "signedPrekeyPrivateKeyBase64url",
        "signedPrekeyPrivateKeyMaterial",
        "signedPrekeyPublicKeyBase64url",
        "signedPrekeySignatureBase64url",
        "signedPrekeyCreatedAt",
        "signedPrekeyExpiresAt",
        "oneTimePrekeyId",
        "oneTimePrekeyPrivateKeyBase64url",
        "oneTimePrekeyPrivateKeyMaterial",
        "oneTimePrekeyPublicKeyBase64url",
        "oneTimePrekeySignatureBase64url",
        "oneTimePrekeyCreatedAt",
        "oneTimePrekeyExpiresAt",
        "oneTimeMlKem1024PrekeyId",
        "oneTimeMlKem1024PrekeySeedBase64url",
        "oneTimeMlKem1024PrekeySeedMaterial",
        "oneTimeMlKem1024PrekeyPublicKeyBase64url",
        "oneTimeMlKem1024PrekeySignatureBase64url",
        "oneTimeMlKem1024PrekeyCreatedAt",
        "oneTimeMlKem1024PrekeyExpiresAt",
        "keyTransparencyResponse",
    ] {
        object.remove(key);
    }
    let generated = generate_identity_material();
    object.insert(
        "privateKeyBase64url".to_string(),
        json!(generated.private_key),
    );
    object.insert("rotationEpoch".to_string(), json!(next_rotation_epoch));
    object.insert(
        "prekeyPublicationVersion".to_string(),
        json!(next_publication_version),
    );
    ensure_mobile_relay_pqxdh_material(config)
}
