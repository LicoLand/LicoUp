// Canonical server-visible relay envelope shared by every protected client flow.

use std::fmt;

use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use chacha20poly1305::{
    Key, KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload as AeadPayload},
};
use hkdf::Hkdf;
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use crate::core::secure_mesh_crypto::{
    MAX_PADDING_BUCKET_BYTES, validate_authenticated_padding_bucket,
};

pub const SECURE_MESH_RELAY_ENVELOPE_SCHEMA: &str = "licolite.secure-mesh.relay-envelope.v2";
pub const SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS: u64 = 15 * 60;
pub const SECURE_MESH_MAILBOX_PREVIOUS_WINDOW_COUNT: usize = 1;
pub const SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES: usize = 4 * 1024;
pub const SECURE_MESH_RELAY_OUTER_FIELDS: [&str; 6] = [
    "schema",
    "deliveryId",
    "mailboxToken",
    "encryptedHeader",
    "ciphertextBucket",
    "ciphertext",
];

const DELIVERY_SECRET_BYTES: usize = 32;
const CHANNEL_BINDING_BYTES: usize = 32;
const DELIVERY_ID_BYTES: usize = 24;
const MAILBOX_TOKEN_BYTES: usize = 32;
const RELAY_HEADER_KEY_BYTES: usize = 32;
const RELAY_HEADER_NONCE_BYTES: usize = 24;
const RELAY_HEADER_TAG_BYTES: usize = 16;
const RELAY_HEADER_FRAME_BYTES: usize =
    SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES - RELAY_HEADER_NONCE_BYTES - RELAY_HEADER_TAG_BYTES;
const RELAY_HEADER_FRAME_MAGIC: &[u8] =
    b"LICO-SECURE-MESH-PRIVATE-RELAY-HEADER-XCHACHA20POLY1305-v3";
const RELAY_HEADER_LENGTH_BYTES: usize = 4;
const MAX_RELAY_PRIVATE_HEADER_BYTES: usize =
    RELAY_HEADER_FRAME_BYTES - RELAY_HEADER_FRAME_MAGIC.len() - RELAY_HEADER_LENGTH_BYTES;
const JSON_SAFE_INTEGER_MAX: u64 = 9_007_199_254_740_991;
const MAX_RELAY_ENVELOPE_JSON_BYTES: usize = ((MAX_PADDING_BUCKET_BYTES + 2) / 3) * 4
    + ((SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES + 2) / 3) * 4
    + 16 * 1024;
const MAILBOX_HKDF_SALT: &[u8] = b"licolite.secure-mesh.mailbox.hkdf-salt.v1";
const MAILBOX_HKDF_INFO: &[u8] = b"licolite.secure-mesh.mailbox.hkdf-info.v1";
const OUTER_AAD_MAGIC: &[u8] = b"LICO-SECURE-MESH-RELAY-OUTER-AAD-v2";

pub struct SecureMeshDeliverySecret {
    bytes: Zeroizing<[u8; DELIVERY_SECRET_BYTES]>,
}

impl SecureMeshDeliverySecret {
    pub fn generate() -> Self {
        let mut bytes = Zeroizing::new([0u8; DELIVERY_SECRET_BYTES]);
        OsRng.fill_bytes(bytes.as_mut());
        Self { bytes }
    }

    pub fn from_bytes(bytes: [u8; DELIVERY_SECRET_BYTES]) -> Self {
        Self {
            bytes: Zeroizing::new(bytes),
        }
    }

    fn as_bytes(&self) -> &[u8; DELIVERY_SECRET_BYTES] {
        &self.bytes
    }
}

impl fmt::Debug for SecureMeshDeliverySecret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecureMeshDeliverySecret([redacted])")
    }
}

#[derive(Clone, Copy, Eq, Hash, PartialEq)]
pub struct SecureMeshRelayChannelBinding([u8; CHANNEL_BINDING_BYTES]);

impl SecureMeshRelayChannelBinding {
    pub fn from_bytes(bytes: [u8; CHANNEL_BINDING_BYTES]) -> Self {
        Self(bytes)
    }

    fn as_bytes(&self) -> &[u8; CHANNEL_BINDING_BYTES] {
        &self.0
    }
}

impl fmt::Debug for SecureMeshRelayChannelBinding {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecureMeshRelayChannelBinding([redacted])")
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum SecureMeshMailboxDirection {
    PairwiseInitiatorToResponder,
    PairwiseResponderToInitiator,
    MlsGroupToMembers,
}

impl SecureMeshMailboxDirection {
    fn stable_label(self) -> &'static [u8] {
        match self {
            Self::PairwiseInitiatorToResponder => b"pairwise.initiator-to-responder.v1",
            Self::PairwiseResponderToInitiator => b"pairwise.responder-to-initiator.v1",
            Self::MlsGroupToMembers => b"mls.group-to-members.v1",
        }
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct SecureMeshMailboxToken {
    value: String,
    epoch: u64,
}

impl SecureMeshMailboxToken {
    pub fn from_base64url(value: impl Into<String>) -> Result<Self> {
        let value = value.into();
        decode_exact_base64url("mailbox token", &value, MAILBOX_TOKEN_BYTES)?;
        Ok(Self { value, epoch: 0 })
    }

