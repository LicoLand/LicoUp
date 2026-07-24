//! Canonical outer associated data binds all mutable relay-routing fields.

use anyhow::{Result, anyhow, ensure};

use super::codec::{append_len_prefixed, decode_exact_base64url};
use super::constants::{
    DELIVERY_ID_BYTES, JSON_SAFE_INTEGER_MAX, MAILBOX_TOKEN_BYTES, OUTER_AAD_MAGIC,
    SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
};
use crate::core::secure_mesh_crypto::validate_authenticated_padding_bucket;

pub(in crate::core::secure_mesh_relay_envelope) fn relay_outer_authenticated_data(
    delivery_id: &str,
    mailbox_token: &str,
    ciphertext_bucket: u64,
) -> Result<Vec<u8>> {
    let delivery_id = decode_exact_base64url("delivery id", delivery_id, DELIVERY_ID_BYTES)?;
    let mailbox_token =
        decode_exact_base64url("mailbox token", mailbox_token, MAILBOX_TOKEN_BYTES)?;
    ensure!(
        ciphertext_bucket <= JSON_SAFE_INTEGER_MAX,
        "secure mesh ciphertext bucket is outside the supported integer range"
    );
    let bucket = usize::try_from(ciphertext_bucket)
        .map_err(|_| anyhow!("secure mesh ciphertext bucket is outside platform bounds"))?;
    validate_authenticated_padding_bucket(bucket)?;
    let mut aad = Vec::with_capacity(256);
    append_len_prefixed(&mut aad, OUTER_AAD_MAGIC)?;
    append_len_prefixed(&mut aad, SECURE_MESH_RELAY_ENVELOPE_SCHEMA.as_bytes())?;
    append_len_prefixed(&mut aad, &delivery_id)?;
    append_len_prefixed(&mut aad, &mailbox_token)?;
    aad.extend_from_slice(&ciphertext_bucket.to_be_bytes());
    Ok(aad)
}
