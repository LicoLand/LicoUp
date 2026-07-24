use crate::core::secure_mesh_relay_envelope::{
    SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS, SecureMeshDeliverySecret,
    SecureMeshMailboxDirection, SecureMeshMailboxSchedule, SecureMeshRelayChannelBinding,
};
use crate::domain::mobile_relay::endpoint_trust::{decode_key_32, local_endpoint_state};
use crate::domain::mobile_relay::secret_custody::{
    MobileRelayE2eeSecretField, RuntimeSecretMaterial,
};
use anyhow::{Result, anyhow};
use serde_json::Value;
use sha2::{Digest, Sha256};
use time::OffsetDateTime;

pub(in crate::domain::mobile_relay) fn current_mailbox_rotation_epoch() -> Result<u64> {
    let now = u64::try_from(OffsetDateTime::now_utc().unix_timestamp())
        .map_err(|_| anyhow!("secure client relay mailbox clock is before unix epoch"))?;
    Ok(now / SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS)
}

pub(in crate::domain::mobile_relay) fn canonical_mailbox_token(
    secret_material: &RuntimeSecretMaterial,
    endpoint_id: &str,
    endpoint_kind: &str,
    rotation_epoch: u64,
) -> Result<String> {
    let pairing_secret = secret_material
        .e2ee_secret(MobileRelayE2eeSecretField::PairingSecret)
        .ok_or_else(|| anyhow!("secure client relay mailbox delivery secret is missing"))?
        .expose_utf8()
        .map_err(|_| anyhow!("secure client relay mailbox delivery secret is invalid"))?;
    let delivery_secret = SecureMeshDeliverySecret::from_bytes(decode_key_32(
        pairing_secret,
        "secure client relay mailbox delivery secret",
    )?);
    let direction = if endpoint_kind == "mobile" {
        SecureMeshMailboxDirection::PairwiseInitiatorToResponder
    } else {
        SecureMeshMailboxDirection::PairwiseResponderToInitiator
    };
    let binding: [u8; 32] = Sha256::digest(
        format!("secure-client-relay-channel:v1:{endpoint_kind}:{endpoint_id}").as_bytes(),
    )
    .into();
    let schedule = SecureMeshMailboxSchedule::new(
        delivery_secret,
        direction,
        SecureMeshRelayChannelBinding::from_bytes(binding),
    );
    let epoch_seconds = rotation_epoch
        .checked_mul(SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS)
        .ok_or_else(|| anyhow!("secure client relay mailbox rotation epoch overflow"))?;
    Ok(schedule
        .token_for_unix_seconds(epoch_seconds)?
        .as_str()
        .to_string())
}

pub(in crate::domain::mobile_relay) fn local_canonical_mailbox_token(
    config: &Value,
    secret_material: &RuntimeSecretMaterial,
) -> Result<String> {
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    canonical_mailbox_token(
        secret_material,
        state
            .get("endpointId")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("mobile relay endpoint id is missing"))?,
        state
            .get("endpointKind")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("mobile relay endpoint kind is missing"))?,
        state
            .get("mailboxRotationEpoch")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("mobile relay mailbox rotation epoch is missing"))?,
    )
}