    pub fn as_str(&self) -> &str {
        &self.value
    }

    #[cfg(test)]
    fn epoch(&self) -> u64 {
        self.epoch
    }
}

impl fmt::Debug for SecureMeshMailboxToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SecureMeshMailboxToken")
            .field("value", &"[redacted]")
            .field("epoch", &"[redacted]")
            .finish()
    }
}

pub struct SecureMeshMailboxSchedule {
    delivery_secret: SecureMeshDeliverySecret,
    direction: SecureMeshMailboxDirection,
    channel_binding: SecureMeshRelayChannelBinding,
}

impl SecureMeshMailboxSchedule {
    pub fn new(
        delivery_secret: SecureMeshDeliverySecret,
        direction: SecureMeshMailboxDirection,
        channel_binding: SecureMeshRelayChannelBinding,
    ) -> Self {
        Self {
            delivery_secret,
            direction,
            channel_binding,
        }
    }

    pub fn token_for_unix_seconds(&self, unix_seconds: u64) -> Result<SecureMeshMailboxToken> {
        let epoch = mailbox_epoch(unix_seconds)?;
        self.token_for_epoch(epoch)
    }

    pub fn accepted_tokens_for_unix_seconds(
        &self,
        unix_seconds: u64,
    ) -> Result<Vec<SecureMeshMailboxToken>> {
        let current_epoch = mailbox_epoch(unix_seconds)?;
        let epochs = accepted_mailbox_epochs(current_epoch)?;
        let mut tokens = Vec::with_capacity(epochs.len());
        for epoch in epochs {
            tokens.push(self.token_for_epoch(epoch)?);
        }
        Ok(tokens)
    }

    pub fn validate_token_for_unix_seconds(
        &self,
        observed_token: &str,
        unix_seconds: u64,
    ) -> Result<SecureMeshMailboxToken> {
        let observed =
            decode_exact_base64url("mailbox token", observed_token, MAILBOX_TOKEN_BYTES)?;
        let current_epoch = mailbox_epoch(unix_seconds)?;
        let mut matched_epoch = None;
        for epoch in accepted_mailbox_epochs(current_epoch)? {
            let expected = self.derive_token_bytes(epoch)?;
            if constant_time_equal(&observed, &expected) && matched_epoch.is_none() {
                matched_epoch = Some(epoch);
            }
        }
        ensure!(
            matched_epoch.is_some(),
            "secure mesh mailbox token is outside the accepted rotation window"
        );
        Ok(SecureMeshMailboxToken {
            value: observed_token.to_string(),
            epoch: matched_epoch.unwrap_or(current_epoch),
        })
    }

    pub fn validate_envelope_for_unix_seconds(
        &self,
        envelope: &SecureMeshRelayEnvelope,
        unix_seconds: u64,
    ) -> Result<SecureMeshMailboxToken> {
        envelope.validate()?;
        self.validate_token_for_unix_seconds(envelope.mailbox_token(), unix_seconds)
    }

    fn token_for_epoch(&self, epoch: u64) -> Result<SecureMeshMailboxToken> {
        let bytes = self.derive_token_bytes(epoch)?;
        Ok(SecureMeshMailboxToken {
            value: general_purpose::URL_SAFE_NO_PAD.encode(bytes),
            epoch,
        })
    }

    fn derive_token_bytes(&self, epoch: u64) -> Result<[u8; MAILBOX_TOKEN_BYTES]> {
        ensure!(
            epoch <= JSON_SAFE_INTEGER_MAX,
            "secure mesh mailbox epoch is outside the supported integer range"
        );
        let mut info = Vec::with_capacity(256);
        append_len_prefixed(&mut info, MAILBOX_HKDF_INFO)?;
        append_len_prefixed(&mut info, SECURE_MESH_RELAY_ENVELOPE_SCHEMA.as_bytes())?;
        append_len_prefixed(&mut info, self.direction.stable_label())?;
        append_len_prefixed(&mut info, self.channel_binding.as_bytes())?;
        info.extend_from_slice(&SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS.to_be_bytes());
        info.extend_from_slice(&epoch.to_be_bytes());
        let hkdf = Hkdf::<Sha256>::new(Some(MAILBOX_HKDF_SALT), self.delivery_secret.as_bytes());
        let mut output = [0u8; MAILBOX_TOKEN_BYTES];
        hkdf.expand(&info, &mut output)
            .map_err(|_| anyhow!("secure mesh mailbox HKDF expansion failed"))?;
        Ok(output)
    }
}

impl fmt::Debug for SecureMeshMailboxSchedule {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SecureMeshMailboxSchedule")
            .field("delivery_secret", &"[redacted]")
            .field("direction", &self.direction)
            .field("channel_binding", &"[redacted]")
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshRelayEnvelope {
    schema: String,
    delivery_id: String,
    mailbox_token: String,
    encrypted_header: String,
    ciphertext_bucket: u64,
    ciphertext: String,
}

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

