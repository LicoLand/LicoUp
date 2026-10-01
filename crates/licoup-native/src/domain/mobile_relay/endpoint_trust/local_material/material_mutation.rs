use super::identity_generation::{
    generate_endpoint_id, generate_identity_material, generate_pairing_secret, generate_session_id,
};
use super::prekey_inventory::ensure_mobile_relay_pqxdh_material;
use super::protocol_reset::ensure_local_pairwise_protocol_compatible;
use crate::core::secure_mesh_secret_store::SecretBytes;
use crate::domain::mobile_relay::relay_operations::current_mailbox_rotation_epoch;
use crate::domain::mobile_relay::secret_custody::{
    CUSTODY_NAMESPACE_FIELD, MobileRelayE2eeSecretField, RuntimeSecretMaterial,
};
use crate::domain::mobile_relay::support::MOBILE_RELAY_E2EE_PROTOCOL_VERSION;
use anyhow::{Result, ensure};
use serde_json::{Map, Value, json};

/// Presence of identity-bearing fields. Regenerating material over any of
/// these would silently replace an existing device identity.
pub(in crate::domain::mobile_relay) fn local_identity_metadata_present(
    object: &Map<String, Value>,
) -> bool {
    const IDENTITY_FIELDS: [&str; 6] = [
        "endpointId",
        "publicKeyBase64url",
        "fingerprint",
        "signingPublicKeyBase64url",
        "privateKeyBase64url",
        "signingKeyBase64url",
    ];
    IDENTITY_FIELDS.iter().any(|field| {
        object
            .get(*field)
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
    })
}

/// Refuse identity-bearing metadata that belongs to another data home.
///
/// This covers both a relocated restore (custody miss with copied metadata)
/// and a replacement import that would place source metadata over an active
/// target identity: the durable document records the home that wrote it, and
/// a different resolved home is refused without mutation. A same-home custody
/// miss (for example the documented ephemeral fallback after restart) keeps its
/// matching binding and may re-provision; a document written before the binding
/// existed adopts the current home on its next owning write.
fn ensure_identity_binding_matches_data_home(object: &Map<String, Value>) -> Result<()> {
    if !local_identity_metadata_present(object) {
        return Ok(());
    }
    let Some(recorded) = object
        .get(CUSTODY_NAMESPACE_FIELD)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Ok(());
    };
    let derived = crate::domain::mobile_relay::secret_custody::native_secret_store_namespace()?;
    ensure!(
        recorded == derived,
        "mobile relay device identity belongs to a different data home; refusing to replace or regenerate it over copied endpoint metadata"
    );
    Ok(())
}

pub(in crate::domain::mobile_relay) fn ensure_mobile_relay_endpoint_material(
    config: &mut Value,
    secret_material: &mut RuntimeSecretMaterial,
    endpoint_kind: &str,
) -> Result<()> {
    ensure_local_pairwise_protocol_compatible(config)?;
    if config
        .get("mobileRelayE2ee")
        .and_then(Value::as_object)
        .is_none()
    {
        config["mobileRelayE2ee"] = json!({});
    }
    if let Some(object) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    {
        ensure_identity_binding_matches_data_home(object)?;
        if secret_material
            .e2ee_secret(MobileRelayE2eeSecretField::PrivateKey)
            .is_none()
        {
            let generated = generate_identity_material();
            secret_material.insert_e2ee_secret(
                MobileRelayE2eeSecretField::PrivateKey,
                SecretBytes::try_from_string(generated.private_key)?,
            )?;
            object.insert(
                "publicKeyBase64url".to_string(),
                json!(generated.public_key),
            );
            object.insert("fingerprint".to_string(), json!(generated.fingerprint));
        }
        if !object
            .get("endpointId")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
        {
            object.insert(
                "endpointId".to_string(),
                json!(generate_endpoint_id(endpoint_kind)),
            );
        }
        if !object
            .get("sessionId")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
        {
            object.insert("sessionId".to_string(), json!(generate_session_id()));
        }
        object.insert(
            "protocolVersion".to_string(),
            json!(MOBILE_RELAY_E2EE_PROTOCOL_VERSION),
        );
        object.insert("endpointKind".to_string(), json!(endpoint_kind));
        object
            .entry("peerVerified".to_string())
            .or_insert_with(|| json!(false));
        if object
            .get("mailboxRotationEpoch")
            .and_then(Value::as_u64)
            .is_none()
        {
            object.insert(
                "mailboxRotationEpoch".to_string(),
                json!(current_mailbox_rotation_epoch()?),
            );
        }
        if secret_material
            .e2ee_secret(MobileRelayE2eeSecretField::PairingSecret)
            .is_none()
        {
            secret_material.insert_e2ee_secret(
                MobileRelayE2eeSecretField::PairingSecret,
                SecretBytes::try_from_string(generate_pairing_secret())?,
            )?;
        }
    }
    ensure_mobile_relay_pqxdh_material(config, secret_material)
}
