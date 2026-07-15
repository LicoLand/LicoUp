use std::fmt;

use anyhow::{Context, Result, anyhow, bail, ensure};
use base64::{Engine as _, engine::general_purpose};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit, Payload as AeadPayload},
};
use hkdf::Hkdf;
use rand::{RngCore, rngs::OsRng};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::core::secure_mesh::SECURE_MESH_PROTOCOL_VERSION;

pub const SECURE_MESH_CONTENT_CIPHER_SUITE: &str =
    "licolite.secure-payload.v1.chacha20poly1305-hkdfsha256";
pub const SECURE_MESH_CONTENT_CRYPTO_STATUS: &str = "content_and_file_aead_available_authenticated_bucket_padding_available_pairwise_session_key_payload_codec_available_mls_exporter_diagnostic_only_product_group_messaging_disabled";

const CONTENT_KEY_LEN: usize = 32;
const CONTENT_NONCE_LEN: usize = 12;
const AAD_HASH_LEN: usize = 32;
const MAX_CONTENT_BYTES: usize = 16 * 1024 * 1024;
const MAX_CONTEXT_FIELD_BYTES: usize = 4096;
const MAX_CONTENT_TYPE_BYTES: usize = 255;
const AEAD_TAG_LEN: usize = 16;
pub(crate) const MIN_PADDING_BUCKET_BYTES: usize = 256;
pub(crate) const POWER_OF_TWO_PADDING_LIMIT_BYTES: usize = 64 * 1024;
pub(crate) const LARGE_PADDING_BUCKET_STEP_BYTES: usize = 64 * 1024;
pub(crate) const MAX_PADDING_BUCKET_BYTES: usize = 16 * 1024 * 1024;
const MAX_SEALED_CONTENT_BYTES: usize = MAX_PADDING_BUCKET_BYTES;
const AAD_MAGIC: &[u8] = b"LCOSM-AAD-v1";
const PLAINTEXT_MAGIC: &[u8] = b"LCOSM-PT-v1";
const PADDED_PLAINTEXT_MAGIC: &[u8] = b"LCOSM-PAD-v1";
const HEADER_MAGIC: &[u8] = b"LCOSM-HDR-v1";
const ADDITIONAL_AAD_MAGIC: &[u8] = b"LCOSM-ADDITIONAL-AAD-v1";
const HKDF_SALT_DOMAIN: &[u8] = b"licolite.secure-mesh.payload-aead.hkdf-salt.v1";
const HKDF_INFO_DOMAIN: &[u8] = b"licolite.secure-mesh.payload-aead.hkdf-info.v1";
const MAX_ADDITIONAL_AAD_BYTES: usize = 16 * 1024;
const PRIVATE_CONTEXT_AEAD_AAD: &[u8] =
    b"licolite.secure-mesh.private-context-aead.public-profile.v2";
const PRIVATE_CONTEXT_FRAME_MAGIC: &[u8] = b"LCOSM-PRIVATE-CONTEXT-FRAME-v2";
const PRIVATE_CONTEXT_HEADER_MAGIC: &[u8] = b"LCOSM-PRIVATE-CONTEXT-HEADER-v2";
const PRIVATE_CONTEXT_HKDF_SALT_DOMAIN: &[u8] =
    b"licolite.secure-mesh.private-context-aead.hkdf-salt.v2";
const PRIVATE_CONTEXT_HKDF_INFO_DOMAIN: &[u8] =
    b"licolite.secure-mesh.private-context-aead.hkdf-info.v2";

pub struct ContentKey {
    bytes: Zeroizing<Vec<u8>>,
}

impl ContentKey {
    pub fn generate() -> Self {
        let mut bytes = vec![0u8; CONTENT_KEY_LEN];
        OsRng.fill_bytes(&mut bytes);
        Self {
            bytes: Zeroizing::new(bytes),
        }
    }

    pub fn from_bytes(bytes: [u8; CONTENT_KEY_LEN]) -> Self {
        Self {
            bytes: Zeroizing::new(bytes.to_vec()),
        }
    }