    fn begin_with_delivery_id(
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

pub(crate) fn seal_private_relay_header(
    draft: &SecureMeshRelayEnvelopeDraft,
    header_key: &[u8],
    private_header: &[u8],
) -> Result<[u8; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES]> {
    let mut nonce = [0u8; RELAY_HEADER_NONCE_BYTES];
    OsRng.fill_bytes(&mut nonce);
    seal_private_relay_header_with_nonce(draft, header_key, private_header, nonce)
}

pub(crate) fn open_private_relay_header<'a>(
    envelope: &SecureMeshRelayEnvelope,
    candidate_header_keys: impl IntoIterator<Item = &'a [u8]>,
) -> Result<Zeroizing<Vec<u8>>> {
    let wire = envelope.decoded_encrypted_header()?;
    ensure!(
        wire.len() == SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES,
        "secure mesh private relay header wire length is invalid"
    );
    let (nonce, encrypted) = wire.split_at(RELAY_HEADER_NONCE_BYTES);
    let aad = envelope.authenticated_outer_data()?;
    let mut attempted = 0usize;
    for header_key in candidate_header_keys {
        attempted = attempted
            .checked_add(1)
            .ok_or_else(|| anyhow!("secure mesh private relay header key count overflow"))?;
        ensure!(
            attempted <= 1_024,
            "secure mesh private relay header candidate-key limit exceeded"
        );
        if header_key.len() != RELAY_HEADER_KEY_BYTES {
            continue;
        }
        let cipher = XChaCha20Poly1305::new(Key::from_slice(header_key));
        let Ok(plaintext) = cipher.decrypt(
            XNonce::from_slice(nonce),
            AeadPayload {
                msg: encrypted,
                aad: &aad,
            },
        ) else {
            continue;
        };
        return decode_private_relay_header_frame(Zeroizing::new(plaintext));
    }
    Err(anyhow!(
        "secure mesh private relay header authentication failed"
    ))
}

fn seal_private_relay_header_with_nonce(
    draft: &SecureMeshRelayEnvelopeDraft,
    header_key: &[u8],
    private_header: &[u8],
    nonce: [u8; RELAY_HEADER_NONCE_BYTES],
) -> Result<[u8; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES]> {
    ensure!(
        header_key.len() == RELAY_HEADER_KEY_BYTES,
        "secure mesh private relay header key length is invalid"
    );
    let plaintext = encode_private_relay_header_frame(private_header)?;
    let aad = draft.authenticated_outer_data()?;
    let cipher = XChaCha20Poly1305::new(Key::from_slice(header_key));
    let encrypted = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            AeadPayload {
                msg: plaintext.as_slice(),
                aad: &aad,
            },
        )
        .map_err(|_| anyhow!("secure mesh private relay header encryption failed"))?;
    ensure!(
        encrypted.len() == RELAY_HEADER_FRAME_BYTES + RELAY_HEADER_TAG_BYTES,
        "secure mesh private relay header ciphertext length is invalid"
    );
    let mut wire = [0u8; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES];
    wire[..RELAY_HEADER_NONCE_BYTES].copy_from_slice(&nonce);
    wire[RELAY_HEADER_NONCE_BYTES..].copy_from_slice(&encrypted);
    Ok(wire)
}

fn encode_private_relay_header_frame(private_header: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    ensure!(
        private_header.len() <= MAX_RELAY_PRIVATE_HEADER_BYTES,
        "secure mesh private relay header payload is too large"
    );
    let payload_length = u32::try_from(private_header.len())
        .map_err(|_| anyhow!("secure mesh private relay header payload length is invalid"))?;
    let mut frame = Zeroizing::new(vec![0u8; RELAY_HEADER_FRAME_BYTES]);
    let mut offset = 0usize;
    frame[offset..offset + RELAY_HEADER_FRAME_MAGIC.len()]
        .copy_from_slice(RELAY_HEADER_FRAME_MAGIC);
    offset += RELAY_HEADER_FRAME_MAGIC.len();
    frame[offset..offset + RELAY_HEADER_LENGTH_BYTES]
        .copy_from_slice(&payload_length.to_be_bytes());
    offset += RELAY_HEADER_LENGTH_BYTES;
    frame[offset..offset + private_header.len()].copy_from_slice(private_header);
    Ok(frame)
}

