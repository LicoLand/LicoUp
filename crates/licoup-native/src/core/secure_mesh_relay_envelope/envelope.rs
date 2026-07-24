//! Validated opaque envelope model and stable accessors.

use std::fmt;

use anyhow::Result;
use serde::Serialize;

use super::aad::relay_outer_authenticated_data;
use super::codec::decode_exact_base64url;
#[cfg(test)]
use super::constants::DELIVERY_ID_BYTES;
use super::constants::SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES;
#[cfg(test)]
use super::draft::SecureMeshRelayEnvelopeDraft;
#[cfg(test)]
use super::mailbox::SecureMeshMailboxToken;

#[derive(Clone, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshRelayEnvelope {
    pub(in crate::core::secure_mesh_relay_envelope) schema: String,
    pub(in crate::core::secure_mesh_relay_envelope) delivery_id: String,
    pub(in crate::core::secure_mesh_relay_envelope) mailbox_token: String,
    pub(in crate::core::secure_mesh_relay_envelope) encrypted_header: String,
    pub(in crate::core::secure_mesh_relay_envelope) ciphertext_bucket: u64,
    pub(in crate::core::secure_mesh_relay_envelope) ciphertext: String,
}

impl SecureMeshRelayEnvelope {
    #[cfg(test)]
    pub(crate) fn new(
        mailbox_token: &SecureMeshMailboxToken,
        encrypted_header: &[u8],
        ciphertext: &[u8],
    ) -> Result<Self> {
        SecureMeshRelayEnvelopeDraft::begin(mailbox_token, ciphertext.len())?
            .finish(encrypted_header, ciphertext)
    }

    pub fn schema(&self) -> &str {
        &self.schema
    }

    pub fn delivery_id(&self) -> &str {
        &self.delivery_id
    }

    pub fn mailbox_token(&self) -> &str {
        &self.mailbox_token
    }

    pub fn encrypted_header(&self) -> &str {
        &self.encrypted_header
    }

    pub fn decoded_encrypted_header(&self) -> Result<Vec<u8>> {
        self.validate()?;
        decode_exact_base64url(
            "encrypted header",
            &self.encrypted_header,
            SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES,
        )
    }

    pub fn authenticated_outer_data(&self) -> Result<Vec<u8>> {
        self.validate()?;
        relay_outer_authenticated_data(
            &self.delivery_id,
            &self.mailbox_token,
            self.ciphertext_bucket,
        )
    }

    pub fn ciphertext_bucket(&self) -> usize {
        self.ciphertext_bucket as usize
    }

    pub fn ciphertext(&self) -> &str {
        &self.ciphertext
    }

    pub fn decoded_ciphertext(&self) -> Result<Vec<u8>> {
        self.validate()?;
        decode_exact_base64url("ciphertext", &self.ciphertext, self.ciphertext_bucket())
    }

    #[cfg(test)]
    pub(in crate::core::secure_mesh_relay_envelope) fn new_with_delivery_id(
        mailbox_token: &SecureMeshMailboxToken,
        encrypted_header: &[u8],
        ciphertext: &[u8],
        delivery_id: [u8; DELIVERY_ID_BYTES],
    ) -> Result<Self> {
        SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
            mailbox_token,
            ciphertext.len(),
            delivery_id,
        )?
        .finish(encrypted_header, ciphertext)
    }
}

impl fmt::Debug for SecureMeshRelayEnvelope {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SecureMeshRelayEnvelope")
            .field("schema", &self.schema)
            .field("delivery_id", &"[redacted]")
            .field("mailbox_token", &"[redacted]")
            .field("encrypted_header", &"[redacted]")
            .field("ciphertext_bucket", &self.ciphertext_bucket)
            .field("ciphertext", &"[redacted]")
            .finish()
    }
}

impl TryFrom<&str> for SecureMeshRelayEnvelope {
    type Error = anyhow::Error;

    fn try_from(value: &str) -> Result<Self> {
        Self::from_json(value)
    }
}