    fn as_slice(&self) -> &[u8] {
        self.bytes.as_slice()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SecureMeshPayloadKind {
    Command,
    ResultPayload,
    Error,
    FileChunk,
    FileManifest,
    ServiceAction,
    TypingIndicator,
    ReadReceipt,
}

impl SecureMeshPayloadKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Command => "command",
            Self::ResultPayload => "result",
            Self::Error => "error",
            Self::FileChunk => "file_chunk",
            Self::FileManifest => "file_manifest",
            Self::ServiceAction => "service_action",
            Self::TypingIndicator => "typing_indicator",
            Self::ReadReceipt => "read_receipt",
        }
    }

    fn tag(self) -> u8 {
        match self {
            Self::Command => 1,
            Self::ResultPayload => 2,
            Self::Error => 3,
            Self::FileChunk => 4,
            Self::FileManifest => 5,
            Self::ServiceAction => 6,
            Self::TypingIndicator => 7,
            Self::ReadReceipt => 8,
        }
    }

    fn from_tag(tag: u8) -> Result<Self> {
        match tag {
            1 => Ok(Self::Command),
            2 => Ok(Self::ResultPayload),
            3 => Ok(Self::Error),
            4 => Ok(Self::FileChunk),
            5 => Ok(Self::FileManifest),
            6 => Ok(Self::ServiceAction),
            7 => Ok(Self::TypingIndicator),
            8 => Ok(Self::ReadReceipt),
            _ => bail!("secure mesh payload kind tag is unsupported"),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshContentContext {
    pub envelope_id: String,
    pub message_id: String,
    pub opaque_mailbox_id: String,
    pub sender_endpoint_id: String,
    pub recipient_endpoint_id: String,
    pub session_id: String,
    pub created_at: String,
    pub expires_at: String,
}

impl SecureMeshContentContext {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        envelope_id: impl Into<String>,
        message_id: impl Into<String>,
        opaque_mailbox_id: impl Into<String>,
        sender_endpoint_id: impl Into<String>,
        recipient_endpoint_id: impl Into<String>,
        session_id: impl Into<String>,
        created_at: impl Into<String>,
        expires_at: impl Into<String>,
    ) -> Self {
        Self {
            envelope_id: envelope_id.into(),
            message_id: message_id.into(),
            opaque_mailbox_id: opaque_mailbox_id.into(),
            sender_endpoint_id: sender_endpoint_id.into(),
            recipient_endpoint_id: recipient_endpoint_id.into(),
            session_id: session_id.into(),
            created_at: created_at.into(),
            expires_at: expires_at.into(),
        }
    }

    fn validate(&self) -> Result<()> {
        validate_context_field("envelope_id", &self.envelope_id)?;
        validate_context_field("message_id", &self.message_id)?;
        validate_context_field("opaque_mailbox_id", &self.opaque_mailbox_id)?;
        validate_context_field("sender_endpoint_id", &self.sender_endpoint_id)?;
        validate_context_field("recipient_endpoint_id", &self.recipient_endpoint_id)?;
        validate_context_field("session_id", &self.session_id)?;
        validate_context_field("created_at", &self.created_at)?;
        validate_context_field("expires_at", &self.expires_at)?;
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshPlaintext {
    pub kind: SecureMeshPayloadKind,
    pub body: Vec<u8>,
    pub content_type: Option<String>,
}

impl SecureMeshPlaintext {
    pub fn new(kind: SecureMeshPayloadKind, body: impl Into<Vec<u8>>) -> Self {
        Self {
            kind,
            body: body.into(),
            content_type: None,
        }
    }

    pub fn with_content_type(mut self, content_type: impl Into<String>) -> Self {
        self.content_type = Some(content_type.into());
        self
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpenedSecureMeshPayload {
    pub kind: SecureMeshPayloadKind,
    pub body: Vec<u8>,
    pub content_type: Option<String>,
    pub created_at: String,
    pub expires_at: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SealedSecureMeshPayload {
    pub protocol_version: String,
    pub cipher_suite: String,
    pub encrypted_header: String,
    pub ciphertext: String,
    pub ciphertext_size: usize,
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct SealedSecureMeshPrivateContextPayload {
    encrypted_header: String,
    ciphertext: String,
    ciphertext_size: usize,
}

impl SealedSecureMeshPrivateContextPayload {
    pub(crate) fn from_encoded_parts(
        encrypted_header: String,
        ciphertext: String,
        ciphertext_size: usize,
    ) -> Result<Self> {
        let sealed = Self {
            encrypted_header,
            ciphertext,
            ciphertext_size,
        };
        sealed.validate()?;
        Ok(sealed)
    }

    pub(crate) fn encrypted_header(&self) -> &str {
        &self.encrypted_header
    }

    pub(crate) fn ciphertext(&self) -> &str {
        &self.ciphertext
    }

    pub(crate) fn ciphertext_size(&self) -> usize {
        self.ciphertext_size
    }

    fn validate(&self) -> Result<()> {
        decode_private_context_header(&self.encrypted_header)?;
        validate_authenticated_padding_bucket(self.ciphertext_size)?;
        decode_canonical_base64url(
            "private-context ciphertext",
            &self.ciphertext,
            self.ciphertext_size,
            self.ciphertext_size,
        )?;
        Ok(())
    }
}

impl fmt::Debug for SealedSecureMeshPrivateContextPayload {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SealedSecureMeshPrivateContextPayload")
            .field("encrypted_header", &"[redacted]")
            .field("ciphertext", &"[redacted]")
            .field("ciphertext_size", &self.ciphertext_size)
            .finish()
    }
}

pub(crate) struct OpenedSecureMeshPrivateContextPayload {
    context: SecureMeshContentContext,
    payload: OpenedSecureMeshPayload,
}

impl OpenedSecureMeshPrivateContextPayload {
    pub(crate) fn into_parts(self) -> (SecureMeshContentContext, OpenedSecureMeshPayload) {
        (self.context, self.payload)
    }
}

pub fn seal_payload(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
) -> Result<SealedSecureMeshPayload> {
    seal_payload_with_aad_binding(key, context, plaintext, &[])
}

pub fn seal_payload_with_aad_binding(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
    additional_aad: &[u8],
) -> Result<SealedSecureMeshPayload> {
    let mut nonce = [0u8; CONTENT_NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    seal_payload_with_nonce_and_aad_binding(key, context, plaintext, nonce, additional_aad)
}

pub fn open_payload(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    sealed: &SealedSecureMeshPayload,
    expected_kind: SecureMeshPayloadKind,
) -> Result<OpenedSecureMeshPayload> {
    open_payload_with_aad_binding(key, context, sealed, expected_kind, &[])
}

pub fn open_payload_with_aad_binding(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    sealed: &SealedSecureMeshPayload,
    expected_kind: SecureMeshPayloadKind,
    additional_aad: &[u8],
) -> Result<OpenedSecureMeshPayload> {
    context.validate()?;
    validate_additional_aad(additional_aad)?;
    ensure!(
        sealed.protocol_version == SECURE_MESH_PROTOCOL_VERSION,
        "secure mesh payload protocol version is unsupported"
    );
    ensure!(
        sealed.cipher_suite == SECURE_MESH_CONTENT_CIPHER_SUITE,
        "secure mesh payload cipher suite is unsupported"
    );

    ensure!(
        sealed.ciphertext_size > 0 && sealed.ciphertext_size <= MAX_SEALED_CONTENT_BYTES,
        "secure mesh payload ciphertext size is outside bounds"
    );
    ensure!(
        sealed.ciphertext.len() <= encoded_len_limit(MAX_SEALED_CONTENT_BYTES),
        "secure mesh payload encoded ciphertext is too large"
    );
    let (nonce, aad_hash) = decode_header(&sealed.encrypted_header)?;
    let aad = build_aad_with_binding(context, expected_kind, additional_aad)?;
    ensure!(
        Sha256::digest(&aad).as_slice() == aad_hash,
        "secure mesh payload AAD hash mismatch"
    );
    let ciphertext = general_purpose::URL_SAFE_NO_PAD
        .decode(&sealed.ciphertext)
        .context("secure mesh payload ciphertext is not base64url")?;
    ensure!(
        ciphertext.len() == sealed.ciphertext_size,
        "secure mesh payload ciphertext size mismatch"
    );
    let derived_key = derive_aead_key(key, context, expected_kind, &aad)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(derived_key.as_slice()));
    let plaintext = Zeroizing::new(
        cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                AeadPayload {
                    msg: &ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| anyhow!("secure mesh payload authentication failed"))?,
    );
    let unpadded = remove_authenticated_padding(&plaintext)?;
    let opened = decode_plaintext(unpadded)?;
    ensure!(
        opened.kind == expected_kind,
        "secure mesh payload kind mismatch"
    );
    Ok(opened)
}

pub(crate) fn seal_private_context_payload(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
) -> Result<SealedSecureMeshPrivateContextPayload> {
    let mut nonce = [0u8; CONTENT_NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    seal_private_context_payload_with_nonce(key, context, plaintext, nonce)
}

pub(crate) fn open_private_context_payload(
    key: &ContentKey,
    sealed: &SealedSecureMeshPrivateContextPayload,
) -> Result<OpenedSecureMeshPrivateContextPayload> {
    sealed.validate()?;
    let nonce = decode_private_context_header(&sealed.encrypted_header)?;
    let ciphertext = decode_canonical_base64url(
        "private-context ciphertext",
        &sealed.ciphertext,
        sealed.ciphertext_size,
        sealed.ciphertext_size,
    )?;
    let derived_key = derive_private_context_aead_key(key)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(derived_key.as_slice()));
    let plaintext = Zeroizing::new(
        cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                AeadPayload {
                    msg: &ciphertext,
                    aad: PRIVATE_CONTEXT_AEAD_AAD,
                },
            )
            .map_err(|_| anyhow!("secure mesh private-context payload authentication failed"))?,
    );
    let unpadded = remove_authenticated_padding(&plaintext)?;
    decode_private_context_frame(unpadded)
}

fn seal_private_context_payload_with_nonce(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
    nonce: [u8; CONTENT_NONCE_LEN],
) -> Result<SealedSecureMeshPrivateContextPayload> {
    context.validate()?;
    validate_plaintext(plaintext)?;
    let encoded_plaintext = encode_private_context_frame(context, plaintext)?;
    let padded_plaintext = add_bucket_padding(&encoded_plaintext)?;
    let derived_key = derive_private_context_aead_key(key)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(derived_key.as_slice()));
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            AeadPayload {
                msg: padded_plaintext.as_slice(),
                aad: PRIVATE_CONTEXT_AEAD_AAD,
            },
        )
        .map_err(|_| anyhow!("secure mesh private-context payload encryption failed"))?;
    SealedSecureMeshPrivateContextPayload::from_encoded_parts(
        encode_private_context_header(&nonce),
        general_purpose::URL_SAFE_NO_PAD.encode(&ciphertext),
        ciphertext.len(),
    )
}

#[cfg(test)]
fn seal_payload_with_nonce(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
    nonce: [u8; CONTENT_NONCE_LEN],
) -> Result<SealedSecureMeshPayload> {
    seal_payload_with_nonce_and_aad_binding(key, context, plaintext, nonce, &[])
}

fn seal_payload_with_nonce_and_aad_binding(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
    nonce: [u8; CONTENT_NONCE_LEN],
    additional_aad: &[u8],
) -> Result<SealedSecureMeshPayload> {
    context.validate()?;
    validate_plaintext(plaintext)?;
    validate_additional_aad(additional_aad)?;
    let aad = build_aad_with_binding(context, plaintext.kind, additional_aad)?;
    let derived_key = derive_aead_key(key, context, plaintext.kind, &aad)?;
    let encoded_plaintext = encode_plaintext(context, plaintext)?;
    let padded_plaintext = add_bucket_padding(&encoded_plaintext)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(derived_key.as_slice()));
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            AeadPayload {
                msg: padded_plaintext.as_slice(),
                aad: &aad,
            },
        )
        .map_err(|_| anyhow!("secure mesh payload encryption failed"))?;
    let encrypted_header = encode_header(&nonce, &Sha256::digest(&aad));
    Ok(SealedSecureMeshPayload {
        protocol_version: SECURE_MESH_PROTOCOL_VERSION.to_string(),
        cipher_suite: SECURE_MESH_CONTENT_CIPHER_SUITE.to_string(),
        encrypted_header,
        ciphertext_size: ciphertext.len(),
        ciphertext: general_purpose::URL_SAFE_NO_PAD.encode(ciphertext),
    })
}

fn padding_bucket_for_ciphertext_size(unpadded_plaintext_size: usize) -> Result<usize> {
    let framed_size = PADDED_PLAINTEXT_MAGIC
        .len()
        .checked_add(4)
        .and_then(|size| size.checked_add(unpadded_plaintext_size))
        .and_then(|size| size.checked_add(AEAD_TAG_LEN))
        .ok_or_else(|| anyhow!("secure mesh padded payload length overflow"))?;
    let bucket = if framed_size <= POWER_OF_TWO_PADDING_LIMIT_BYTES {
        framed_size
            .max(MIN_PADDING_BUCKET_BYTES)
            .checked_next_power_of_two()
            .ok_or_else(|| anyhow!("secure mesh padding bucket overflow"))?
    } else {
        framed_size
            .checked_add(LARGE_PADDING_BUCKET_STEP_BYTES - 1)
            .ok_or_else(|| anyhow!("secure mesh padding bucket overflow"))?
            / LARGE_PADDING_BUCKET_STEP_BYTES
            * LARGE_PADDING_BUCKET_STEP_BYTES
    };
    ensure!(
        bucket <= MAX_PADDING_BUCKET_BYTES,
        "secure mesh payload exceeds the maximum padding bucket"
    );
    Ok(bucket)
}

pub(crate) fn validate_authenticated_padding_bucket(ciphertext_size: usize) -> Result<()> {
    ensure!(
        ciphertext_size >= MIN_PADDING_BUCKET_BYTES && ciphertext_size <= MAX_PADDING_BUCKET_BYTES,
        "secure mesh ciphertext bucket is outside bounds"
    );
    if ciphertext_size <= POWER_OF_TWO_PADDING_LIMIT_BYTES {
        ensure!(
            ciphertext_size.is_power_of_two(),
            "secure mesh ciphertext bucket is not a supported power-of-two bucket"
        );
    } else {
        ensure!(
            ciphertext_size % LARGE_PADDING_BUCKET_STEP_BYTES == 0,
            "secure mesh ciphertext bucket is not aligned to the large-payload step"
        );
    }
    Ok(())
}

fn add_bucket_padding(encoded_plaintext: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    let ciphertext_bucket = padding_bucket_for_ciphertext_size(encoded_plaintext.len())?;
    let padded_plaintext_size = ciphertext_bucket
        .checked_sub(AEAD_TAG_LEN)
        .ok_or_else(|| anyhow!("secure mesh padding bucket is invalid"))?;
    let original_len = u32::try_from(encoded_plaintext.len())
        .map_err(|_| anyhow!("secure mesh payload is too large to pad"))?;
    let mut padded = Zeroizing::new(Vec::with_capacity(padded_plaintext_size));
    padded.extend_from_slice(PADDED_PLAINTEXT_MAGIC);
    padded.extend_from_slice(&original_len.to_be_bytes());
    padded.extend_from_slice(encoded_plaintext);
    padded.resize(padded_plaintext_size, 0);
    Ok(padded)
}

fn remove_authenticated_padding(padded_plaintext: &[u8]) -> Result<&[u8]> {
    let prefix_len = PADDED_PLAINTEXT_MAGIC.len() + 4;
    ensure!(
        padded_plaintext.len() >= prefix_len,
        "secure mesh padded payload is truncated"
    );
    ensure!(
        padded_plaintext.starts_with(PADDED_PLAINTEXT_MAGIC),
        "secure mesh padded payload magic is invalid"
    );
    let original_len = u32::from_be_bytes(
        padded_plaintext[PADDED_PLAINTEXT_MAGIC.len()..prefix_len]
            .try_into()
            .map_err(|_| anyhow!("secure mesh padded payload length is invalid"))?,
    ) as usize;
    let end = prefix_len
        .checked_add(original_len)
        .ok_or_else(|| anyhow!("secure mesh padded payload length overflow"))?;
    ensure!(
        end <= padded_plaintext.len(),
        "secure mesh padded payload length is invalid"
    );
    ensure!(
        padded_plaintext[end..].iter().all(|byte| *byte == 0),
        "secure mesh padded payload bytes are invalid"
    );
    Ok(&padded_plaintext[prefix_len..end])
}

fn validate_context_field(label: &str, value: &str) -> Result<()> {
    let trimmed = value.trim();
    ensure!(
        !trimmed.is_empty(),
        "secure mesh context {label} is required"
    );
    ensure!(
        value.len() <= MAX_CONTEXT_FIELD_BYTES,
        "secure mesh context {label} is too large"
    );
    Ok(())
}

fn validate_plaintext(plaintext: &SecureMeshPlaintext) -> Result<()> {
    ensure!(
        plaintext.body.len() <= MAX_CONTENT_BYTES,
        "secure mesh payload body is too large"
    );
    if let Some(content_type) = &plaintext.content_type {
        ensure!(
            !content_type.trim().is_empty(),
            "secure mesh payload content type is empty"
        );
        ensure!(
            content_type.len() <= MAX_CONTENT_TYPE_BYTES,
            "secure mesh payload content type is too large"
        );
    }
    Ok(())
}

fn build_aad_with_binding(
    context: &SecureMeshContentContext,
    kind: SecureMeshPayloadKind,
    additional_aad: &[u8],
) -> Result<Vec<u8>> {
    validate_additional_aad(additional_aad)?;
    let mut out = Vec::new();
    out.extend_from_slice(AAD_MAGIC);
    append_len_prefixed_bytes(&mut out, SECURE_MESH_PROTOCOL_VERSION.as_bytes())?;
    append_len_prefixed_bytes(&mut out, SECURE_MESH_CONTENT_CIPHER_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.envelope_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.message_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.opaque_mailbox_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.sender_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.recipient_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, kind.as_str().as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.created_at.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.expires_at.as_bytes())?;
    if !additional_aad.is_empty() {
        out.extend_from_slice(ADDITIONAL_AAD_MAGIC);
        append_len_prefixed_bytes(&mut out, additional_aad)?;
    }
    Ok(out)
}

fn validate_additional_aad(additional_aad: &[u8]) -> Result<()> {
    ensure!(
        additional_aad.len() <= MAX_ADDITIONAL_AAD_BYTES,
        "secure mesh additional AAD is too large"
    );
    Ok(())
}

fn derive_aead_key(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    kind: SecureMeshPayloadKind,
    aad: &[u8],
) -> Result<Zeroizing<Vec<u8>>> {
    ensure!(
        key.as_slice().len() == CONTENT_KEY_LEN,
        "secure mesh content key length is invalid"
    );
    let mut salt_hasher = Sha256::new();
    salt_hasher.update(HKDF_SALT_DOMAIN);
    salt_hasher.update(aad);
    let salt = salt_hasher.finalize();
    let hkdf = Hkdf::<Sha256>::new(Some(&salt), key.as_slice());
    let mut info = Vec::new();
    info.extend_from_slice(HKDF_INFO_DOMAIN);
    append_len_prefixed_bytes(&mut info, context.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut info, kind.as_str().as_bytes())?;
    append_len_prefixed_bytes(&mut info, SECURE_MESH_CONTENT_CIPHER_SUITE.as_bytes())?;
    let mut okm = Zeroizing::new(vec![0u8; CONTENT_KEY_LEN]);
    hkdf.expand(&info, okm.as_mut_slice())
        .map_err(|_| anyhow!("secure mesh content key derivation failed"))?;
    Ok(okm)
}

fn derive_private_context_aead_key(key: &ContentKey) -> Result<Zeroizing<Vec<u8>>> {
    ensure!(
        key.as_slice().len() == CONTENT_KEY_LEN,
        "secure mesh private-context content key length is invalid"
    );
    let mut salt_hasher = Sha256::new();
    salt_hasher.update(PRIVATE_CONTEXT_HKDF_SALT_DOMAIN);
    salt_hasher.update(PRIVATE_CONTEXT_AEAD_AAD);
    let salt = salt_hasher.finalize();
    let hkdf = Hkdf::<Sha256>::new(Some(&salt), key.as_slice());
    let mut info = Vec::new();
    info.extend_from_slice(PRIVATE_CONTEXT_HKDF_INFO_DOMAIN);
    append_len_prefixed_bytes(&mut info, PRIVATE_CONTEXT_AEAD_AAD)?;
    let mut okm = Zeroizing::new(vec![0u8; CONTENT_KEY_LEN]);
    hkdf.expand(&info, okm.as_mut_slice())
        .map_err(|_| anyhow!("secure mesh private-context key derivation failed"))?;
    Ok(okm)
}

fn encode_private_context_frame(
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
) -> Result<Zeroizing<Vec<u8>>> {
    context.validate()?;
    validate_plaintext(plaintext)?;
    let mut out = Zeroizing::new(Vec::new());
    out.extend_from_slice(PRIVATE_CONTEXT_FRAME_MAGIC);
    out.push(plaintext.kind.tag());
    append_len_prefixed_bytes(&mut out, context.envelope_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.message_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.opaque_mailbox_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.sender_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.recipient_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.created_at.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.expires_at.as_bytes())?;
    match &plaintext.content_type {
        Some(content_type) => {
            out.push(1);
            append_len_prefixed_bytes(&mut out, content_type.as_bytes())?;
        }
        None => out.push(0),
    }
    append_len_prefixed_bytes(&mut out, &plaintext.body)?;
    Ok(out)
}

fn decode_private_context_frame(bytes: &[u8]) -> Result<OpenedSecureMeshPrivateContextPayload> {
    let mut reader = SliceReader::new(bytes);
    reader.expect_bytes(PRIVATE_CONTEXT_FRAME_MAGIC)?;
    let kind = SecureMeshPayloadKind::from_tag(reader.read_u8()?)?;
    let envelope_id = read_bounded_required_string(
        &mut reader,
        "private-context envelope_id",
        MAX_CONTEXT_FIELD_BYTES,
    )?;
    let message_id = read_bounded_required_string(
        &mut reader,
        "private-context message_id",
        MAX_CONTEXT_FIELD_BYTES,
    )?;
    let opaque_mailbox_id = read_bounded_required_string(
        &mut reader,
        "private-context opaque_mailbox_id",
        MAX_CONTEXT_FIELD_BYTES,
    )?;
    let sender_endpoint_id = read_bounded_required_string(
        &mut reader,
        "private-context sender_endpoint_id",
        MAX_CONTEXT_FIELD_BYTES,
    )?;
    let recipient_endpoint_id = read_bounded_required_string(
        &mut reader,
        "private-context recipient_endpoint_id",
        MAX_CONTEXT_FIELD_BYTES,
    )?;
    let session_id = read_bounded_required_string(
        &mut reader,
        "private-context session_id",
        MAX_CONTEXT_FIELD_BYTES,
    )?;
    let created_at = read_bounded_required_string(
        &mut reader,
        "private-context created_at",
        MAX_CONTEXT_FIELD_BYTES,
    )?;
    let expires_at = read_bounded_required_string(
        &mut reader,
        "private-context expires_at",
        MAX_CONTEXT_FIELD_BYTES,
    )?;
    let content_type = match reader.read_u8()? {
        0 => None,
        1 => Some(read_bounded_required_string(
            &mut reader,
            "private-context content_type",
            MAX_CONTENT_TYPE_BYTES,
        )?),
        _ => bail!("secure mesh private-context content type marker is unsupported"),
    };
    let body = reader.read_len_prefixed_bytes()?;
    ensure!(
        body.len() <= MAX_CONTENT_BYTES,
        "secure mesh private-context payload body is too large"
    );
    let body = body.to_vec();
    ensure!(
        reader.is_empty(),
        "secure mesh private-context frame has trailing bytes"
    );
    let context = SecureMeshContentContext {
        envelope_id,
        message_id,
        opaque_mailbox_id,
        sender_endpoint_id,
        recipient_endpoint_id,
        session_id,
        created_at,
        expires_at,
    };
    context.validate()?;
    let payload = OpenedSecureMeshPayload {
        kind,
        body,
        content_type,
        created_at: context.created_at.clone(),
        expires_at: context.expires_at.clone(),
    };
    Ok(OpenedSecureMeshPrivateContextPayload { context, payload })
}

fn read_bounded_required_string(
    reader: &mut SliceReader<'_>,
    label: &str,
    maximum_bytes: usize,
) -> Result<String> {
    let bytes = reader.read_len_prefixed_bytes()?;
    ensure!(
        !bytes.is_empty() && bytes.len() <= maximum_bytes,
        "secure mesh {label} is outside bounds"
    );
    let value = String::from_utf8(bytes.to_vec())
        .map_err(|_| anyhow!("secure mesh {label} is not valid UTF-8"))?;
    ensure!(!value.trim().is_empty(), "secure mesh {label} is required");
    Ok(value)
}

fn encode_plaintext(
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(PLAINTEXT_MAGIC);
    out.push(plaintext.kind.tag());
    append_len_prefixed_bytes(&mut out, context.created_at.as_bytes())?;
    append_len_prefixed_bytes(&mut out, context.expires_at.as_bytes())?;
    match &plaintext.content_type {
        Some(content_type) => {
            out.push(1);
            append_len_prefixed_bytes(&mut out, content_type.as_bytes())?;
        }
        None => out.push(0),
    }
    append_len_prefixed_bytes(&mut out, &plaintext.body)?;
    Ok(out)
}

fn decode_plaintext(bytes: &[u8]) -> Result<OpenedSecureMeshPayload> {
    let mut reader = SliceReader::new(bytes);
    reader.expect_bytes(PLAINTEXT_MAGIC)?;
    let kind = SecureMeshPayloadKind::from_tag(reader.read_u8()?)?;
    let created_at = read_string(&mut reader, "created_at")?;
    let expires_at = read_string(&mut reader, "expires_at")?;
    let content_type = match reader.read_u8()? {
        0 => None,
        1 => Some(read_string(&mut reader, "content_type")?),
        _ => bail!("secure mesh payload content type marker is unsupported"),
    };
    let body = reader.read_len_prefixed_bytes()?.to_vec();
    ensure!(
        reader.is_empty(),
        "secure mesh payload has trailing plaintext bytes"
    );
    ensure!(
        body.len() <= MAX_CONTENT_BYTES,
        "secure mesh payload body is too large"
    );
    Ok(OpenedSecureMeshPayload {
        kind,
        body,
        content_type,
        created_at,
        expires_at,
    })
}

fn read_string(reader: &mut SliceReader<'_>, label: &str) -> Result<String> {
    let bytes = reader.read_len_prefixed_bytes()?;
    String::from_utf8(bytes.to_vec())
        .map_err(|_| anyhow!("secure mesh payload {label} is not valid UTF-8"))
}

fn encode_header(nonce: &[u8; CONTENT_NONCE_LEN], aad_hash: &[u8]) -> String {
    let mut out = Vec::with_capacity(HEADER_MAGIC.len() + CONTENT_NONCE_LEN + AAD_HASH_LEN);
    out.extend_from_slice(HEADER_MAGIC);
    out.extend_from_slice(nonce);
    out.extend_from_slice(aad_hash);
    general_purpose::URL_SAFE_NO_PAD.encode(out)
}

fn encode_private_context_header(nonce: &[u8; CONTENT_NONCE_LEN]) -> String {
    let mut out =
        Vec::with_capacity(PRIVATE_CONTEXT_HEADER_MAGIC.len() + CONTENT_NONCE_LEN + AAD_HASH_LEN);
    out.extend_from_slice(PRIVATE_CONTEXT_HEADER_MAGIC);
    out.extend_from_slice(nonce);
    out.extend_from_slice(&Sha256::digest(PRIVATE_CONTEXT_AEAD_AAD));
    general_purpose::URL_SAFE_NO_PAD.encode(out)
}

fn decode_private_context_header(value: &str) -> Result<[u8; CONTENT_NONCE_LEN]> {
    let expected_size = PRIVATE_CONTEXT_HEADER_MAGIC.len() + CONTENT_NONCE_LEN + AAD_HASH_LEN;
    let bytes = decode_canonical_base64url(
        "private-context encrypted header",
        value,
        expected_size,
        expected_size,
    )?;
    ensure!(
        bytes.starts_with(PRIVATE_CONTEXT_HEADER_MAGIC),
        "secure mesh private-context encrypted header magic is invalid"
    );
    let nonce_start = PRIVATE_CONTEXT_HEADER_MAGIC.len();
    let mut nonce = [0u8; CONTENT_NONCE_LEN];
    nonce.copy_from_slice(&bytes[nonce_start..nonce_start + CONTENT_NONCE_LEN]);
    let aad_hash_start = nonce_start + CONTENT_NONCE_LEN;
    ensure!(
        &bytes[aad_hash_start..] == Sha256::digest(PRIVATE_CONTEXT_AEAD_AAD).as_slice(),
        "secure mesh private-context encrypted header profile hash mismatch"
    );
    Ok(nonce)
}

fn decode_canonical_base64url(
    label: &str,
    value: &str,
    minimum_decoded_bytes: usize,
    maximum_decoded_bytes: usize,
) -> Result<Vec<u8>> {
    ensure!(
        minimum_decoded_bytes <= maximum_decoded_bytes,
        "secure mesh base64url decoder bounds are invalid"
    );
    ensure!(
        !value.is_empty() && value.len() <= encoded_len_limit(maximum_decoded_bytes),
        "secure mesh {label} is outside encoded bounds"
    );
    let bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .with_context(|| format!("secure mesh {label} is not base64url"))?;
    ensure!(
        (minimum_decoded_bytes..=maximum_decoded_bytes).contains(&bytes.len()),
        "secure mesh {label} is outside decoded bounds"
    );
    ensure!(
        general_purpose::URL_SAFE_NO_PAD.encode(&bytes) == value,
        "secure mesh {label} is not canonical base64url"
    );
    Ok(bytes)
}

fn decode_header(value: &str) -> Result<([u8; CONTENT_NONCE_LEN], [u8; AAD_HASH_LEN])> {
    ensure!(
        value.len() <= encoded_len_limit(HEADER_MAGIC.len() + CONTENT_NONCE_LEN + AAD_HASH_LEN),
        "secure mesh payload encrypted header is too large"
    );
    let bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .context("secure mesh payload encrypted header is not base64url")?;
    ensure!(
        bytes.len() == HEADER_MAGIC.len() + CONTENT_NONCE_LEN + AAD_HASH_LEN,
        "secure mesh payload encrypted header length is invalid"
    );
    ensure!(
        bytes.starts_with(HEADER_MAGIC),
        "secure mesh payload encrypted header magic is invalid"
    );
    let mut nonce = [0u8; CONTENT_NONCE_LEN];
    let nonce_start = HEADER_MAGIC.len();
    nonce.copy_from_slice(&bytes[nonce_start..nonce_start + CONTENT_NONCE_LEN]);
    let mut aad_hash = [0u8; AAD_HASH_LEN];
    let hash_start = nonce_start + CONTENT_NONCE_LEN;
    aad_hash.copy_from_slice(&bytes[hash_start..hash_start + AAD_HASH_LEN]);
    Ok((nonce, aad_hash))
}

const fn encoded_len_limit(decoded_bytes: usize) -> usize {
    decoded_bytes.div_ceil(3) * 4
}

fn append_len_prefixed_bytes(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len = u32::try_from(value.len())
        .map_err(|_| anyhow!("secure mesh payload field is too large"))?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

struct SliceReader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> SliceReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn expect_bytes(&mut self, expected: &[u8]) -> Result<()> {
        let actual = self.read_exact(expected.len())?;
        ensure!(
            actual == expected,
            "secure mesh payload plaintext magic is invalid"
        );
        Ok(())
    }

    fn read_u8(&mut self) -> Result<u8> {
        Ok(self.read_exact(1)?[0])
    }

    fn read_len_prefixed_bytes(&mut self) -> Result<&'a [u8]> {
        let len_bytes = self.read_exact(4)?;
        let len = u32::from_be_bytes(
            len_bytes
                .try_into()
                .map_err(|_| anyhow!("secure mesh length prefix is invalid"))?,
        ) as usize;
        self.read_exact(len)
    }

    fn read_exact(&mut self, len: usize) -> Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(len)
            .ok_or_else(|| anyhow!("secure mesh payload length overflow"))?;
        ensure!(end <= self.bytes.len(), "secure mesh payload is truncated");
        let value = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(value)
    }

    fn is_empty(&self) -> bool {
        self.offset == self.bytes.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secure_mesh_content_crypto_round_trips_supported_payload_kinds() {
        let key = key_fixture(7);
        for (index, payload) in [
            SecureMeshPlaintext::new(
                SecureMeshPayloadKind::Command,
                br#"{"op":"agent.message.send"}"#,
            ),
            SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, br#"{"ok":true}"#),
            SecureMeshPlaintext::new(SecureMeshPayloadKind::Error, b"permission denied"),
            SecureMeshPlaintext::new(SecureMeshPayloadKind::FileChunk, b"file-bytes")
                .with_content_type("application/octet-stream"),
            SecureMeshPlaintext::new(
                SecureMeshPayloadKind::FileManifest,
                br#"{"name":"redacted.bin","chunks":1}"#,
            )
            .with_content_type("application/json"),
            SecureMeshPlaintext::new(
                SecureMeshPayloadKind::ServiceAction,
                br#"{"actionKind":"message_delete","messageHash":"sha256:redacted"}"#,
            )
            .with_content_type("application/json"),
            SecureMeshPlaintext::new(
                SecureMeshPayloadKind::TypingIndicator,
                br#"{"typingState":"started"}"#,
            )
            .with_content_type("application/json"),
            SecureMeshPlaintext::new(
                SecureMeshPayloadKind::ReadReceipt,
                br#"{"readUpToMessageDigest":"sha256:redacted"}"#,
            )
            .with_content_type("application/json"),
        ]
        .into_iter()
        .enumerate()
        {
            let nonce = [index as u8; CONTENT_NONCE_LEN];
            let sealed =
                seal_payload_with_nonce(&key, &context_fixture(), &payload, nonce).unwrap();
            let opened = open_payload(&key, &context_fixture(), &sealed, payload.kind).unwrap();
            assert_eq!(opened.kind, payload.kind);
            assert_eq!(opened.body, payload.body);
            assert_eq!(opened.content_type, payload.content_type);
            assert_eq!(opened.created_at, context_fixture().created_at);
            assert_eq!(opened.expires_at, context_fixture().expires_at);
        }
    }

    #[test]
    fn secure_mesh_content_crypto_rejects_aad_tamper() {
        let key = key_fixture(9);
        let context = context_fixture();
        let payload = SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, b"command");
        let sealed =
            seal_payload_with_nonce(&key, &context, &payload, [3u8; CONTENT_NONCE_LEN]).unwrap();
        let mut tampered = context.clone();
        tampered.message_id = "msg_tampered".to_string();
        let error =
            open_payload(&key, &tampered, &sealed, SecureMeshPayloadKind::Command).unwrap_err();
        assert!(error.to_string().contains("AAD hash mismatch"));
    }

    #[test]
    fn secure_mesh_content_crypto_rejects_wrong_key() {
        let context = context_fixture();
        let payload = SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, b"result");
        let sealed = seal_payload_with_nonce(
            &key_fixture(1),
            &context,
            &payload,
            [4u8; CONTENT_NONCE_LEN],
        )
        .unwrap();
        let error = open_payload(
            &key_fixture(2),
            &context,
            &sealed,
            SecureMeshPayloadKind::ResultPayload,
        )
        .unwrap_err();
        assert!(error.to_string().contains("authentication failed"));
    }

    #[test]
    fn secure_mesh_content_crypto_bucket_padding_hides_length_and_round_trips_boundaries() {
        let key = key_fixture(23);
        let context = context_fixture();
        let mut observed_buckets = Vec::new();
        for body_len in [
            0usize, 1, 31, 32, 127, 128, 511, 4095, 65_535, 65_536, 131_071,
        ] {
            let payload =
                SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, vec![0x5a; body_len]);
            let sealed = seal_payload_with_nonce(
                &key,
                &context,
                &payload,
                [body_len as u8; CONTENT_NONCE_LEN],
            )
            .unwrap();
            assert_eq!(sealed.ciphertext_size % MIN_PADDING_BUCKET_BYTES, 0);
            assert!(sealed.ciphertext_size <= MAX_PADDING_BUCKET_BYTES);
            if sealed.ciphertext_size > POWER_OF_TWO_PADDING_LIMIT_BYTES {
                assert_eq!(sealed.ciphertext_size % LARGE_PADDING_BUCKET_STEP_BYTES, 0);
            } else {
                assert!(sealed.ciphertext_size.is_power_of_two());
            }
            let opened =
                open_payload(&key, &context, &sealed, SecureMeshPayloadKind::Command).unwrap();
            assert_eq!(opened.body, payload.body);
            observed_buckets.push(sealed.ciphertext_size);
        }
        assert!(
            observed_buckets
                .windows(2)
                .all(|window| window[0] <= window[1]),
            "padding buckets must be monotonic"
        );
    }

    #[test]
    fn secure_mesh_content_crypto_rejects_invalid_padding_and_oversized_bucket() {
        let encoded = encode_plaintext(
            &context_fixture(),
            &SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, b"bounded"),
        )
        .unwrap();
        let mut padded = add_bucket_padding(&encoded).unwrap();
        let last = padded.len() - 1;
        padded[last] = 1;
        assert!(
            remove_authenticated_padding(&padded)
                .unwrap_err()
                .to_string()
                .contains("padded payload")
        );
        assert!(
            padding_bucket_for_ciphertext_size(MAX_PADDING_BUCKET_BYTES)
                .unwrap_err()
                .to_string()
                .contains("maximum padding bucket")
        );
    }

    #[test]
    fn secure_mesh_private_context_crypto_round_trips_full_context_and_payload() {
        let key = key_fixture(61);
        let context = SecureMeshContentContext::new(
            "private-envelope-canary",
            "private-message-canary",
            "private-mailbox-canary",
            "private-sender-canary",
            "private-recipient-canary",
            "private-session-canary",
            "2031-04-05T06:07:08.000Z",
            "2031-04-05T06:17:08.000Z",
        );
        let plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::ServiceAction,
            b"private-body-canary".as_slice(),
        )
        .with_content_type("application/x-private-canary");
        let sealed = seal_private_context_payload_with_nonce(
            &key,
            &context,
            &plaintext,
            [0x45; CONTENT_NONCE_LEN],
        )
        .unwrap();

        validate_authenticated_padding_bucket(sealed.ciphertext_size()).unwrap();
        assert_eq!(
            sealed.encrypted_header(),
            encode_private_context_header(&[0x45; CONTENT_NONCE_LEN])
        );

        let opened = open_private_context_payload(&key, &sealed).unwrap();
        let (opened_context, opened_payload) = opened.into_parts();
        assert_eq!(opened_context, context);
        assert_eq!(opened_payload.kind, plaintext.kind);
        assert_eq!(opened_payload.body, plaintext.body);
        assert_eq!(opened_payload.content_type, plaintext.content_type);
        assert_eq!(opened_payload.created_at, context.created_at);
        assert_eq!(opened_payload.expires_at, context.expires_at);
    }

    #[test]
    fn secure_mesh_private_context_crypto_rejects_wrong_key_and_profile_header_tamper() {
        let context = context_fixture();
        let plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, b"private-command");
        let sealed = seal_private_context_payload_with_nonce(
            &key_fixture(62),
            &context,
            &plaintext,
            [0x46; CONTENT_NONCE_LEN],
        )
        .unwrap();

        let wrong_key_error = open_private_context_payload(&key_fixture(63), &sealed)
            .err()
            .expect("wrong private-context key must fail closed");
        assert!(
            wrong_key_error
                .to_string()
                .contains("authentication failed")
        );

        let mut tampered_header = general_purpose::URL_SAFE_NO_PAD
            .decode(sealed.encrypted_header())
            .unwrap();
        let last = tampered_header.len() - 1;
        tampered_header[last] ^= 0x01;
        let tampered_error = SealedSecureMeshPrivateContextPayload::from_encoded_parts(
            general_purpose::URL_SAFE_NO_PAD.encode(tampered_header),
            sealed.ciphertext().to_string(),
            sealed.ciphertext_size(),
        )
        .unwrap_err();
        assert!(tampered_error.to_string().contains("profile hash mismatch"));
    }

    #[test]
    fn secure_mesh_private_context_crypto_authenticates_padding_and_enforces_bucket_cap() {
        let key = key_fixture(64);
        let context = context_fixture();
        let plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, b"bounded-private");
        let frame = encode_private_context_frame(&context, &plaintext).unwrap();
        let mut padded = add_bucket_padding(&frame).unwrap();
        let last = padded.len() - 1;
        padded[last] = 1;
        let nonce = [0x47; CONTENT_NONCE_LEN];
        let derived_key = derive_private_context_aead_key(&key).unwrap();
        let cipher = ChaCha20Poly1305::new(Key::from_slice(derived_key.as_slice()));
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                AeadPayload {
                    msg: padded.as_slice(),
                    aad: PRIVATE_CONTEXT_AEAD_AAD,
                },
            )
            .unwrap();
        let malformed = SealedSecureMeshPrivateContextPayload::from_encoded_parts(
            encode_private_context_header(&nonce),
            general_purpose::URL_SAFE_NO_PAD.encode(&ciphertext),
            ciphertext.len(),
        )
        .unwrap();
        let padding_error = open_private_context_payload(&key, &malformed)
            .err()
            .expect("authenticated non-zero padding must fail closed");
        assert!(padding_error.to_string().contains("padded payload bytes"));

        let valid = seal_private_context_payload_with_nonce(
            &key,
            &context,
            &plaintext,
            [0x48; CONTENT_NONCE_LEN],
        )
        .unwrap();
        let cap_error = SealedSecureMeshPrivateContextPayload::from_encoded_parts(
            valid.encrypted_header().to_string(),
            valid.ciphertext().to_string(),
            MAX_PADDING_BUCKET_BYTES + LARGE_PADDING_BUCKET_STEP_BYTES,
        )
        .unwrap_err();
        assert!(cap_error.to_string().contains("bucket is outside bounds"));

        let mut oversized_context = context_fixture();
        oversized_context.message_id = format!("{}x", " ".repeat(MAX_CONTEXT_FIELD_BYTES));
        let context_cap_error = seal_private_context_payload_with_nonce(
            &key,
            &oversized_context,
            &plaintext,
            [0x49; CONTENT_NONCE_LEN],
        )
        .unwrap_err();
        assert!(
            context_cap_error
                .to_string()
                .contains("message_id is too large")
        );
    }

    #[test]
    fn secure_mesh_content_crypto_has_stable_vectors_for_all_payload_kinds() {
        let context = context_fixture();
        #[allow(dead_code)]
        struct ContentCryptoStableVector {
            label: &'static str,
            payload: SecureMeshPlaintext,
            nonce: [u8; CONTENT_NONCE_LEN],
            encrypted_header: &'static str,
            ciphertext: &'static str,
            ciphertext_sha256: &'static str,
            ciphertext_size: usize,
        }
        let vectors = [
            ContentCryptoStableVector {
                label: "command",
                payload: SecureMeshPlaintext::new(
                    SecureMeshPayloadKind::Command,
                    br#"{"op":"client.snapshot.request"}"#,
                ),
                nonce: [11u8; CONTENT_NONCE_LEN],
                encrypted_header: "TENPU00tSERSLXYxCwsLCwsLCwsLCwsLid3eN_56h7EgoDu-Ulym2ksRx-BHS3P-AC50baYelyA",
                ciphertext: "-ar9u2Fl3ad9Jlu8ULlk-1qFuHQ1ADwOy6-NmMCE-bSMpoHNZ1QUhKDhoj7kNyrT1Ovw1vZWl2VpnKSPy8d2UJp6WdPiGeljxpjAWNopTCzcSeA-TmtzunzIGpwuW2zV21VngG1U11eFEBAMhqhp1Z6NDag4ejnvsQ",
                ciphertext_sha256: "sha256:f9cba09afc662fae4047af8a552272d2b10498cd93c78ec08d175993dee0fe9e",
                ciphertext_size: 256,
            },
            ContentCryptoStableVector {
                label: "result",
                payload: SecureMeshPlaintext::new(
                    SecureMeshPayloadKind::ResultPayload,
                    br#"{"ok":true}"#,
                ),
                nonce: [12u8; CONTENT_NONCE_LEN],
                encrypted_header: "TENPU00tSERSLXYxDAwMDAwMDAwMDAwMYPPp34_d3xprNFxTlCSpHUUnP108t7RF7We85N-56g8",
                ciphertext: "1rFim7RvXCwMI9sriRbvIbQv9WFIl4oGmJ1gna2PPRCGkoHNKBAi9mEvzhWqft-pJjoPz41mTONOrZj5fLn3t5KyBFyGk-j7KQBTJZfJdMROBU-bLr4dBS2-PHuuzYi85J_j8A",
                ciphertext_sha256: "sha256:742fb6d16cccd1406fad32f6bf1e1c3b2fefc5cd87ee0a6987822a1122608c12",
                ciphertext_size: 256,
            },
            ContentCryptoStableVector {
                label: "error",
                payload: SecureMeshPlaintext::new(
                    SecureMeshPayloadKind::Error,
                    b"permission denied",
                ),
                nonce: [13u8; CONTENT_NONCE_LEN],
                encrypted_header: "TENPU00tSERSLXYxDQ0NDQ0NDQ0NDQ0NTM3hz_h9gz7umBrAv64Q42VAuyJwbYq0MiztVSDFohM",
                ciphertext: "wQLaYL3c7UeoiE5DNukuq-Dj_piq8PtcunwOZZYWHQ8AJcYYYIk4OC_NP8lhCt5nYK2rO_G72kuhFu3O6WHAEk5xJRoabmn0MQA_0vJ4dBeSlybZanmN1WmVhVl3uOZY6CJBGBEcrMtBuA",
                ciphertext_sha256: "sha256:ab06fc5c61f70d8b81d28c63ec5596d732091a31ef8fd11e0c2aec0d31e7768d",
                ciphertext_size: 256,
            },
            ContentCryptoStableVector {
                label: "file_chunk",
                payload: SecureMeshPlaintext::new(SecureMeshPayloadKind::FileChunk, b"file-bytes")
                    .with_content_type("application/octet-stream"),
                nonce: [14u8; CONTENT_NONCE_LEN],
                encrypted_header: "TENPU00tSERSLXYxDg4ODg4ODg4ODg4OrLHXwrpVMiFxxPyvZCaUbnc6swlTk0Srs--TuX0whPw",
                ciphertext: "UzCiIRVjxbR-EeYrzWLeo1KcpsSvnu_xMcEpZkMVv0bkX8TRcYH0q5gDMYL5sx-vuEvl_qhXhf7LaDnNxptEKR_JVoAwDYS3ojf6poMeEza08p3qxDo6iysCzs5sutdPeh-R1r8JX9qjFP6PQny5sSx3AssTqCDTC5u07Ojy9Q",
                ciphertext_sha256: "sha256:bd8573b353f26c81d7eef7d977a9d4f64c31502b34d75ed7cc884917794507be",
                ciphertext_size: 256,
            },
            ContentCryptoStableVector {
                label: "file_manifest",
                payload: SecureMeshPlaintext::new(
                    SecureMeshPayloadKind::FileManifest,
                    br#"{"name":"redacted.bin","chunks":1}"#,
                )
                .with_content_type("application/json"),
                nonce: [15u8; CONTENT_NONCE_LEN],
                encrypted_header: "TENPU00tSERSLXYxDw8PDw8PDw8PDw8PpbBbxYXu43WrnvCLzac4z_01omjap3M79dpBifCudkY",
                ciphertext: "p5Fc0jS1RBf7QsOt3EFGZ8-ycm_J9XBv4-93a_JfJnR5gNVStZe6azbGF8z5HRefwEg0K3EIV4ACwtJvn-5PrJulOb-e2HV4Jdo6DeVxeK8eT5Be6h8STi3Tf9ErMeY_QSjeB7CVlmY97DqAIxuAWT7chvW0SRVCgsNUb1xdGMYHa6RfB3WpNmDmuxfbFNE",
                ciphertext_sha256: "sha256:c77c2dfb5656a364aece995e4ad82dc47864d547c3168dba57341929addd26fa",
                ciphertext_size: 256,
            },
            ContentCryptoStableVector {
                label: "service_action",
                payload: SecureMeshPlaintext::new(
                    SecureMeshPayloadKind::ServiceAction,
                    br#"{"actionKind":"message_delete","messageHash":"sha256:redacted"}"#,
                )
                .with_content_type("application/json"),
                nonce: [16u8; CONTENT_NONCE_LEN],
                encrypted_header: "TENPU00tSERSLXYxEBAQEBAQEBAQEBAQ-YksT7y5m8lw5V9wzRjWksh3jdF1fmqM8P-1BcabJrU",
                ciphertext: "lsXkoS6g6VIdBbuWcqE_cX21dd2YVLQZlZDDFc4Rp-75DeqoqPJZkIqfjub6cJjpV0ags0gAG7yyJV6LmE99C-D0kRcnR3_kPszFL1xBcoBLejNRUR3wk-NQ5oM2drUamnCHZoJyy3l0bdArmbC8kK1FnMfylJl7KncpSCvZ5k3lFMWHU0SjpssXnjfEm0oiX206_rhW_suQLrt9brF6r5WYt6Amk8JPP7CQ8g",
                ciphertext_sha256: "sha256:ed83f2fc9c2a33f92658699484dbb2e831dad2301a29fb6ed69659d84557f86e",
                ciphertext_size: 256,
            },
            ContentCryptoStableVector {
                label: "typing_indicator",
                payload: SecureMeshPlaintext::new(
                    SecureMeshPayloadKind::TypingIndicator,
                    br#"{"typingState":"started"}"#,
                )
                .with_content_type("application/json"),
                nonce: [17u8; CONTENT_NONCE_LEN],
                encrypted_header: "TENPU00tSERSLXYxERERERERERERERERvDL66dT4cAEssRk094Qb7SVC0sOCqPeOdnhkucEQ_ms",
                ciphertext: "FYxeYCydlCadYK6SlgAP6oTjlPzPmOD8PaS3e5Z76Ai0nTDk61Qt9eHNFfDO3noCbzpBw4eBvpi4pwt3bg96nodSxzptRNleo9OWj7mTovpOyRP-5AmSXBi9VVc2Jj9PiKIvUIflPwsms2i2b8gekmObUNZYoRzSq_XpCoEyZTgk5h6A3Fk",
                ciphertext_sha256: "sha256:278c4a852a80b7a3cb6580157cc3cb053fcbd1e738dde2a8663f93814e4efad3",
                ciphertext_size: 256,
            },
            ContentCryptoStableVector {
                label: "read_receipt",
                payload: SecureMeshPlaintext::new(
                    SecureMeshPayloadKind::ReadReceipt,
                    br#"{"readUpToMessageDigest":"sha256:redacted"}"#,
                )
                .with_content_type("application/json"),
                nonce: [18u8; CONTENT_NONCE_LEN],
                encrypted_header: "TENPU00tSERSLXYxEhISEhISEhISEhIS57RIYPytMnMQMMfoFaiQnHQpJ0bln5Yz-UHapPLyfmI",
                ciphertext: "XYzZ45FRETlpANS-Rwfh3-pcmvIaxXepYScebTtgIzMi9xiQTByWXc0786CCI_qbdJi3TKeGaxB0HoYWaZpZGXjAdFBCNTCIOXiezxdm-7lY8e9blANraywaO5kjzsbr9VK2sWUswWgxB4LdE9nsrBKfITfQRRv9an_nuWoTDVtx1fIQRdJyo0JDNIJPcwKab_TKcOrxw1k",
                ciphertext_sha256: "sha256:fb972e87169b043a22f7aa16fb21c01f35546178a9accb0146adbaefe1b0079e",
                ciphertext_size: 256,
            },
        ];
        assert_eq!(vectors.len(), 8);
        for vector in vectors {
            let candidate =
                seal_payload_with_nonce(&key_fixture(42), &context, &vector.payload, vector.nonce)
                    .unwrap();
            assert_eq!(
                candidate.encrypted_header, vector.encrypted_header,
                "{} encrypted header vector changed",
                vector.label
            );
            let candidate_ciphertext_sha256 = format!(
                "sha256:{}",
                Sha256::digest(candidate.ciphertext.as_bytes())
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>()
            );
            assert_eq!(
                candidate_ciphertext_sha256, vector.ciphertext_sha256,
                "{} ciphertext digest vector changed",
                vector.label
            );
            assert_eq!(
                candidate.ciphertext_size, vector.ciphertext_size,
                "{} ciphertext size vector changed",
                vector.label
            );
            let opened =
                open_payload(&key_fixture(42), &context, &candidate, vector.payload.kind).unwrap();
            assert_eq!(opened.kind, vector.payload.kind, "{} kind", vector.label);
            assert_eq!(opened.body, vector.payload.body, "{} body", vector.label);
            assert_eq!(
                opened.content_type, vector.payload.content_type,
                "{} content type",
                vector.label
            );
        }
    }

    fn context_fixture() -> SecureMeshContentContext {
        SecureMeshContentContext::new(
            "env_test",
            "msg_test",
            "mailbox_test",
            "desktop_gui:alpha",
            "mobile:beta",
            "pairwise_session_test",
            "2026-01-01T00:00:00.000Z",
            "2026-01-01T00:10:00.000Z",
        )
    }

    fn key_fixture(byte: u8) -> ContentKey {
        ContentKey::from_bytes([byte; CONTENT_KEY_LEN])
    }
}