fn decode_private_relay_header_frame(frame: Zeroizing<Vec<u8>>) -> Result<Zeroizing<Vec<u8>>> {
    ensure!(
        frame.len() == RELAY_HEADER_FRAME_BYTES && frame.starts_with(RELAY_HEADER_FRAME_MAGIC),
        "secure mesh private relay header frame is invalid"
    );
    let length_start = RELAY_HEADER_FRAME_MAGIC.len();
    let payload_start = length_start + RELAY_HEADER_LENGTH_BYTES;
    let payload_length = u32::from_be_bytes(
        frame[length_start..payload_start]
            .try_into()
            .map_err(|_| anyhow!("secure mesh private relay header length is invalid"))?,
    );
    let payload_length = usize::try_from(payload_length)
        .map_err(|_| anyhow!("secure mesh private relay header length is invalid"))?;
    ensure!(
        payload_length <= MAX_RELAY_PRIVATE_HEADER_BYTES,
        "secure mesh private relay header length is outside bounds"
    );
    let payload_end = payload_start
        .checked_add(payload_length)
        .ok_or_else(|| anyhow!("secure mesh private relay header length overflow"))?;
    ensure!(
        payload_end <= frame.len() && frame[payload_end..].iter().all(|byte| *byte == 0),
        "secure mesh private relay header padding is invalid"
    );
    Ok(Zeroizing::new(frame[payload_start..payload_end].to_vec()))
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
    fn new_with_delivery_id(
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct SecureMeshRelayEnvelopeWire {
    schema: String,
    delivery_id: String,
    mailbox_token: String,
    encrypted_header: String,
    ciphertext_bucket: u64,
    ciphertext: String,
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

fn mailbox_epoch(unix_seconds: u64) -> Result<u64> {
    ensure!(
        unix_seconds <= JSON_SAFE_INTEGER_MAX,
        "secure mesh mailbox time is outside the supported integer range"
    );
    Ok(unix_seconds / SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS)
}

fn accepted_mailbox_epochs(current_epoch: u64) -> Result<Vec<u64>> {
    let mut epochs = Vec::with_capacity(1 + SECURE_MESH_MAILBOX_PREVIOUS_WINDOW_COUNT);
    epochs.push(current_epoch);
    for distance in 1..=SECURE_MESH_MAILBOX_PREVIOUS_WINDOW_COUNT {
        let distance = u64::try_from(distance)
            .map_err(|_| anyhow!("secure mesh mailbox overlap is outside bounds"))?;
        let Some(epoch) = current_epoch.checked_sub(distance) else {
            break;
        };
        epochs.push(epoch);
    }
    Ok(epochs)
}

fn append_len_prefixed(output: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let length = u16::try_from(value.len())
        .map_err(|_| anyhow!("secure mesh mailbox derivation field is too large"))?;
    output.extend_from_slice(&length.to_be_bytes());
    output.extend_from_slice(value);
    Ok(())
}

fn decode_exact_base64url(label: &str, value: &str, expected_bytes: usize) -> Result<Vec<u8>> {
    decode_bounded_base64url(label, value, expected_bytes, expected_bytes)
}

fn decode_bounded_base64url(
    label: &str,
    value: &str,
    minimum_bytes: usize,
    maximum_bytes: usize,
) -> Result<Vec<u8>> {
    ensure!(
        minimum_bytes <= maximum_bytes,
        "secure mesh relay envelope decoder bounds are invalid"
    );
    let maximum_encoded_len = base64url_encoded_len(maximum_bytes)?;
    ensure!(
        !value.is_empty() && value.len() <= maximum_encoded_len,
        "secure mesh relay envelope {label} is outside encoded bounds"
    );
    let decoded = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .with_context(|| format!("secure mesh relay envelope {label} is not base64url"))?;
    ensure!(
        (minimum_bytes..=maximum_bytes).contains(&decoded.len()),
        "secure mesh relay envelope {label} is outside decoded bounds"
    );
    ensure!(
        general_purpose::URL_SAFE_NO_PAD.encode(&decoded) == value,
        "secure mesh relay envelope {label} is not canonical base64url"
    );
    Ok(decoded)
}

fn base64url_encoded_len(input_bytes: usize) -> Result<usize> {
    let complete = input_bytes
        .checked_div(3)
        .and_then(|groups| groups.checked_mul(4))
        .ok_or_else(|| anyhow!("secure mesh relay envelope encoded length overflow"))?;
    let remainder = match input_bytes % 3 {
        0 => 0,
        1 => 2,
        2 => 3,
        _ => unreachable!(),
    };
    complete
        .checked_add(remainder)
        .ok_or_else(|| anyhow!("secure mesh relay envelope encoded length overflow"))
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len() && bool::from(left.ct_eq(right))
}

fn relay_outer_authenticated_data(
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

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use chacha20poly1305::{ChaCha20Poly1305, Nonce};
    use serde_json::{Value, json};
    use sha2::{Digest, Sha256};

    use super::*;
    use crate::core::secure_mesh_crypto::{
        LARGE_PADDING_BUCKET_STEP_BYTES, MIN_PADDING_BUCKET_BYTES, POWER_OF_TWO_PADDING_LIMIT_BYTES,
    };

    const VECTOR_TIME_SECONDS: u64 = 1_800_000_123;

    fn schedule(direction: SecureMeshMailboxDirection) -> SecureMeshMailboxSchedule {
        SecureMeshMailboxSchedule::new(
            SecureMeshDeliverySecret::from_bytes([0x11; DELIVERY_SECRET_BYTES]),
            direction,
            SecureMeshRelayChannelBinding::from_bytes([0x22; CHANNEL_BINDING_BYTES]),
        )
    }

    fn envelope_fixture() -> SecureMeshRelayEnvelope {
        let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
            .token_for_unix_seconds(VECTOR_TIME_SECONDS)
            .unwrap();
        SecureMeshRelayEnvelope::new_with_delivery_id(
            &mailbox,
            &[0x33; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES],
            &[0x44; MIN_PADDING_BUCKET_BYTES],
            [0x55; DELIVERY_ID_BYTES],
        )
        .unwrap()
    }

    #[test]
    fn canonical_relay_envelope_has_one_strict_outer_schema() {
        let envelope = envelope_fixture();
        let wire = envelope.to_json().unwrap();
        let value: Value = serde_json::from_str(&wire).unwrap();
        let keys = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>();
        assert_eq!(keys, SECURE_MESH_RELAY_OUTER_FIELDS.into_iter().collect());
        assert_eq!(
            value["schema"],
            Value::String(SECURE_MESH_RELAY_ENVELOPE_SCHEMA.to_string())
        );
        assert_eq!(value["ciphertextBucket"], MIN_PADDING_BUCKET_BYTES);
        let parsed = SecureMeshRelayEnvelope::from_json(&wire).unwrap();
        assert_eq!(parsed, envelope);

        for forbidden in [
            "messageId",
            "envelopeId",
            "sessionId",
            "senderEndpointId",
            "recipientEndpointId",
            "payloadKind",
            "contentType",
            "createdAt",
            "expiresAt",
            "cipherSuite",
            "protocolVersion",
        ] {
            assert!(!value.as_object().unwrap().contains_key(forbidden));
        }
    }

    #[test]
    fn canonical_relay_envelope_rejects_forbidden_and_unknown_outer_fields() {
        let base: Value = serde_json::from_str(&envelope_fixture().to_json().unwrap()).unwrap();
        for field in [
            "messageId",
            "envelopeId",
            "sessionId",
            "senderEndpointId",
            "recipientEndpointId",
            "payloadKind",
            "contentType",
            "createdAt",
            "expiresAt",
            "cipherSuite",
            "protocolVersion",
            "unknownCompatibilityField",
        ] {
            let mut candidate = base.clone();
            candidate[field] = json!("forbidden");
            let wire = serde_json::to_string(&candidate).unwrap();
            assert!(SecureMeshRelayEnvelope::from_json(&wire).is_err());
        }
    }

    #[test]
    fn canonical_relay_envelope_rejects_duplicate_json_keys() {
        let wire = envelope_fixture().to_json().unwrap();
        let duplicate = wire.replacen(
            '{',
            &format!("{{\"schema\":\"{}\",", SECURE_MESH_RELAY_ENVELOPE_SCHEMA),
            1,
        );
        assert!(SecureMeshRelayEnvelope::from_json(&duplicate).is_err());
    }

    #[test]
    fn canonical_relay_envelope_enforces_base64_sizes_and_bucket_match() {
        let base: Value = serde_json::from_str(&envelope_fixture().to_json().unwrap()).unwrap();

        let mut padded_delivery_id = base.clone();
        padded_delivery_id["deliveryId"] =
            json!(format!("{}=", base["deliveryId"].as_str().unwrap()));
        assert!(
            SecureMeshRelayEnvelope::from_json(
                &serde_json::to_string(&padded_delivery_id).unwrap()
            )
            .is_err()
        );

        let mut short_mailbox = base.clone();
        short_mailbox["mailboxToken"] = json!(general_purpose::URL_SAFE_NO_PAD.encode([1u8; 31]));
        assert!(
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&short_mailbox).unwrap())
                .is_err()
        );

        let mut invalid_header = base.clone();
        invalid_header["encryptedHeader"] = json!("not+base64url");
        assert!(
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&invalid_header).unwrap())
                .is_err()
        );

        let mut unsupported_bucket = base.clone();
        unsupported_bucket["ciphertextBucket"] = json!(300);
        assert!(
            SecureMeshRelayEnvelope::from_json(
                &serde_json::to_string(&unsupported_bucket).unwrap()
            )
            .is_err()
        );

        let mut short_header = base.clone();
        short_header["encryptedHeader"] = json!(general_purpose::URL_SAFE_NO_PAD.encode(vec![
                2u8;
                SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
                    - 1
            ]));
        assert!(
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&short_header).unwrap())
                .is_err()
        );

        let mut oversized_header = base.clone();
        oversized_header["encryptedHeader"] = json!(general_purpose::URL_SAFE_NO_PAD.encode(vec![
                3u8;
                SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
                    + 1
            ]));
        assert!(
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&oversized_header).unwrap())
                .is_err()
        );

        let mut invalid_ciphertext = base.clone();
        invalid_ciphertext["ciphertext"] = json!("not+base64url");
        assert!(
            SecureMeshRelayEnvelope::from_json(
                &serde_json::to_string(&invalid_ciphertext).unwrap()
            )
            .is_err()
        );

        let mut mismatched_bucket = base.clone();
        mismatched_bucket["ciphertextBucket"] = json!(MIN_PADDING_BUCKET_BYTES * 2);
        assert!(
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&mismatched_bucket).unwrap())
                .is_err()
        );

        let mut oversized_integer = base;
        oversized_integer["ciphertextBucket"] = json!(JSON_SAFE_INTEGER_MAX + 1);
        assert!(
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&oversized_integer).unwrap())
                .is_err()
        );

        let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
            .token_for_unix_seconds(VECTOR_TIME_SECONDS)
            .unwrap();
        assert!(
            SecureMeshRelayEnvelope::new(
                &mailbox,
                &[0u8; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES - 1],
                &[0u8; MIN_PADDING_BUCKET_BYTES],
            )
            .is_err()
        );
        assert!(
            SecureMeshRelayEnvelope::new(
                &mailbox,
                &[0u8; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES],
                &[0u8; MIN_PADDING_BUCKET_BYTES + 1],
            )
            .is_err()
        );
    }

    #[test]
    fn authenticated_ciphertext_bucket_validator_covers_every_protocol_bucket() {
        let mut bucket = MIN_PADDING_BUCKET_BYTES;
        while bucket <= POWER_OF_TWO_PADDING_LIMIT_BYTES {
            validate_authenticated_padding_bucket(bucket).unwrap();
            if bucket > MIN_PADDING_BUCKET_BYTES {
                assert!(validate_authenticated_padding_bucket(bucket - 1).is_err());
            }
            assert!(validate_authenticated_padding_bucket(bucket + 1).is_err());
            bucket = bucket.checked_mul(2).unwrap();
        }

        bucket = POWER_OF_TWO_PADDING_LIMIT_BYTES + LARGE_PADDING_BUCKET_STEP_BYTES;
        while bucket <= MAX_PADDING_BUCKET_BYTES {
            validate_authenticated_padding_bucket(bucket).unwrap();
            assert!(validate_authenticated_padding_bucket(bucket - 1).is_err());
            if bucket < MAX_PADDING_BUCKET_BYTES {
                assert!(validate_authenticated_padding_bucket(bucket + 1).is_err());
            }
            bucket += LARGE_PADDING_BUCKET_STEP_BYTES;
        }
        assert!(validate_authenticated_padding_bucket(MIN_PADDING_BUCKET_BYTES - 1).is_err());
        assert!(validate_authenticated_padding_bucket(MAX_PADDING_BUCKET_BYTES + 1).is_err());
    }

    #[test]
    fn mailbox_hkdf_has_stable_vector_and_rotates_without_endpoint_hashes() {
        let schedule = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder);
        let token = schedule
            .token_for_unix_seconds(VECTOR_TIME_SECONDS)
            .unwrap();
        assert_eq!(
            token.as_str(),
            "_2HSIErOouJGw302pF7oJu5fWHXnoaYvcamcpJCN3HY"
        );
        assert_eq!(
            token.epoch(),
            VECTOR_TIME_SECONDS / SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS
        );
        let next = schedule
            .token_for_unix_seconds(
                VECTOR_TIME_SECONDS + SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS,
            )
            .unwrap();
        assert_ne!(token.as_str(), next.as_str());
        let unkeyed_endpoint_hash =
            general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(b"example-endpoint-id"));
        assert_ne!(token.as_str(), unkeyed_endpoint_hash);
    }

    #[test]
    fn mailbox_accepts_only_current_and_previous_directional_windows() {
        let now = 50 * SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS + 123;
        let expected = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder);
        let current = expected.token_for_unix_seconds(now).unwrap();
        let previous = expected
            .token_for_unix_seconds(now - SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS)
            .unwrap();
        let future = expected
            .token_for_unix_seconds(now + SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS)
            .unwrap();
        let expired = expected
            .token_for_unix_seconds(now - 2 * SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS)
            .unwrap();

        assert_eq!(
            expected
                .validate_token_for_unix_seconds(current.as_str(), now)
                .unwrap()
                .epoch(),
            current.epoch()
        );
        assert_eq!(
            expected
                .validate_token_for_unix_seconds(previous.as_str(), now)
                .unwrap()
                .epoch(),
            previous.epoch()
        );
        assert!(
            expected
                .validate_token_for_unix_seconds(future.as_str(), now)
                .is_err()
        );
        assert!(
            expected
                .validate_token_for_unix_seconds(expired.as_str(), now)
                .is_err()
        );

        let wrong_direction = schedule(SecureMeshMailboxDirection::PairwiseResponderToInitiator);
        assert!(
            wrong_direction
                .validate_token_for_unix_seconds(current.as_str(), now)
                .is_err()
        );
        let wrong_channel = SecureMeshMailboxSchedule::new(
            SecureMeshDeliverySecret::from_bytes([0x11; DELIVERY_SECRET_BYTES]),
            SecureMeshMailboxDirection::PairwiseInitiatorToResponder,
            SecureMeshRelayChannelBinding::from_bytes([0x23; CHANNEL_BINDING_BYTES]),
        );
        assert!(
            wrong_channel
                .validate_token_for_unix_seconds(current.as_str(), now)
                .is_err()
        );
        let wrong_secret = SecureMeshMailboxSchedule::new(
            SecureMeshDeliverySecret::from_bytes([0x12; DELIVERY_SECRET_BYTES]),
            SecureMeshMailboxDirection::PairwiseInitiatorToResponder,
            SecureMeshRelayChannelBinding::from_bytes([0x22; CHANNEL_BINDING_BYTES]),
        );
        assert!(
            wrong_secret
                .validate_token_for_unix_seconds(current.as_str(), now)
                .is_err()
        );
        let unrelated = general_purpose::URL_SAFE_NO_PAD.encode([0x99; MAILBOX_TOKEN_BYTES]);
        assert!(
            expected
                .validate_token_for_unix_seconds(&unrelated, now)
                .is_err()
        );
        assert!(
            expected
                .token_for_unix_seconds(JSON_SAFE_INTEGER_MAX + 1)
                .is_err()
        );
    }

    #[test]
    fn mailbox_rotation_overlap_is_fixed_and_bounded() {
        let schedule = schedule(SecureMeshMailboxDirection::MlsGroupToMembers);
        for epoch in 1..128u64 {
            let now = epoch * SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS;
            let accepted = schedule.accepted_tokens_for_unix_seconds(now).unwrap();
            assert_eq!(
                accepted.len(),
                1 + SECURE_MESH_MAILBOX_PREVIOUS_WINDOW_COUNT
            );
            assert_eq!(accepted[0].epoch(), epoch);
            assert_eq!(accepted[1].epoch(), epoch - 1);
            assert_ne!(accepted[0].as_str(), accepted[1].as_str());
        }
        assert_eq!(
            schedule.accepted_tokens_for_unix_seconds(0).unwrap().len(),
            1
        );
    }

    #[test]
    fn new_envelopes_use_random_nonsemantic_delivery_ids() {
        let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
            .token_for_unix_seconds(VECTOR_TIME_SECONDS)
            .unwrap();
        let first = SecureMeshRelayEnvelope::new(
            &mailbox,
            &[0x61; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES],
            &[0x62; MIN_PADDING_BUCKET_BYTES],
        )
        .unwrap();
        let second = SecureMeshRelayEnvelope::new(
            &mailbox,
            &[0x61; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES],
            &[0x62; MIN_PADDING_BUCKET_BYTES],
        )
        .unwrap();
        assert_ne!(first.delivery_id(), second.delivery_id());
        assert_eq!(
            general_purpose::URL_SAFE_NO_PAD
                .decode(first.delivery_id())
                .unwrap()
                .len(),
            DELIVERY_ID_BYTES
        );
        assert_eq!(
            first.decoded_encrypted_header().unwrap(),
            vec![0x61; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES]
        );
        assert_eq!(
            first.decoded_ciphertext().unwrap(),
            vec![0x62; MIN_PADDING_BUCKET_BYTES]
        );
    }

    #[test]
    fn canonical_outer_aad_binds_every_mutable_routing_field() {
        let envelope = envelope_fixture();
        let baseline = envelope.authenticated_outer_data().unwrap();
        let baseline_again = envelope.authenticated_outer_data().unwrap();
        assert_eq!(baseline, baseline_again);

        let value: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
        for (field, replacement) in [
            (
                "deliveryId",
                json!(general_purpose::URL_SAFE_NO_PAD.encode([0x91u8; DELIVERY_ID_BYTES])),
            ),
            (
                "mailboxToken",
                json!(general_purpose::URL_SAFE_NO_PAD.encode([0x92u8; MAILBOX_TOKEN_BYTES])),
            ),
            ("ciphertextBucket", json!(MIN_PADDING_BUCKET_BYTES * 2)),
        ] {
            let mut changed = value.clone();
            changed[field] = replacement;
            if field == "ciphertextBucket" {
                changed["ciphertext"] = json!(general_purpose::URL_SAFE_NO_PAD.encode(vec![
                    0x44u8;
                    MIN_PADDING_BUCKET_BYTES
                        * 2
                ]));
            }
            let changed =
                SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&changed).unwrap())
                    .unwrap();
            assert_ne!(baseline, changed.authenticated_outer_data().unwrap());
        }
    }

    #[test]
    fn fixed_private_header_round_trip_authenticates_outer_fields_and_hides_canaries() {
        let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
            .token_for_unix_seconds(VECTOR_TIME_SECONDS)
            .unwrap();
        let draft = SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
            &mailbox,
            MIN_PADDING_BUCKET_BYTES,
            [0x81; DELIVERY_ID_BYTES],
        )
        .unwrap();
        let key = [0x82u8; RELAY_HEADER_KEY_BYTES];
        let private_header = b"private-endpoint-session-message-file-acp-canary";
        let nonce = [0x83; RELAY_HEADER_NONCE_BYTES];
        let encrypted_header =
            seal_private_relay_header_with_nonce(&draft, &key, private_header, nonce).unwrap();
        assert_eq!(RELAY_HEADER_NONCE_BYTES, 24);
        assert_eq!(&encrypted_header[..RELAY_HEADER_NONCE_BYTES], &nonce);
        let envelope = draft
            .finish(&encrypted_header, &[0x84u8; MIN_PADDING_BUCKET_BYTES])
            .unwrap();
        let opened =
            open_private_relay_header(&envelope, [&[0x85u8; RELAY_HEADER_KEY_BYTES][..], &key[..]])
                .unwrap();
        assert_eq!(opened.as_slice(), private_header);
        assert_eq!(
            envelope.decoded_encrypted_header().unwrap().len(),
            SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
        );
        assert!(!envelope.to_json().unwrap().contains("private-endpoint"));

        let mut changed: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
        changed["deliveryId"] =
            json!(general_purpose::URL_SAFE_NO_PAD.encode([0x86u8; DELIVERY_ID_BYTES]));
        let changed =
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&changed).unwrap()).unwrap();
        assert!(open_private_relay_header(&changed, [&key[..]]).is_err());
    }

    #[test]
    fn private_header_rejects_nonce_ciphertext_and_tag_tampering() {
        let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
            .token_for_unix_seconds(VECTOR_TIME_SECONDS)
            .unwrap();
        let draft = SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
            &mailbox,
            MIN_PADDING_BUCKET_BYTES,
            [0xa1; DELIVERY_ID_BYTES],
        )
        .unwrap();
        let key = [0xa2u8; RELAY_HEADER_KEY_BYTES];
        let encrypted_header = seal_private_relay_header_with_nonce(
            &draft,
            &key,
            b"authenticated-private-header",
            [0xa3; RELAY_HEADER_NONCE_BYTES],
        )
        .unwrap();
        let envelope = draft
            .finish(&encrypted_header, &[0xa4u8; MIN_PADDING_BUCKET_BYTES])
            .unwrap();
        let base: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();

        for offset in [
            0,
            RELAY_HEADER_NONCE_BYTES,
            SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES - 1,
        ] {
            let mut tampered = encrypted_header;
            tampered[offset] ^= 1;
            let mut wire = base.clone();
            wire["encryptedHeader"] = json!(general_purpose::URL_SAFE_NO_PAD.encode(tampered));
            let envelope =
                SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&wire).unwrap()).unwrap();
            assert!(open_private_relay_header(&envelope, [&key[..]]).is_err());
        }
    }

    #[test]
    fn private_header_rejects_pre_migration_chacha20poly1305_layout() {
        let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
            .token_for_unix_seconds(VECTOR_TIME_SECONDS)
            .unwrap();
        let draft = SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
            &mailbox,
            MIN_PADDING_BUCKET_BYTES,
            [0xb1; DELIVERY_ID_BYTES],
        )
        .unwrap();
        let key = [0xb2u8; RELAY_HEADER_KEY_BYTES];
        let old_nonce = [0xb3u8; 12];
        let old_frame_magic = b"LICO-SECURE-MESH-PRIVATE-RELAY-HEADER-v2";
        let old_frame_bytes =
            SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES - old_nonce.len() - RELAY_HEADER_TAG_BYTES;
        let private_header = b"pre-migration-private-header";
        let mut old_frame = Zeroizing::new(vec![0u8; old_frame_bytes]);
        old_frame[..old_frame_magic.len()].copy_from_slice(old_frame_magic);
        let length_start = old_frame_magic.len();
        let payload_start = length_start + RELAY_HEADER_LENGTH_BYTES;
        old_frame[length_start..payload_start]
            .copy_from_slice(&(private_header.len() as u32).to_be_bytes());
        old_frame[payload_start..payload_start + private_header.len()]
            .copy_from_slice(private_header);

        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
        let encrypted = cipher
            .encrypt(
                Nonce::from_slice(&old_nonce),
                AeadPayload {
                    msg: old_frame.as_slice(),
                    aad: &draft.authenticated_outer_data().unwrap(),
                },
            )
            .unwrap();
        assert_eq!(encrypted.len(), old_frame_bytes + RELAY_HEADER_TAG_BYTES);
        let mut old_wire = [0u8; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES];
        old_wire[..old_nonce.len()].copy_from_slice(&old_nonce);
        old_wire[old_nonce.len()..].copy_from_slice(&encrypted);

        let envelope = draft
            .finish(&old_wire, &[0xb4u8; MIN_PADDING_BUCKET_BYTES])
            .unwrap();
        assert!(open_private_relay_header(&envelope, [&key[..]]).is_err());
    }

    #[test]
    fn private_header_frame_rejects_oversize_nonzero_padding_and_wrong_keys() {
        assert!(
            encode_private_relay_header_frame(&vec![0u8; MAX_RELAY_PRIVATE_HEADER_BYTES + 1])
                .is_err()
        );
        let mut frame = encode_private_relay_header_frame(b"bounded-private-header").unwrap();
        let last = frame.len() - 1;
        frame[last] = 1;
        assert!(decode_private_relay_header_frame(frame).is_err());

        let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
            .token_for_unix_seconds(VECTOR_TIME_SECONDS)
            .unwrap();
        let draft = SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
            &mailbox,
            MIN_PADDING_BUCKET_BYTES,
            [0x91; DELIVERY_ID_BYTES],
        )
        .unwrap();
        let key = [0x92u8; RELAY_HEADER_KEY_BYTES];
        let header = seal_private_relay_header(&draft, &key, b"header").unwrap();
        let envelope = draft
            .finish(&header, &[0x93u8; MIN_PADDING_BUCKET_BYTES])
            .unwrap();
        assert!(
            open_private_relay_header(
                &envelope,
                [
                    &[0x94u8; RELAY_HEADER_KEY_BYTES][..],
                    &[0x95u8; RELAY_HEADER_KEY_BYTES - 1][..],
                ],
            )
            .is_err()
        );
    }
}
