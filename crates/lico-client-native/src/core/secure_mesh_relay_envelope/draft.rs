//! Draft construction binds canonical routing metadata before encryption finishes.

use std::fmt;

use anyhow::{Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use rand::{RngCore, rngs::OsRng};

use super::aad::relay_outer_authenticated_data;
use super::codec::decode_exact_base64url;
use super::constants::{
    DELIVERY_ID_BYTES, MAILBOX_TOKEN_BYTES, SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES,
    SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
};
use super::envelope::SecureMeshRelayEnvelope;
use super::mailbox::SecureMeshMailboxToken;
use crate::core::secure_mesh_crypto::validate_authenticated_padding_bucket;

#[derive(Clone, Eq, PartialEq)]
pub struct SecureMeshRelayEnvelopeDraft {
    delivery_id: String,
    mailbox_token: String,
    ciphertext_bucket: u64,
}

impl SecureMeshRelayEnvelopeDraft {
    pub fn begin(mailbox_token: &SecureMeshMailboxToken, ciphertext_bucket: usize) -> Result<Self> {
        let mut delivery_id = [0u8; DELIVERY_ID_BYTES];
        OsRng.fill_bytes(&mut delivery_id);
        Self::begin_with_delivery_id(mailbox_token, ciphertext_bucket, delivery_id)
    }

    pub fn from_canonical_ids(
        mailbox_token: &str,
        delivery_id: &str,
        ciphertext_bucket: usize,
    ) -> Result<Self> {
        validate_authenticated_padding_bucket(ciphertext_bucket)?;
        decode_exact_base64url("mailbox token", mailbox_token, MAILBOX_TOKEN_BYTES)?;
        decode_exact_base64url("delivery id", delivery_id, DELIVERY_ID_BYTES)?;
        let draft = Self {
            delivery_id: delivery_id.to_string(),
            mailbox_token: mailbox_token.to_string(),
            ciphertext_bucket: u64::try_from(ciphertext_bucket)
                .map_err(|_| anyhow!("secure mesh ciphertext bucket is outside platform bounds"))?,
        };
        draft.authenticated_outer_data()?;
        Ok(draft)
    }

    pub fn authenticated_outer_data(&self) -> Result<Vec<u8>> {
        relay_outer_authenticated_data(
            &self.delivery_id,
            &self.mailbox_token,
            self.ciphertext_bucket,
        )
    }

    pub fn finish(
        self,
        encrypted_header: &[u8],
        ciphertext: &[u8],
    ) -> Result<SecureMeshRelayEnvelope> {
        ensure!(
            encrypted_header.len() == SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES,
            "secure mesh encrypted header does not match the canonical bucket"
        );
        ensure!(
            ciphertext.len()
                == usize::try_from(self.ciphertext_bucket).map_err(|_| {
                    anyhow!("secure mesh ciphertext bucket is outside platform bounds")
                })?,
            "secure mesh ciphertext does not match the canonical bucket"
        );
        let envelope = SecureMeshRelayEnvelope {
            schema: SECURE_MESH_RELAY_ENVELOPE_SCHEMA.to_string(),
            delivery_id: self.delivery_id,
            mailbox_token: self.mailbox_token,
            encrypted_header: general_purpose::URL_SAFE_NO_PAD.encode(encrypted_header),
            ciphertext_bucket: self.ciphertext_bucket,
            ciphertext: general_purpose::URL_SAFE_NO_PAD.encode(ciphertext),
        };
        envelope.validate()?;
        Ok(envelope)
    }

    pub(in crate::core::secure_mesh_relay_envelope) fn begin_with_delivery_id(
        mailbox_token: &SecureMeshMailboxToken,
        ciphertext_bucket: usize,
        delivery_id: [u8; DELIVERY_ID_BYTES],
    ) -> Result<Self> {
        validate_authenticated_padding_bucket(ciphertext_bucket)?;
        decode_exact_base64url("mailbox token", mailbox_token.as_str(), MAILBOX_TOKEN_BYTES)?;
        let draft = Self {
            delivery_id: general_purpose::URL_SAFE_NO_PAD.encode(delivery_id),
            mailbox_token: mailbox_token.value.clone(),
            ciphertext_bucket: u64::try_from(ciphertext_bucket)
                .map_err(|_| anyhow!("secure mesh ciphertext bucket is outside platform bounds"))?,
        };
        draft.authenticated_outer_data()?;
        Ok(draft)
    }
}

impl fmt::Debug for SecureMeshRelayEnvelopeDraft {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SecureMeshRelayEnvelopeDraft")
            .field("delivery_id", &"[redacted]")
            .field("mailbox_token", &"[redacted]")
            .field("ciphertext_bucket", &self.ciphertext_bucket)
            .finish()
    }
}
