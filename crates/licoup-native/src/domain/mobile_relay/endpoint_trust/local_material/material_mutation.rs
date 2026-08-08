use super::identity_generation::{
    generate_endpoint_id, generate_identity_material, generate_pairing_secret, generate_session_id,
};
use super::prekey_inventory::ensure_mobile_relay_pqxdh_material;
use super::protocol_reset::reset_incompatible_local_pairwise_protocol;
use crate::core::secure_mesh_secret_store::SecretBytes;
use crate::domain::mobile_relay::relay_operations::current_mailbox_rotation_epoch;
use crate::domain::mobile_relay::secret_custody::{
    MobileRelayE2eeSecretField, RuntimeSecretMaterial,
};
use crate::domain::mobile_relay::support::MOBILE_RELAY_E2EE_PROTOCOL_VERSION;
use anyhow::Result;
use serde_json::{Value, json};

pub(in crate::domain::mobile_relay) fn ensure_mobile_relay_endpoint_material(
    config: &mut Value,
    secret_material: &mut RuntimeSecretMaterial,
    endpoint_kind: &str,
) -> Result<()> {
    if reset_incompatible_local_pairwise_protocol(config) {
        for field in MobileRelayE2eeSecretField::ALL {
            secret_material.remove_e2ee_secret(field);
        }
    }
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
