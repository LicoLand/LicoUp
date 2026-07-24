//! Strict JSON wire model, serialization, canonical base64url bounds, and bucket validation.

use anyhow::{Context, Result, anyhow, ensure};
use serde::Deserialize;

use super::codec::{decode_bounded_base64url, decode_exact_base64url};
use super::constants::{
    DELIVERY_ID_BYTES, JSON_SAFE_INTEGER_MAX, MAILBOX_TOKEN_BYTES, MAX_RELAY_ENVELOPE_JSON_BYTES,
    SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES, SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
};
use super::envelope::SecureMeshRelayEnvelope;
use crate::core::secure_mesh_crypto::validate_authenticated_padding_bucket;

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(super) struct SecureMeshRelayEnvelopeWire {
    pub(in crate::core::secure_mesh_relay_envelope) schema: String,
    pub(in crate::core::secure_mesh_relay_envelope) delivery_id: String,
    pub(in crate::core::secure_mesh_relay_envelope) mailbox_token: String,
    pub(in crate::core::secure_mesh_relay_envelope) encrypted_header: String,
    pub(in crate::core::secure_mesh_relay_envelope) ciphertext_bucket: u64,
    pub(in crate::core::secure_mesh_relay_envelope) ciphertext: String,
}

impl SecureMeshRelayEnvelope {
    pub fn from_json(wire: &str) -> Result<Self> {
        ensure!(
            wire.len() <= MAX_RELAY_ENVELOPE_JSON_BYTES,
            "secure mesh relay envelope JSON is too large"
        );
        let wire_envelope: SecureMeshRelayEnvelopeWire =
            serde_json::from_str(wire).context("secure mesh relay envelope JSON is invalid")?;
        let envelope = Self {
            schema: wire_envelope.schema,
            delivery_id: wire_envelope.delivery_id,
            mailbox_token: wire_envelope.mailbox_token,
            encrypted_header: wire_envelope.encrypted_header,
            ciphertext_bucket: wire_envelope.ciphertext_bucket,
            ciphertext: wire_envelope.ciphertext,
        };
        envelope.validate()?;
        Ok(envelope)
    }

    pub fn to_json(&self) -> Result<String> {
        self.validate()?;
        serde_json::to_string(self).context("secure mesh relay envelope serialization failed")
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.schema == SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
            "secure mesh relay envelope schema is unsupported"
        );
        decode_exact_base64url("delivery id", &self.delivery_id, DELIVERY_ID_BYTES)?;
        decode_exact_base64url("mailbox token", &self.mailbox_token, MAILBOX_TOKEN_BYTES)?;
        decode_bounded_base64url(
            "encrypted header",
            &self.encrypted_header,
            SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES,
            SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES,
        )?;
        ensure!(
            self.ciphertext_bucket <= JSON_SAFE_INTEGER_MAX,
            "secure mesh ciphertext bucket is outside the supported integer range"
        );
        let ciphertext_bucket = usize::try_from(self.ciphertext_bucket)
            .map_err(|_| anyhow!("secure mesh ciphertext bucket is outside platform bounds"))?;
        validate_authenticated_padding_bucket(ciphertext_bucket)?;
        decode_exact_base64url("ciphertext", &self.ciphertext, ciphertext_bucket)?;
        Ok(())
    }
}
