use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use chacha20poly1305::{
    Key, KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload as AeadPayload},
};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fmt,
    path::{Component, Path, PathBuf},
};
use zeroize::Zeroizing;

use crate::core::secure_mesh_crypto::{
    ContentKey, SealedSecureMeshPayload, SecureMeshContentContext, SecureMeshPayloadKind,
    SecureMeshPlaintext, open_payload, seal_payload,
};

pub const SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE: &str =
    "application/licolite.secure-mesh.file.v1+json";
pub const SECURE_MESH_FILE_CHUNK_CONTENT_TYPE: &str =
    "application/licolite.secure-mesh.file.v1+json";
pub const SECURE_MESH_FILE_KEY_ENVELOPE_CONTENT_TYPE: &str =
    "application/licolite.secure-mesh.file-key-envelope.v2+json";
pub const SECURE_MESH_FILE_CRYPTO_STATUS: &str = "file_root_key_domain_separation_pairwise_device_mls_epoch_wrap_manifest_chunk_receipt_available";
pub const SECURE_MESH_FILE_KEY_SUITE: &str =
    "licolite.secure-mesh.file-key.v2.xchacha20poly1305-hkdfsha256";
const FILE_MANIFEST_MAGIC: &[u8] = b"LCOSM-FM-v1";
const FILE_CHUNK_MAGIC: &[u8] = b"LCOSM-FC-v1";
const FILE_ROOT_KEY_BYTES: usize = 32;
const FILE_KEY_WRAP_SECRET_BYTES: usize = 32;
const FILE_KEY_ENVELOPE_NONCE_BYTES: usize = 24;
const FILE_KEY_ENVELOPE_TAG_BYTES: usize = 16;
const FILE_KEY_ENVELOPE_SCHEMA: &str = "licolite.secure-mesh.file-key-envelope.v2";
const FILE_KEY_ENVELOPE_FRAME_MAGIC: &[u8] = b"LCOSM-FILE-KEY-ENVELOPE-XCHACHA20POLY1305-v2";
const FILE_KEY_ENVELOPE_MAX_JSON_BYTES: usize = 4 * 1024;
const FILE_AAD_MAGIC: &[u8] = b"LCOSM-FILE-AAD-v2";
const FILE_HKDF_SALT: &[u8] = b"licolite.secure-mesh.file.hkdf-salt.v2";
const FILE_HKDF_MANIFEST_DOMAIN: &[u8] = b"licolite.secure-mesh.file.manifest-key.v2";
const FILE_HKDF_CHUNK_DOMAIN: &[u8] = b"licolite.secure-mesh.file.chunk-key.v2";
const FILE_HKDF_CHUNK_HASH_DOMAIN: &[u8] = b"licolite.secure-mesh.file.chunk-hash-key.v2";
const FILE_HKDF_RECEIPT_DOMAIN: &[u8] = b"licolite.secure-mesh.file.receipt-key.v2";
const FILE_HKDF_KEY_WRAP_DOMAIN: &[u8] = b"licolite.secure-mesh.file.key-wrap-key.v2";
const FILE_AAD_MANIFEST_PURPOSE: &[u8] = b"manifest";
const FILE_AAD_CHUNK_PURPOSE: &[u8] = b"chunk";
const FILE_AAD_CHUNK_HASH_PURPOSE: &[u8] = b"chunk-hash";
const FILE_AAD_RECEIPT_PURPOSE: &[u8] = b"receipt";
const FILE_AAD_KEY_WRAP_PURPOSE: &[u8] = b"key-wrap";
const MAX_FILE_CRYPTO_CONTEXT_BYTES: usize = 4096;
const MAX_FILE_NAME_BYTES: usize = 255;
const MAX_MIME_BYTES: usize = 255;
const MAX_RELATIVE_PATH_BYTES: usize = 4096;
const MAX_CHUNK_BYTES: usize = 8 * 1024 * 1024;
const MAX_CHUNK_COUNT: u32 = 100_000;
const DEFAULT_MAX_QUEUED_FILE_TRANSFERS: usize = 32;
const DEFAULT_MAX_QUEUED_FILE_CIPHERTEXT_BYTES: usize = 512 * 1024 * 1024;
const DEFAULT_FILE_CONFLICT_POLICY: &str = "fail_if_exists";

pub struct FileRootKey {
    bytes: Zeroizing<[u8; FILE_ROOT_KEY_BYTES]>,
}

impl FileRootKey {
    pub fn generate() -> Self {
        let mut bytes = Zeroizing::new([0u8; FILE_ROOT_KEY_BYTES]);
        OsRng.fill_bytes(bytes.as_mut());
        Self { bytes }
    }

    pub fn from_bytes(bytes: [u8; FILE_ROOT_KEY_BYTES]) -> Self {
        Self {
            bytes: Zeroizing::new(bytes),
        }
    }

    fn as_bytes(&self) -> &[u8; FILE_ROOT_KEY_BYTES] {
        &self.bytes
    }
}

impl fmt::Debug for FileRootKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("FileRootKey([redacted])")
    }
}

pub struct FileKeyWrapSecret {
    bytes: Zeroizing<[u8; FILE_KEY_WRAP_SECRET_BYTES]>,
}

impl FileKeyWrapSecret {
    pub fn from_bytes(bytes: [u8; FILE_KEY_WRAP_SECRET_BYTES]) -> Self {
        Self {
            bytes: Zeroizing::new(bytes),
        }
    }

    fn as_bytes(&self) -> &[u8; FILE_KEY_WRAP_SECRET_BYTES] {
        &self.bytes
    }
}

impl fmt::Debug for FileKeyWrapSecret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("FileKeyWrapSecret([redacted])")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FileKeyEnvelopeMode {
    PairwiseDevice,
    MlsEpoch,
}

impl FileKeyEnvelopeMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::PairwiseDevice => "pairwise_device",
            Self::MlsEpoch => "mls_epoch",
        }
    }

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "pairwise_device" => Ok(Self::PairwiseDevice),
            "mls_epoch" => Ok(Self::MlsEpoch),
            _ => Err(anyhow!("secure mesh file key envelope mode is unsupported")),
        }
    }
}

#[derive(Clone, Eq, PartialEq)]
enum SecureMeshFileChannelBinding {
    PairwiseDevice,
    MlsEpoch { group_id: String, epoch: u64 },
}

#[derive(Clone, Eq, PartialEq)]
pub struct SecureMeshFileProtectionContext {
    content_context: SecureMeshContentContext,
    file_id: String,
    chunk_count: u32,
    file_hash: String,
    expires_at_unix_seconds: u64,
    channel: SecureMeshFileChannelBinding,
}

impl SecureMeshFileProtectionContext {
    pub fn for_pairwise_device(
        content_context: SecureMeshContentContext,
        file_id: impl Into<String>,
        chunk_count: u32,
        file_hash: impl Into<String>,
        expires_at_unix_seconds: u64,
    ) -> Result<Self> {
        let context = Self {
            content_context,
            file_id: file_id.into(),
            chunk_count,
            file_hash: file_hash.into(),
            expires_at_unix_seconds,
            channel: SecureMeshFileChannelBinding::PairwiseDevice,
        };
        context.validate()?;
        Ok(context)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn for_mls_epoch(
        content_context: SecureMeshContentContext,
        file_id: impl Into<String>,
        chunk_count: u32,
        file_hash: impl Into<String>,
        group_id: impl Into<String>,
        epoch: u64,
        expires_at_unix_seconds: u64,
    ) -> Result<Self> {
        let context = Self {
            content_context,
            file_id: file_id.into(),
            chunk_count,
            file_hash: file_hash.into(),
            expires_at_unix_seconds,
            channel: SecureMeshFileChannelBinding::MlsEpoch {
                group_id: group_id.into(),
                epoch,
            },
        };
        context.validate()?;
        Ok(context)
    }

    pub fn content_context(&self) -> &SecureMeshContentContext {
        &self.content_context
    }

    pub fn file_id(&self) -> &str {
        &self.file_id
    }

    pub fn chunk_count(&self) -> u32 {
        self.chunk_count
    }

    pub fn file_hash(&self) -> &str {
        &self.file_hash
    }

    pub fn recipient_endpoint_id(&self) -> &str {
        &self.content_context.recipient_endpoint_id
    }

    pub fn expires_at_unix_seconds(&self) -> u64 {
        self.expires_at_unix_seconds
    }

    pub fn mls_epoch(&self) -> Option<u64> {
        match self.channel {
            SecureMeshFileChannelBinding::PairwiseDevice => None,
            SecureMeshFileChannelBinding::MlsEpoch { epoch, .. } => Some(epoch),
        }
    }

    fn envelope_mode(&self) -> FileKeyEnvelopeMode {
        match self.channel {
            SecureMeshFileChannelBinding::PairwiseDevice => FileKeyEnvelopeMode::PairwiseDevice,
            SecureMeshFileChannelBinding::MlsEpoch { .. } => FileKeyEnvelopeMode::MlsEpoch,
        }
    }

    fn validate(&self) -> Result<()> {
        validate_text("file crypto file_id", &self.file_id, MAX_FILE_NAME_BYTES)?;
        ensure!(
            self.chunk_count > 0 && self.chunk_count <= MAX_CHUNK_COUNT,
            "secure mesh file crypto chunk count is outside bounds"
        );
        validate_file_hash("file hash", &self.file_hash)?;
        validate_crypto_context_text(
            "file crypto sender endpoint",
            &self.content_context.sender_endpoint_id,
            MAX_FILE_CRYPTO_CONTEXT_BYTES,
        )?;
        validate_crypto_context_text(
            "file crypto recipient endpoint",
            &self.content_context.recipient_endpoint_id,
            MAX_FILE_CRYPTO_CONTEXT_BYTES,
        )?;
        validate_crypto_context_text(
            "file crypto session",
            &self.content_context.session_id,
            MAX_FILE_CRYPTO_CONTEXT_BYTES,
        )?;
        validate_text(
            "file crypto expiry",
            &self.content_context.expires_at,
            MAX_FILE_CRYPTO_CONTEXT_BYTES,
        )?;
        ensure!(
            self.expires_at_unix_seconds > 0,
            "secure mesh file crypto expiry is invalid"
        );
        if let SecureMeshFileChannelBinding::MlsEpoch { group_id, .. } = &self.channel {
            validate_crypto_context_text(
                "file crypto MLS group",
                group_id,
                MAX_FILE_CRYPTO_CONTEXT_BYTES,
            )?;
        }
        Ok(())
    }

    fn ensure_not_expired(&self, now_unix_seconds: u64) -> Result<()> {
        ensure!(
            now_unix_seconds <= self.expires_at_unix_seconds,
            "secure mesh file key envelope is expired"
        );
        Ok(())
    }

    fn same_transfer_as(&self, other: &Self) -> bool {
        self.file_id == other.file_id
            && self.chunk_count == other.chunk_count
            && self.file_hash == other.file_hash
            && self.content_context.sender_endpoint_id == other.content_context.sender_endpoint_id
            && self.expires_at_unix_seconds == other.expires_at_unix_seconds
    }
}

impl fmt::Debug for SecureMeshFileProtectionContext {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SecureMeshFileProtectionContext")
            .field("file_id", &"[redacted]")
            .field("chunk_count", &self.chunk_count)
            .field("file_hash", &"[redacted]")
            .field("sender_endpoint_id", &"[redacted]")
            .field("recipient_endpoint_id", &"[redacted]")
            .field("channel", &self.envelope_mode())
            .field("expires_at_unix_seconds", &"[redacted]")
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct FileKeyEnvelope {
    schema: String,
    suite: String,
    mode: FileKeyEnvelopeMode,
    context_digest: String,
    epoch: Option<u64>,
    expires_at_unix_seconds: u64,
    nonce: String,
    ciphertext: String,
}

impl FileKeyEnvelope {
    pub fn to_json(&self) -> Result<String> {
        self.validate()?;
        let wire = FileKeyEnvelopeWire {
            schema: self.schema.clone(),
            suite: self.suite.clone(),
            mode: self.mode.as_str().to_string(),
            context_digest: self.context_digest.clone(),
            epoch: self.epoch,
            expires_at_unix_seconds: self.expires_at_unix_seconds,
            nonce: self.nonce.clone(),
            ciphertext: self.ciphertext.clone(),
        };
        serde_json::to_string(&wire).context("secure mesh file key envelope serialization failed")
    }

    pub fn from_json(value: &str) -> Result<Self> {
        ensure!(
            value.len() <= FILE_KEY_ENVELOPE_MAX_JSON_BYTES,
            "secure mesh file key envelope JSON is too large"
        );
        let wire: FileKeyEnvelopeWire =
            serde_json::from_str(value).context("secure mesh file key envelope JSON is invalid")?;
        let envelope = Self {
            schema: wire.schema,
            suite: wire.suite,
            mode: FileKeyEnvelopeMode::from_str(&wire.mode)?,
            context_digest: wire.context_digest,
            epoch: wire.epoch,
            expires_at_unix_seconds: wire.expires_at_unix_seconds,
            nonce: wire.nonce,
            ciphertext: wire.ciphertext,
        };
        envelope.validate()?;
        Ok(envelope)
    }

    pub fn mode(&self) -> FileKeyEnvelopeMode {
        self.mode
    }

    pub fn expires_at_unix_seconds(&self) -> u64 {
        self.expires_at_unix_seconds
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            self.schema == FILE_KEY_ENVELOPE_SCHEMA,
            "secure mesh file key envelope schema is unsupported"
        );
        ensure!(
            self.suite == SECURE_MESH_FILE_KEY_SUITE,
            "secure mesh file key envelope suite is unsupported"
        );
        decode_exact_base64url("file key context digest", &self.context_digest, 32)?;
        decode_exact_base64url("file key nonce", &self.nonce, FILE_KEY_ENVELOPE_NONCE_BYTES)?;
        decode_exact_base64url(
            "file key ciphertext",
            &self.ciphertext,
            file_key_envelope_frame_bytes() + FILE_KEY_ENVELOPE_TAG_BYTES,
        )?;
        ensure!(
            self.expires_at_unix_seconds > 0,
            "secure mesh file key envelope expiry is invalid"
        );
        match self.mode {
            FileKeyEnvelopeMode::PairwiseDevice => ensure!(
                self.epoch.is_none(),
                "secure mesh pairwise file key envelope must not carry an MLS epoch"
            ),
            FileKeyEnvelopeMode::MlsEpoch => ensure!(
                self.epoch.is_some(),
                "secure mesh MLS file key envelope epoch is required"
            ),
        }
        Ok(())
    }
}

impl fmt::Debug for FileKeyEnvelope {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("FileKeyEnvelope")
            .field("schema", &self.schema)
            .field("suite", &self.suite)
            .field("mode", &self.mode)
            .field("context_digest", &"[redacted]")
            .field("epoch", &self.epoch)
            .field("expires_at_unix_seconds", &"[redacted]")
            .field("nonce", &"[redacted]")
            .field("ciphertext", &"[redacted]")
            .finish()
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct FileKeyEnvelopeWire {
    schema: String,
    suite: String,
    mode: String,
    context_digest: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    epoch: Option<u64>,
    expires_at_unix_seconds: u64,
    nonce: String,
    ciphertext: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthenticatedSecureMeshFileReceipt {
    pub chunk_index: u32,
    pub ciphertext_hash: String,
    pub authentication_tag: String,
}

pub fn seal_file_root_key_for_pairwise_device(
    root_key: &FileRootKey,
    wrap_secret: &FileKeyWrapSecret,
    context: &SecureMeshFileProtectionContext,
) -> Result<FileKeyEnvelope> {
    ensure!(
        context.envelope_mode() == FileKeyEnvelopeMode::PairwiseDevice,
        "secure mesh pairwise file key context has the wrong channel mode"
    );
    seal_file_root_key(root_key, wrap_secret, context)
}

pub fn seal_file_root_key_for_pairwise_devices<'a>(
    root_key: &FileRootKey,
    targets: impl IntoIterator<Item = (&'a FileKeyWrapSecret, &'a SecureMeshFileProtectionContext)>,
) -> Result<Vec<FileKeyEnvelope>> {
    let mut envelopes = Vec::new();
    let mut recipients = HashSet::new();
    let mut first_context: Option<&SecureMeshFileProtectionContext> = None;
    for (wrap_secret, context) in targets {
        ensure!(
            context.envelope_mode() == FileKeyEnvelopeMode::PairwiseDevice,
            "secure mesh pairwise file key target has the wrong channel mode"
        );
        if let Some(first) = first_context {
            ensure!(
                first.same_transfer_as(context),
                "secure mesh pairwise file key targets do not describe one transfer"
            );
        } else {
            first_context = Some(context);
        }
        ensure!(
            recipients.insert(context.recipient_endpoint_id().to_string()),
            "secure mesh pairwise file key recipient is duplicated"
        );
        envelopes.push(seal_file_root_key_for_pairwise_device(
            root_key,
            wrap_secret,
            context,
        )?);
    }
    ensure!(
        !envelopes.is_empty(),
        "secure mesh pairwise file key target list is empty"
    );
    Ok(envelopes)
}

pub fn open_file_root_key_for_pairwise_device(
    envelope: &FileKeyEnvelope,
    wrap_secret: &FileKeyWrapSecret,
    context: &SecureMeshFileProtectionContext,
    now_unix_seconds: u64,
) -> Result<FileRootKey> {
    ensure!(
        context.envelope_mode() == FileKeyEnvelopeMode::PairwiseDevice,
        "secure mesh pairwise file key context has the wrong channel mode"
    );
    ensure!(
        envelope.mode == FileKeyEnvelopeMode::PairwiseDevice,
        "secure mesh pairwise file key envelope has the wrong channel mode"
    );
    open_file_root_key(envelope, wrap_secret, context, now_unix_seconds)
}

pub fn seal_file_root_key_for_mls_epoch(
    root_key: &FileRootKey,
    exporter_secret: &FileKeyWrapSecret,
    context: &SecureMeshFileProtectionContext,
) -> Result<FileKeyEnvelope> {
    ensure!(
        context.envelope_mode() == FileKeyEnvelopeMode::MlsEpoch,
        "secure mesh MLS file key context has the wrong channel mode"
    );
    seal_file_root_key(root_key, exporter_secret, context)
}

pub fn open_file_root_key_for_mls_epoch(
    envelope: &FileKeyEnvelope,
    exporter_secret: &FileKeyWrapSecret,
    context: &SecureMeshFileProtectionContext,
    current_epoch: u64,
    now_unix_seconds: u64,
) -> Result<FileRootKey> {
    ensure!(
        context.envelope_mode() == FileKeyEnvelopeMode::MlsEpoch,
        "secure mesh MLS file key context has the wrong channel mode"
    );
    ensure!(
        context.mls_epoch() == Some(current_epoch),
        "secure mesh MLS file key context is not for the current epoch"
    );
    ensure!(
        envelope.mode == FileKeyEnvelopeMode::MlsEpoch && envelope.epoch == Some(current_epoch),
        "secure mesh MLS file key envelope is not for the current epoch"
    );
    open_file_root_key(envelope, exporter_secret, context, now_unix_seconds)
}

pub fn authenticate_file_chunk_receipt(
    root_key: &FileRootKey,
    context: &SecureMeshFileProtectionContext,
    encrypted: &EncryptedSecureMeshFileChunk,
    now_unix_seconds: u64,
) -> Result<AuthenticatedSecureMeshFileReceipt> {
    context.validate()?;
    context.ensure_not_expired(now_unix_seconds)?;
    ensure_file_chunk_context(context, encrypted.chunk_index)?;
    validate_file_hash("ciphertext hash", &encrypted.ciphertext_hash)?;
    let aad = file_authenticated_data(
        context,
        FILE_AAD_RECEIPT_PURPOSE,
        Some(encrypted.chunk_index),
        &encrypted.ciphertext_hash,
    )?;
    let key = derive_file_key(
        root_key.as_bytes(),
        FILE_HKDF_RECEIPT_DOMAIN,
        aad.as_slice(),
    )?;
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key.as_ref())
        .map_err(|_| anyhow!("secure mesh file receipt MAC key is invalid"))?;
    mac.update(&aad);
    Ok(AuthenticatedSecureMeshFileReceipt {
        chunk_index: encrypted.chunk_index,
        ciphertext_hash: encrypted.ciphertext_hash.clone(),
        authentication_tag: general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()),
    })
}

pub fn verify_file_chunk_receipt(
    root_key: &FileRootKey,
    context: &SecureMeshFileProtectionContext,
    receipt: &AuthenticatedSecureMeshFileReceipt,
    now_unix_seconds: u64,
) -> Result<()> {
    context.validate()?;
    context.ensure_not_expired(now_unix_seconds)?;
    ensure_file_chunk_context(context, receipt.chunk_index)?;
    validate_file_hash("ciphertext hash", &receipt.ciphertext_hash)?;
    let tag = decode_exact_base64url(
        "file receipt authentication tag",
        &receipt.authentication_tag,
        32,
    )?;
    let aad = file_authenticated_data(
        context,
        FILE_AAD_RECEIPT_PURPOSE,
        Some(receipt.chunk_index),
        &receipt.ciphertext_hash,
    )?;
    let key = derive_file_key(
        root_key.as_bytes(),
        FILE_HKDF_RECEIPT_DOMAIN,
        aad.as_slice(),
    )?;
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key.as_ref())
        .map_err(|_| anyhow!("secure mesh file receipt MAC key is invalid"))?;
    mac.update(&aad);
    mac.verify_slice(&tag)
        .map_err(|_| anyhow!("secure mesh file receipt authentication failed"))
}

fn seal_file_root_key(
    root_key: &FileRootKey,
    wrap_secret: &FileKeyWrapSecret,
    context: &SecureMeshFileProtectionContext,
) -> Result<FileKeyEnvelope> {
    context.validate()?;
    let aad = file_authenticated_data(
        context,
        FILE_AAD_KEY_WRAP_PURPOSE,
        None,
        context.file_hash(),
    )?;
    let context_digest = file_aad_digest(&aad);
    let key = derive_file_key(
        wrap_secret.as_bytes(),
        FILE_HKDF_KEY_WRAP_DOMAIN,
        aad.as_slice(),
    )?;
    let mut frame = Zeroizing::new(Vec::with_capacity(file_key_envelope_frame_bytes()));
    frame.extend_from_slice(FILE_KEY_ENVELOPE_FRAME_MAGIC);
    frame.extend_from_slice(root_key.as_bytes());
    frame.extend_from_slice(&context_digest);
    ensure!(
        frame.len() == file_key_envelope_frame_bytes(),
        "secure mesh file key envelope frame length is invalid"
    );
    let mut nonce = [0u8; FILE_KEY_ENVELOPE_NONCE_BYTES];
    OsRng.fill_bytes(&mut nonce);
    let cipher = XChaCha20Poly1305::new(Key::from_slice(key.as_ref()));
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            AeadPayload {
                msg: frame.as_slice(),
                aad: &aad,
            },
        )
        .map_err(|_| anyhow!("secure mesh file key envelope encryption failed"))?;
    let envelope = FileKeyEnvelope {
        schema: FILE_KEY_ENVELOPE_SCHEMA.to_string(),
        suite: SECURE_MESH_FILE_KEY_SUITE.to_string(),
        mode: context.envelope_mode(),
        context_digest: general_purpose::URL_SAFE_NO_PAD.encode(context_digest),
        epoch: context.mls_epoch(),
        expires_at_unix_seconds: context.expires_at_unix_seconds,
        nonce: general_purpose::URL_SAFE_NO_PAD.encode(nonce),
        ciphertext: general_purpose::URL_SAFE_NO_PAD.encode(ciphertext),
    };
    envelope.validate()?;
    Ok(envelope)
}

fn open_file_root_key(
    envelope: &FileKeyEnvelope,
    wrap_secret: &FileKeyWrapSecret,
    context: &SecureMeshFileProtectionContext,
    now_unix_seconds: u64,
) -> Result<FileRootKey> {
    envelope.validate()?;
    context.validate()?;
    context.ensure_not_expired(now_unix_seconds)?;
    ensure!(
        envelope.mode == context.envelope_mode(),
        "secure mesh file key envelope channel context mismatch"
    );
    ensure!(
        envelope.epoch == context.mls_epoch(),
        "secure mesh file key envelope epoch context mismatch"
    );
    ensure!(
        envelope.expires_at_unix_seconds == context.expires_at_unix_seconds,
        "secure mesh file key envelope expiry context mismatch"
    );
    let aad = file_authenticated_data(
        context,
        FILE_AAD_KEY_WRAP_PURPOSE,
        None,
        context.file_hash(),
    )?;
    let context_digest = file_aad_digest(&aad);
    ensure!(
        decode_exact_base64url("file key context digest", &envelope.context_digest, 32)?
            == context_digest,
        "secure mesh file key envelope context mismatch"
    );
    let key = derive_file_key(
        wrap_secret.as_bytes(),
        FILE_HKDF_KEY_WRAP_DOMAIN,
        aad.as_slice(),
    )?;
    let nonce = decode_exact_base64url(
        "file key nonce",
        &envelope.nonce,
        FILE_KEY_ENVELOPE_NONCE_BYTES,
    )?;
    let ciphertext = decode_exact_base64url(
        "file key ciphertext",
        &envelope.ciphertext,
        file_key_envelope_frame_bytes() + FILE_KEY_ENVELOPE_TAG_BYTES,
    )?;
    let cipher = XChaCha20Poly1305::new(Key::from_slice(key.as_ref()));
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&nonce),
            AeadPayload {
                msg: &ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| anyhow!("secure mesh file key envelope authentication failed"))?;
    let plaintext = Zeroizing::new(plaintext);
    ensure!(
        plaintext.len() == file_key_envelope_frame_bytes()
            && plaintext.starts_with(FILE_KEY_ENVELOPE_FRAME_MAGIC),
        "secure mesh file key envelope frame is invalid"
    );
    let key_start = FILE_KEY_ENVELOPE_FRAME_MAGIC.len();
    let digest_start = key_start + FILE_ROOT_KEY_BYTES;
    ensure!(
        plaintext[digest_start..] == context_digest,
        "secure mesh file key envelope frame context mismatch"
    );
    let mut root_key = [0u8; FILE_ROOT_KEY_BYTES];
    root_key.copy_from_slice(&plaintext[key_start..digest_start]);
    Ok(FileRootKey::from_bytes(root_key))
}

fn file_key_envelope_frame_bytes() -> usize {
    FILE_KEY_ENVELOPE_FRAME_MAGIC.len() + FILE_ROOT_KEY_BYTES + 32
}

fn derive_file_key(
    input_key_material: &[u8],
    domain: &[u8],
    aad: &[u8],
) -> Result<Zeroizing<[u8; 32]>> {
    let mut info = Vec::with_capacity(domain.len() + aad.len() + 8);
    append_len_prefixed_bytes(&mut info, domain)?;
    append_len_prefixed_bytes(&mut info, aad)?;
    let hkdf = Hkdf::<Sha256>::new(Some(FILE_HKDF_SALT), input_key_material);
    let mut key = Zeroizing::new([0u8; 32]);
    hkdf.expand(&info, key.as_mut())
        .map_err(|_| anyhow!("secure mesh file HKDF expansion failed"))?;
    Ok(key)
}

fn file_authenticated_data(
    context: &SecureMeshFileProtectionContext,
    purpose: &[u8],
    chunk_index: Option<u32>,
    object_hash: &str,
) -> Result<Vec<u8>> {
    context.validate()?;
    validate_authenticated_digest("file AAD object hash", object_hash)?;
    if let Some(index) = chunk_index {
        ensure_file_chunk_context(context, index)?;
    }
    let mut aad = Vec::with_capacity(1024);
    append_len_prefixed_bytes(&mut aad, FILE_AAD_MAGIC)?;
    append_len_prefixed_bytes(&mut aad, SECURE_MESH_FILE_KEY_SUITE.as_bytes())?;
    append_len_prefixed_bytes(&mut aad, purpose)?;
    append_len_prefixed_bytes(&mut aad, context.file_id.as_bytes())?;
    match chunk_index {
        Some(index) => {
            aad.push(1);
            aad.extend_from_slice(&index.to_be_bytes());
        }
        None => aad.push(0),
    }
    aad.extend_from_slice(&context.chunk_count.to_be_bytes());
    append_len_prefixed_bytes(&mut aad, context.file_hash.as_bytes())?;
    append_len_prefixed_bytes(&mut aad, object_hash.as_bytes())?;
    append_len_prefixed_bytes(
        &mut aad,
        context.content_context.sender_endpoint_id.as_bytes(),
    )?;
    append_len_prefixed_bytes(
        &mut aad,
        context.content_context.recipient_endpoint_id.as_bytes(),
    )?;
    append_len_prefixed_bytes(&mut aad, context.content_context.session_id.as_bytes())?;
    match &context.channel {
        SecureMeshFileChannelBinding::PairwiseDevice => {
            append_len_prefixed_bytes(&mut aad, b"pairwise-device")?;
        }
        SecureMeshFileChannelBinding::MlsEpoch { group_id, epoch } => {
            append_len_prefixed_bytes(&mut aad, b"mls-epoch")?;
            append_len_prefixed_bytes(&mut aad, group_id.as_bytes())?;
            aad.extend_from_slice(&epoch.to_be_bytes());
        }
    }
    aad.extend_from_slice(&context.expires_at_unix_seconds.to_be_bytes());
    append_len_prefixed_bytes(&mut aad, context.content_context.envelope_id.as_bytes())?;
    append_len_prefixed_bytes(&mut aad, context.content_context.message_id.as_bytes())?;
    append_len_prefixed_bytes(
        &mut aad,
        context.content_context.opaque_mailbox_id.as_bytes(),
    )?;
    append_len_prefixed_bytes(&mut aad, context.content_context.created_at.as_bytes())?;
    append_len_prefixed_bytes(&mut aad, context.content_context.expires_at.as_bytes())?;
    Ok(aad)
}

fn file_aad_digest(aad: &[u8]) -> [u8; 32] {
    Sha256::digest(aad).into()
}

fn scoped_file_content_context(
    context: &SecureMeshFileProtectionContext,
    aad: &[u8],
) -> SecureMeshContentContext {
    let mut scoped = context.content_context.clone();
    scoped.message_id = format!(
        "file-aad-v2:{}",
        general_purpose::URL_SAFE_NO_PAD.encode(file_aad_digest(aad))
    );
    scoped
}

fn ensure_file_chunk_context(
    context: &SecureMeshFileProtectionContext,
    chunk_index: u32,
) -> Result<()> {
    ensure!(
        chunk_index < context.chunk_count,
        "secure mesh file chunk index is outside the protected manifest"
    );
    Ok(())
}

fn authenticated_file_chunk_hash(
    root_key: &FileRootKey,
    context: &SecureMeshFileProtectionContext,
    chunk_index: u32,
    chunk_bytes: &[u8],
) -> Result<String> {
    let aad = file_authenticated_data(
        context,
        FILE_AAD_CHUNK_HASH_PURPOSE,
        Some(chunk_index),
        context.file_hash(),
    )?;
    let key = derive_file_key(root_key.as_bytes(), FILE_HKDF_CHUNK_HASH_DOMAIN, &aad)?;
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key.as_ref())
        .map_err(|_| anyhow!("secure mesh file chunk hash key is invalid"))?;
    mac.update(&aad);
    mac.update(chunk_bytes);
    Ok(format!(
        "hmac-sha256:{}",
        general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
    ))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshFileManifest {
    pub file_id: String,
    pub file_name: String,
    pub mime_type: String,
    pub relative_path: String,
    pub total_size: u64,
    pub chunk_size: u32,
    pub chunk_count: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshFileChunk {
    pub file_id: String,
    pub chunk_index: u32,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EncryptedSecureMeshFileManifest {
    pub file_key_suite: String,
    pub file_aad_digest: String,
    pub sealed: SealedSecureMeshPayload,
    pub ciphertext_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EncryptedSecureMeshFileChunk {
    pub file_key_suite: String,
    pub file_aad_digest: String,
    pub file_id_hash: String,
    pub chunk_index: u32,
    pub chunk_hash: String,
    pub plaintext_size: usize,
    pub ciphertext_hash: String,
    pub sealed: SealedSecureMeshPayload,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshFileChunkReceipt {
    pub chunk_index: u32,
    pub ciphertext_hash: String,
    pub plaintext_size: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshFileTransferState {
    pub file_id: String,
    pub file_id_hash: String,
    pub total_size: u64,
    pub chunk_size: u32,
    pub chunk_count: u32,
    pub received_chunks: Vec<Option<SecureMeshFileChunkReceipt>>,
    pub acknowledged_at: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshFileResumeReport {
    pub received_chunk_count: usize,
    pub missing_chunk_indices: Vec<u32>,
    pub complete: bool,
    pub ack_required: bool,
    pub purge_local_ciphertext: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SecureMeshQueuedFileTransfer {
    recipient_endpoint_hash: String,
    state: SecureMeshFileTransferState,
    queued_ciphertext_bytes: usize,
    receive_confirmed: bool,
}

#[derive(Debug)]
pub struct SecureMeshFileTransferQueue {
    max_active_transfers: usize,
    max_ciphertext_bytes: usize,
    queued_ciphertext_bytes: usize,
    order: VecDeque<String>,
    transfers: HashMap<String, SecureMeshQueuedFileTransfer>,
}

impl Default for SecureMeshFileTransferQueue {
    fn default() -> Self {
        Self::new(
            DEFAULT_MAX_QUEUED_FILE_TRANSFERS,
            DEFAULT_MAX_QUEUED_FILE_CIPHERTEXT_BYTES,
        )
        .expect("default secure mesh file transfer queue bounds are valid")
    }
}

impl SecureMeshFileTransferQueue {
    pub fn new(max_active_transfers: usize, max_ciphertext_bytes: usize) -> Result<Self> {
        ensure!(
            max_active_transfers > 0 && max_active_transfers <= DEFAULT_MAX_QUEUED_FILE_TRANSFERS,
            "secure mesh file transfer queue active-transfer bound is invalid"
        );
        ensure!(
            max_ciphertext_bytes > 0
                && max_ciphertext_bytes <= DEFAULT_MAX_QUEUED_FILE_CIPHERTEXT_BYTES,
            "secure mesh file transfer queue ciphertext-byte bound is invalid"
        );
        Ok(Self {
            max_active_transfers,
            max_ciphertext_bytes,
            queued_ciphertext_bytes: 0,
            order: VecDeque::with_capacity(max_active_transfers),
            transfers: HashMap::with_capacity(max_active_transfers),
        })
    }

    pub fn enqueue(
        &mut self,
        manifest: &SecureMeshFileManifest,
        recipient_endpoint_id: &str,
    ) -> Result<String> {
        validate_crypto_context_text(
            "file transfer recipient endpoint",
            recipient_endpoint_id,
            MAX_FILE_CRYPTO_CONTEXT_BYTES,
        )?;
        ensure!(
            self.transfers.len() < self.max_active_transfers,
            "secure mesh file transfer queue is full"
        );
        let transfer_id = file_transfer_queue_id(manifest, recipient_endpoint_id);
        ensure!(
            !self.transfers.contains_key(&transfer_id),
            "secure mesh file transfer is already queued"
        );
        self.transfers.insert(
            transfer_id.clone(),
            SecureMeshQueuedFileTransfer {
                recipient_endpoint_hash: hash_bytes(recipient_endpoint_id.as_bytes()),
                state: start_file_transfer(manifest)?,
                queued_ciphertext_bytes: 0,
                receive_confirmed: false,
            },
        );
        self.order.push_back(transfer_id.clone());
        Ok(transfer_id)
    }

    pub fn record_chunk(
        &mut self,
        transfer_id: &str,
        encrypted: &EncryptedSecureMeshFileChunk,
    ) -> Result<SecureMeshFileResumeReport> {
        let transfer = self
            .transfers
            .get_mut(transfer_id)
            .ok_or_else(|| anyhow!("secure mesh file transfer is not queued"))?;
        let already_received = transfer
            .state
            .received_chunks
            .get(encrypted.chunk_index as usize)
            .and_then(Option::as_ref)
            .is_some();
        let ciphertext_bytes = encrypted.sealed.ciphertext_size;
        if !already_received {
            let next_total = self
                .queued_ciphertext_bytes
                .checked_add(ciphertext_bytes)
                .ok_or_else(|| anyhow!("secure mesh file transfer queue byte count overflow"))?;
            ensure!(
                next_total <= self.max_ciphertext_bytes,
                "secure mesh file transfer queue ciphertext-byte bound exceeded"
            );
        }
        let report = record_file_chunk_receipt(&mut transfer.state, encrypted)?;
        if !already_received {
            transfer.queued_ciphertext_bytes += ciphertext_bytes;
            self.queued_ciphertext_bytes += ciphertext_bytes;
        }
        Ok(report)
    }

    pub fn confirm_receive(&mut self, transfer_id: &str) -> Result<()> {
        let transfer = self
            .transfers
            .get_mut(transfer_id)
            .ok_or_else(|| anyhow!("secure mesh file transfer is not queued"))?;
        ensure!(
            file_transfer_resume_report(&transfer.state)?.complete,
            "secure mesh file transfer cannot be confirmed before complete"
        );
        transfer.receive_confirmed = true;
        Ok(())
    }

    pub fn acknowledge(
        &mut self,
        transfer_id: &str,
        acknowledged_at: impl Into<String>,
    ) -> Result<SecureMeshFileResumeReport> {
        let transfer = self
            .transfers
            .get_mut(transfer_id)
            .ok_or_else(|| anyhow!("secure mesh file transfer is not queued"))?;
        ensure!(
            transfer.receive_confirmed,
            "secure mesh file transfer requires receive confirmation before ACK"
        );
        acknowledge_file_transfer(&mut transfer.state, acknowledged_at)
    }

    pub fn purge_acknowledged(&mut self, transfer_id: &str) -> Result<usize> {
        let transfer = self
            .transfers
            .get(transfer_id)
            .ok_or_else(|| anyhow!("secure mesh file transfer is not queued"))?;
        ensure!(
            file_transfer_resume_report(&transfer.state)?.purge_local_ciphertext,
            "secure mesh file transfer cannot be purged before ACK"
        );
        let purged_bytes = transfer.queued_ciphertext_bytes;
        self.transfers.remove(transfer_id);
        self.order.retain(|queued| queued != transfer_id);
        self.queued_ciphertext_bytes = self
            .queued_ciphertext_bytes
            .checked_sub(purged_bytes)
            .ok_or_else(|| anyhow!("secure mesh file transfer queue byte count underflow"))?;
        Ok(purged_bytes)
    }

    pub fn redacted_status(&self) -> Value {
        json!({
            "activeTransferCount": self.transfers.len(),
            "queuedCiphertextBytes": self.queued_ciphertext_bytes,
            "maxActiveTransfers": self.max_active_transfers,
            "maxCiphertextBytes": self.max_ciphertext_bytes,
            "orderedTransferIds": self.order,
            "recipientEndpointHashes": self.order.iter().filter_map(|id| {
                self.transfers.get(id).map(|transfer| transfer.recipient_endpoint_hash.clone())
            }).collect::<Vec<_>>(),
            "bodyRedacted": true
        })
    }
}

pub fn seal_file_manifest(
    root_key: &FileRootKey,
    context: &SecureMeshFileProtectionContext,
    manifest: &SecureMeshFileManifest,
) -> Result<EncryptedSecureMeshFileManifest> {
    validate_manifest(manifest)?;
    context.validate()?;
    ensure!(
        context.file_id == manifest.file_id && context.chunk_count == manifest.chunk_count,
        "secure mesh file manifest protection context mismatch"
    );
    let aad = file_authenticated_data(
        context,
        FILE_AAD_MANIFEST_PURPOSE,
        None,
        context.file_hash(),
    )?;
    let derived_key = derive_file_key(root_key.as_bytes(), FILE_HKDF_MANIFEST_DOMAIN, &aad)?;
    let content_key = ContentKey::from_bytes(*derived_key);
    let scoped_context = scoped_file_content_context(context, &aad);
    let sealed = seal_payload(
        &content_key,
        &scoped_context,
        &SecureMeshPlaintext::new(
            SecureMeshPayloadKind::FileManifest,
            encode_manifest(manifest)?,
        )
        .with_content_type(SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE),
    )?;
    let ciphertext_hash = ciphertext_hash(&sealed)?;
    Ok(EncryptedSecureMeshFileManifest {
        file_key_suite: SECURE_MESH_FILE_KEY_SUITE.to_string(),
        file_aad_digest: general_purpose::URL_SAFE_NO_PAD.encode(file_aad_digest(&aad)),
        sealed,
        ciphertext_hash,
    })
}

pub fn open_file_manifest(
    root_key: &FileRootKey,
    context: &SecureMeshFileProtectionContext,
    encrypted: &EncryptedSecureMeshFileManifest,
) -> Result<SecureMeshFileManifest> {
    context.validate()?;
    ensure!(
        encrypted.file_key_suite == SECURE_MESH_FILE_KEY_SUITE,
        "secure mesh file manifest key suite is unsupported"
    );
    let aad = file_authenticated_data(
        context,
        FILE_AAD_MANIFEST_PURPOSE,
        None,
        context.file_hash(),
    )?;
    ensure!(
        decode_exact_base64url("file manifest AAD digest", &encrypted.file_aad_digest, 32,)?
            == file_aad_digest(&aad),
        "secure mesh file manifest protection context mismatch"
    );
    ensure!(
        ciphertext_hash(&encrypted.sealed)? == encrypted.ciphertext_hash,
        "secure mesh file manifest ciphertext hash mismatch"
    );
    let derived_key = derive_file_key(root_key.as_bytes(), FILE_HKDF_MANIFEST_DOMAIN, &aad)?;
    let content_key = ContentKey::from_bytes(*derived_key);
    let scoped_context = scoped_file_content_context(context, &aad);
    let opened = open_payload(
        &content_key,
        &scoped_context,
        &encrypted.sealed,
        SecureMeshPayloadKind::FileManifest,
    )?;
    ensure!(
        opened.content_type.as_deref() == Some(SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE),
        "secure mesh file manifest content type mismatch"
    );
    let manifest = decode_manifest(&opened.body)?;
    ensure!(
        manifest.file_id == context.file_id && manifest.chunk_count == context.chunk_count,
        "secure mesh file manifest protection context mismatch"
    );
    Ok(manifest)
}

pub fn file_manifest_delivery_json(encrypted: &EncryptedSecureMeshFileManifest) -> Value {
    json!({
        "kind": "file_manifest",
        "contentType": SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE,
        "fileKeySuite": encrypted.file_key_suite,
        "fileAadDigest": encrypted.file_aad_digest,
        "ciphertextHash": encrypted.ciphertext_hash,
        "sealed": sealed_payload_json(&encrypted.sealed),
        "metadataEncrypted": true,
        "bodyRedacted": true
    })
}

pub fn seal_file_chunk(
    root_key: &FileRootKey,
    context: &SecureMeshFileProtectionContext,
    chunk: &SecureMeshFileChunk,
) -> Result<EncryptedSecureMeshFileChunk> {
    validate_chunk(chunk)?;
    context.validate()?;
    ensure!(
        context.file_id == chunk.file_id,
        "secure mesh file chunk protection context mismatch"
    );
    ensure_file_chunk_context(context, chunk.chunk_index)?;
    let chunk_hash = authenticated_file_chunk_hash(
        root_key,
        context,
        chunk.chunk_index,
        chunk.bytes.as_slice(),
    )?;
    let aad = file_authenticated_data(
        context,
        FILE_AAD_CHUNK_PURPOSE,
        Some(chunk.chunk_index),
        &chunk_hash,
    )?;
    let derived_key = derive_file_key(root_key.as_bytes(), FILE_HKDF_CHUNK_DOMAIN, &aad)?;
    let content_key = ContentKey::from_bytes(*derived_key);
    let scoped_context = scoped_file_content_context(context, &aad);
    let sealed = seal_payload(
        &content_key,
        &scoped_context,
        &SecureMeshPlaintext::new(SecureMeshPayloadKind::FileChunk, encode_chunk(chunk)?)
            .with_content_type(SECURE_MESH_FILE_CHUNK_CONTENT_TYPE),
    )?;
    Ok(EncryptedSecureMeshFileChunk {
        file_key_suite: SECURE_MESH_FILE_KEY_SUITE.to_string(),
        file_aad_digest: general_purpose::URL_SAFE_NO_PAD.encode(file_aad_digest(&aad)),
        file_id_hash: hash_bytes(chunk.file_id.as_bytes()),
        chunk_index: chunk.chunk_index,
        chunk_hash,
        plaintext_size: chunk.bytes.len(),
        ciphertext_hash: ciphertext_hash(&sealed)?,
        sealed,
    })
}

pub fn open_file_chunk(
    root_key: &FileRootKey,
    context: &SecureMeshFileProtectionContext,
    encrypted: &EncryptedSecureMeshFileChunk,
) -> Result<SecureMeshFileChunk> {
    context.validate()?;
    ensure!(
        encrypted.file_key_suite == SECURE_MESH_FILE_KEY_SUITE,
        "secure mesh file chunk key suite is unsupported"
    );
    ensure_file_chunk_context(context, encrypted.chunk_index)?;
    validate_file_chunk_hash("file chunk hash", &encrypted.chunk_hash)?;
    ensure!(
        hash_bytes(context.file_id.as_bytes()) == encrypted.file_id_hash,
        "secure mesh file chunk protection context mismatch"
    );
    let aad = file_authenticated_data(
        context,
        FILE_AAD_CHUNK_PURPOSE,
        Some(encrypted.chunk_index),
        &encrypted.chunk_hash,
    )?;
    ensure!(
        decode_exact_base64url("file chunk AAD digest", &encrypted.file_aad_digest, 32,)?
            == file_aad_digest(&aad),
        "secure mesh file chunk protection context mismatch"
    );
    ensure!(
        ciphertext_hash(&encrypted.sealed)? == encrypted.ciphertext_hash,
        "secure mesh file chunk ciphertext hash mismatch"
    );
    let derived_key = derive_file_key(root_key.as_bytes(), FILE_HKDF_CHUNK_DOMAIN, &aad)?;
    let content_key = ContentKey::from_bytes(*derived_key);
    let scoped_context = scoped_file_content_context(context, &aad);
    let opened = open_payload(
        &content_key,
        &scoped_context,
        &encrypted.sealed,
        SecureMeshPayloadKind::FileChunk,
    )?;
    ensure!(
        opened.content_type.as_deref() == Some(SECURE_MESH_FILE_CHUNK_CONTENT_TYPE),
        "secure mesh file chunk content type mismatch"
    );
    let chunk = decode_chunk(&opened.body)?;
    ensure!(
        chunk.file_id == context.file_id,
        "secure mesh file chunk protection context mismatch"
    );
    ensure!(
        hash_bytes(chunk.file_id.as_bytes()) == encrypted.file_id_hash,
        "secure mesh file chunk file id hash mismatch"
    );
    ensure!(
        chunk.chunk_index == encrypted.chunk_index,
        "secure mesh file chunk index mismatch"
    );
    ensure!(
        chunk.bytes.len() == encrypted.plaintext_size,
        "secure mesh file chunk plaintext size mismatch"
    );
    ensure!(
        authenticated_file_chunk_hash(
            root_key,
            context,
            chunk.chunk_index,
            chunk.bytes.as_slice(),
        )? == encrypted.chunk_hash,
        "secure mesh file chunk hash mismatch"
    );
    Ok(chunk)
}

pub fn file_chunk_delivery_json(encrypted: &EncryptedSecureMeshFileChunk) -> Value {
    json!({
        "kind": "file_chunk",
        "contentType": SECURE_MESH_FILE_CHUNK_CONTENT_TYPE,
        "fileKeySuite": encrypted.file_key_suite,
        "fileAadDigest": encrypted.file_aad_digest,
        "fileIdHash": encrypted.file_id_hash,
        "chunkIndex": encrypted.chunk_index,
        "chunkHash": encrypted.chunk_hash,
        "plaintextSize": encrypted.plaintext_size,
        "ciphertextHash": encrypted.ciphertext_hash,
        "sealed": sealed_payload_json(&encrypted.sealed),
        "metadataEncrypted": true,
        "bodyRedacted": true
    })
}

pub fn start_file_transfer(
    manifest: &SecureMeshFileManifest,
) -> Result<SecureMeshFileTransferState> {
    validate_manifest_for_transfer(manifest)?;
    let chunk_count = usize::try_from(manifest.chunk_count)
        .map_err(|_| anyhow!("secure mesh file chunk count is too large"))?;
    Ok(SecureMeshFileTransferState {
        file_id: manifest.file_id.clone(),
        file_id_hash: hash_bytes(manifest.file_id.as_bytes()),
        total_size: manifest.total_size,
        chunk_size: manifest.chunk_size,
        chunk_count: manifest.chunk_count,
        received_chunks: vec![None; chunk_count],
        acknowledged_at: None,
    })
}

fn file_transfer_queue_id(
    manifest: &SecureMeshFileManifest,
    recipient_endpoint_id: &str,
) -> String {
    hash_bytes(
        format!(
            "licolite.secure-mesh.file-transfer-queue.v1\0{}\0{}",
            hash_bytes(manifest.file_id.as_bytes()),
            hash_bytes(recipient_endpoint_id.as_bytes())
        )
        .as_bytes(),
    )
}

pub fn record_file_chunk_receipt(
    state: &mut SecureMeshFileTransferState,
    encrypted: &EncryptedSecureMeshFileChunk,
) -> Result<SecureMeshFileResumeReport> {
    ensure!(
        state.acknowledged_at.is_none(),
        "secure mesh file transfer is already acknowledged"
    );
    ensure!(
        encrypted.file_id_hash == state.file_id_hash,
        "secure mesh file transfer chunk file id mismatch"
    );
    ensure!(
        encrypted.chunk_index < state.chunk_count,
        "secure mesh file transfer chunk index is outside manifest bounds"
    );
    validate_chunk_plaintext_size(state, encrypted.chunk_index, encrypted.plaintext_size)?;
    let receipt = SecureMeshFileChunkReceipt {
        chunk_index: encrypted.chunk_index,
        ciphertext_hash: encrypted.ciphertext_hash.clone(),
        plaintext_size: encrypted.plaintext_size,
    };
    let slot = state
        .received_chunks
        .get_mut(encrypted.chunk_index as usize)
        .ok_or_else(|| anyhow!("secure mesh file transfer chunk index is outside state bounds"))?;
    match slot {
        Some(existing) if existing == &receipt => return file_transfer_resume_report(state),
        Some(_) => {
            return Err(anyhow!(
                "secure mesh file transfer duplicate chunk has conflicting hash"
            ));
        }
        None => *slot = Some(receipt),
    }
    file_transfer_resume_report(state)
}

pub fn acknowledge_file_transfer(
    state: &mut SecureMeshFileTransferState,
    acknowledged_at: impl Into<String>,
) -> Result<SecureMeshFileResumeReport> {
    let acknowledged_at = acknowledged_at.into();
    ensure!(
        !acknowledged_at.trim().is_empty(),
        "secure mesh file transfer ack timestamp is required"
    );
    let report = file_transfer_resume_report(state)?;
    ensure!(
        report.complete,
        "secure mesh file transfer cannot be acknowledged before complete"
    );
    state.acknowledged_at = Some(acknowledged_at);
    file_transfer_resume_report(state)
}

pub fn file_transfer_resume_report(
    state: &SecureMeshFileTransferState,
) -> Result<SecureMeshFileResumeReport> {
    ensure_transfer_total_matches_receipts(state)?;
    let missing_chunk_indices = state
        .received_chunks
        .iter()
        .enumerate()
        .filter_map(|(index, receipt)| {
            if receipt.is_none() {
                Some(index as u32)
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    let received_chunk_count = state.received_chunks.len() - missing_chunk_indices.len();
    let complete = missing_chunk_indices.is_empty();
    Ok(SecureMeshFileResumeReport {
        received_chunk_count,
        missing_chunk_indices,
        complete,
        ack_required: complete && state.acknowledged_at.is_none(),
        purge_local_ciphertext: complete && state.acknowledged_at.is_some(),
    })
}

pub fn evaluate_file_route_json(params: &Value) -> Result<Value> {
    let manifest_value = params
        .get("manifest")
        .or_else(|| params.get("fileManifest"))
        .ok_or_else(|| anyhow!("secure mesh file manifest is required"))?;
    let manifest = manifest_from_json(manifest_value)?;
    let state = start_file_transfer(&manifest)?;
    let report = file_transfer_resume_report(&state)?;
    Ok(json!({
        "ok": true,
        "fileProtocolVersion": crate::core::secure_mesh::SECURE_MESH_FILE_PROTOCOL_VERSION,
        "fileCryptoStatus": SECURE_MESH_FILE_CRYPTO_STATUS,
        "route": {
            "transport": "SecureEnvelopeDeliveryMailbox",
            "uploadOperation": "secure_mesh.file_chunk.upload",
            "fetchOperation": "secure_mesh.file_chunk.fetch",
            "manifestContentType": SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE,
            "chunkContentType": SECURE_MESH_FILE_CHUNK_CONTENT_TYPE,
            "metadataEncrypted": true
        },
        "transfer": {
            "fileIdHash": state.file_id_hash,
            "totalSize": state.total_size,
            "chunkSize": state.chunk_size,
            "chunkCount": state.chunk_count
        },
        "resume": {
            "receivedChunkCount": report.received_chunk_count,
            "missingChunkIndices": report.missing_chunk_indices,
            "complete": report.complete,
            "ackRequired": report.ack_required,
            "purgeLocalCiphertext": report.purge_local_ciphertext
        }
    }))
}

pub fn evaluate_file_receive_destination_json(params: &Value) -> Result<Value> {
    let manifest_value = params
        .get("manifest")
        .or_else(|| params.get("fileManifest"))
        .ok_or_else(|| anyhow!("secure mesh file manifest is required"))?;
    let manifest = manifest_from_json(manifest_value)?;
    let approved_root = json_optional_text(
        params,
        &[
            "approvedRoot",
            "destinationRoot",
            "receiveRoot",
            "approvedDestinationRoot",
        ],
    )
    .ok_or_else(|| anyhow!("secure mesh file approved destination root is required"))?;
    let conflict_policy = json_optional_text(params, &["conflictPolicy"])
        .unwrap_or_else(|| DEFAULT_FILE_CONFLICT_POLICY.to_string());
    ensure!(
        matches!(
            conflict_policy.as_str(),
            "fail_if_exists" | "rename" | "overwrite_after_confirm"
        ),
        "secure mesh file destination conflict policy is unsupported"
    );
    let approved_root = PathBuf::from(approved_root);
    let relative_destination = receive_relative_path(&manifest)?;
    let destination = validate_receive_destination(&approved_root, &relative_destination)?;
    Ok(json!({
        "ok": true,
        "fileProtocolVersion": crate::core::secure_mesh::SECURE_MESH_FILE_PROTOCOL_VERSION,
        "receivePolicy": {
            "destinationApproved": true,
            "requiresUserApprovedRoot": true,
            "destinationPathRedacted": true,
            "conflictPolicy": conflict_policy,
            "writeOperation": "secure_mesh.file_receive.write"
        },
        "destination": {
            "approvedRootHash": hash_bytes(path_to_bytes(&approved_root).as_slice()),
            "relativePathHash": hash_bytes(path_to_bytes(&relative_destination).as_slice()),
            "fileNameHash": hash_bytes(manifest.file_name.as_bytes()),
            "resolvedPathHash": hash_bytes(path_to_bytes(&destination).as_slice())
        },
        "manifest": {
            "fileIdHash": hash_bytes(manifest.file_id.as_bytes()),
            "totalSize": manifest.total_size,
            "chunkSize": manifest.chunk_size,
            "chunkCount": manifest.chunk_count,
            "metadataEncrypted": true,
            "bodyRedacted": true
        }
    }))
}

pub fn evaluate_file_receive_confirmation_json(params: &Value) -> Result<Value> {
    let manifest_value = params
        .get("manifest")
        .or_else(|| params.get("fileManifest"))
        .ok_or_else(|| anyhow!("secure mesh file manifest is required"))?;
    let manifest = manifest_from_json(manifest_value)?;
    let approved_root = json_optional_text(
        params,
        &[
            "approvedRoot",
            "destinationRoot",
            "receiveRoot",
            "approvedDestinationRoot",
        ],
    )
    .ok_or_else(|| anyhow!("secure mesh file approved destination root is required"))?;
    let conflict_policy = json_optional_text(params, &["conflictPolicy"])
        .unwrap_or_else(|| DEFAULT_FILE_CONFLICT_POLICY.to_string());
    ensure!(
        matches!(
            conflict_policy.as_str(),
            "fail_if_exists" | "rename" | "overwrite_after_confirm"
        ),
        "secure mesh file destination conflict policy is unsupported"
    );
    ensure!(
        !json_bool(params, &["autoPreview", "autoPreviewEnabled"]).unwrap_or(false),
        "secure mesh file auto-preview is disabled before receive confirmation"
    );
    ensure!(
        !json_bool(
            params,
            &[
                "autoIngestion",
                "autoIngestionEnabled",
                "autoImport",
                "autoImportEnabled"
            ],
        )
        .unwrap_or(false),
        "secure mesh file auto-ingestion is disabled before receive confirmation"
    );
    let user_confirmed =
        json_bool(params, &["userConfirmed", "confirmed", "receiveConfirmed"]).unwrap_or(false);
    let approved_root = PathBuf::from(approved_root);
    let relative_destination = receive_relative_path(&manifest)?;
    let destination = validate_receive_destination(&approved_root, &relative_destination)?;
    let manifest_digest = hash_bytes(
        serde_json::to_vec(&manifest_to_json(&manifest))
            .context("secure mesh file manifest digest serialization failed")?
            .as_slice(),
    );
    Ok(json!({
        "ok": true,
        "fileProtocolVersion": crate::core::secure_mesh::SECURE_MESH_FILE_PROTOCOL_VERSION,
        "receiveConfirmation": {
            "required": true,
            "userVisibleConfirmationRequired": true,
            "userConfirmed": user_confirmed,
            "defaultDecision": if user_confirmed { "confirmed" } else { "pending_user_confirmation" },
            "writeAllowed": user_confirmed,
            "localWriteDeferredUntilConfirmed": !user_confirmed,
            "decryptedBytesHiddenUntilConfirmed": !user_confirmed,
            "autoPreviewEnabled": false,
            "autoIngestionEnabled": false,
            "autoPreviewDisabledByDefault": true,
            "autoIngestionDisabledByDefault": true,
            "receiveOperation": "secure_mesh.file_receive.confirm"
        },
        "receivePolicy": {
            "destinationApproved": true,
            "requiresUserApprovedRoot": true,
            "destinationPathRedacted": true,
            "conflictPolicy": conflict_policy,
            "writeOperation": "secure_mesh.file_receive.write"
        },
        "destination": {
            "approvedRootHash": hash_bytes(path_to_bytes(&approved_root).as_slice()),
            "relativePathHash": hash_bytes(path_to_bytes(&relative_destination).as_slice()),
            "fileNameHash": hash_bytes(manifest.file_name.as_bytes()),
            "resolvedPathHash": hash_bytes(path_to_bytes(&destination).as_slice())
        },
        "manifest": {
            "manifestHash": manifest_digest,
            "fileIdHash": hash_bytes(manifest.file_id.as_bytes()),
            "totalSize": manifest.total_size,
            "chunkSize": manifest.chunk_size,
            "chunkCount": manifest.chunk_count,
            "metadataEncrypted": true,
            "bodyRedacted": true
        }
    }))
}

pub fn evaluate_file_handoff_proof_json(params: &Value) -> Result<Value> {
    let manifest = if let Some(value) = params
        .get("manifest")
        .or_else(|| params.get("fileManifest"))
    {
        manifest_from_json(value)?
    } else {
        default_handoff_proof_manifest()
    };
    ensure!(
        manifest.chunk_count == 1,
        "secure mesh file handoff proof currently requires one chunk"
    );
    let chunk_bytes = handoff_proof_chunk_bytes(params, &manifest)?;
    let chunk = SecureMeshFileChunk {
        file_id: manifest.file_id.clone(),
        chunk_index: 0,
        bytes: chunk_bytes,
    };
    validate_chunk_plaintext_matches_manifest(&manifest, &chunk)?;

    let source_key = FileRootKey::generate();
    let file_hash = hash_bytes(&chunk.bytes);
    let sender_endpoint = json_optional_text(params, &["senderEndpoint"])
        .unwrap_or_else(|| "android-physical-endpoint".to_string());
    let desktop_endpoint = json_optional_text(params, &["desktopEndpoint"])
        .unwrap_or_else(|| "desktop-reseal-endpoint".to_string());
    let recipient_endpoints = handoff_recipient_endpoints(params)?;

    let source_manifest_context = SecureMeshFileProtectionContext::for_pairwise_device(
        handoff_context(
            "source_manifest",
            "msg_source_manifest",
            &sender_endpoint,
            &desktop_endpoint,
            "session_source_to_desktop",
        ),
        manifest.file_id.clone(),
        manifest.chunk_count,
        file_hash.clone(),
        1_800_000_000,
    )?;
    let source_chunk_context = SecureMeshFileProtectionContext::for_pairwise_device(
        handoff_context(
            "source_chunk_0",
            "msg_source_chunk_0",
            &sender_endpoint,
            &desktop_endpoint,
            "session_source_to_desktop",
        ),
        manifest.file_id.clone(),
        manifest.chunk_count,
        file_hash.clone(),
        1_800_000_000,
    )?;
    let encrypted_source_manifest =
        seal_file_manifest(&source_key, &source_manifest_context, &manifest)?;
    let encrypted_source_chunk = seal_file_chunk(&source_key, &source_chunk_context, &chunk)?;
    let source_manifest_delivery = file_manifest_delivery_json(&encrypted_source_manifest);
    let source_chunk_delivery = file_chunk_delivery_json(&encrypted_source_chunk);

    let opened_manifest = open_file_manifest(
        &source_key,
        &source_manifest_context,
        &encrypted_source_manifest,
    )?;
    let opened_chunk =
        open_file_chunk(&source_key, &source_chunk_context, &encrypted_source_chunk)?;
    ensure!(
        opened_manifest == manifest && opened_chunk == chunk,
        "secure mesh file handoff source open mismatch"
    );

    let mut recipient_deliveries = Vec::new();
    let mut recipient_server_visible = Vec::new();
    let mut resealed_manifest_hashes = HashSet::new();
    let mut resealed_chunk_hashes = HashSet::new();
    let mut first_resealed_manifest_hash = String::new();
    let mut first_resealed_chunk_hash = String::new();
    let mut first_resealed_manifest_size = 0usize;
    let mut first_resealed_chunk_size = 0usize;
    let mut all_recipients_opened_resealed = true;
    let mut all_wrong_recipients_rejected = true;
    let mut all_recipients_endpoint_specific_reseal_ready = true;
    let mut all_transfers_ack_purged = true;
    let mut transfer_queue = SecureMeshFileTransferQueue::default();

    for (recipient_index, recipient_endpoint) in recipient_endpoints.iter().enumerate() {
        let recipient_key = FileRootKey::generate();
        let recipient_index_label = recipient_index + 1;
        let recipient_session = format!("session_desktop_to_recipient_{recipient_index_label}");
        let recipient_manifest_envelope = format!("resealed_manifest_{recipient_index_label}");
        let recipient_manifest_message = format!("msg_resealed_manifest_{recipient_index_label}");
        let recipient_chunk_envelope = format!("resealed_chunk_0_{recipient_index_label}");
        let recipient_chunk_message = format!("msg_resealed_chunk_0_{recipient_index_label}");
        let recipient_manifest_context = SecureMeshFileProtectionContext::for_pairwise_device(
            handoff_context(
                &recipient_manifest_envelope,
                &recipient_manifest_message,
                &desktop_endpoint,
                recipient_endpoint,
                &recipient_session,
            ),
            manifest.file_id.clone(),
            manifest.chunk_count,
            file_hash.clone(),
            1_800_000_000,
        )?;
        let recipient_chunk_context = SecureMeshFileProtectionContext::for_pairwise_device(
            handoff_context(
                &recipient_chunk_envelope,
                &recipient_chunk_message,
                &desktop_endpoint,
                recipient_endpoint,
                &recipient_session,
            ),
            manifest.file_id.clone(),
            manifest.chunk_count,
            file_hash.clone(),
            1_800_000_000,
        )?;
        let resealed_manifest = seal_file_manifest(
            &recipient_key,
            &recipient_manifest_context,
            &opened_manifest,
        )?;
        let resealed_chunk =
            seal_file_chunk(&recipient_key, &recipient_chunk_context, &opened_chunk)?;
        let resealed_manifest_delivery = file_manifest_delivery_json(&resealed_manifest);
        let resealed_chunk_delivery = file_chunk_delivery_json(&resealed_chunk);

        let recipient_opened_manifest = open_file_manifest(
            &recipient_key,
            &recipient_manifest_context,
            &resealed_manifest,
        )?;
        let recipient_opened_chunk =
            open_file_chunk(&recipient_key, &recipient_chunk_context, &resealed_chunk)?;
        let recipient_opened_resealed =
            recipient_opened_manifest == manifest && recipient_opened_chunk == chunk;
        all_recipients_opened_resealed &= recipient_opened_resealed;

        let wrong_recipient_context = SecureMeshFileProtectionContext::for_pairwise_device(
            handoff_context(
                &recipient_manifest_envelope,
                &recipient_manifest_message,
                &desktop_endpoint,
                "wrong-recipient-endpoint",
                &recipient_session,
            ),
            manifest.file_id.clone(),
            manifest.chunk_count,
            file_hash.clone(),
            1_800_000_000,
        )?;
        let wrong_recipient_rejected =
            open_file_manifest(&recipient_key, &wrong_recipient_context, &resealed_manifest)
                .is_err();
        all_wrong_recipients_rejected &= wrong_recipient_rejected;

        let endpoint_specific_reseal_ready = encrypted_source_manifest.ciphertext_hash
            != resealed_manifest.ciphertext_hash
            && encrypted_source_chunk.ciphertext_hash != resealed_chunk.ciphertext_hash;
        all_recipients_endpoint_specific_reseal_ready &= endpoint_specific_reseal_ready;
        resealed_manifest_hashes.insert(resealed_manifest.ciphertext_hash.clone());
        resealed_chunk_hashes.insert(resealed_chunk.ciphertext_hash.clone());

        let transfer_id = transfer_queue.enqueue(&recipient_opened_manifest, recipient_endpoint)?;
        let receipt = transfer_queue.record_chunk(&transfer_id, &resealed_chunk)?;
        let ack_before_confirmation_rejected = transfer_queue
            .acknowledge(&transfer_id, "2026-01-01T00:00:00.000Z")
            .is_err();
        transfer_queue.confirm_receive(&transfer_id)?;
        let acknowledged = transfer_queue.acknowledge(&transfer_id, "2026-01-01T00:00:01.000Z")?;
        let purged_ciphertext_bytes = transfer_queue.purge_acknowledged(&transfer_id)?;
        let transfer_ack_purged = receipt.complete
            && receipt.ack_required
            && ack_before_confirmation_rejected
            && !acknowledged.ack_required
            && acknowledged.purge_local_ciphertext
            && purged_ciphertext_bytes == resealed_chunk.sealed.ciphertext_size;
        all_transfers_ack_purged &= transfer_ack_purged;

        if recipient_index == 0 {
            first_resealed_manifest_hash = resealed_manifest.ciphertext_hash.clone();
            first_resealed_chunk_hash = resealed_chunk.ciphertext_hash.clone();
            first_resealed_manifest_size = resealed_manifest.sealed.ciphertext_size;
            first_resealed_chunk_size = resealed_chunk.sealed.ciphertext_size;
        }

        recipient_server_visible.push(json!({
            "manifest": resealed_manifest_delivery,
            "chunk": resealed_chunk_delivery
        }));
        recipient_deliveries.push(json!({
            "recipientIndex": recipient_index_label,
            "recipientEndpointHash": hash_bytes(recipient_endpoint.as_bytes()),
            "recipientOpenedResealed": recipient_opened_resealed,
            "wrongRecipientRejected": wrong_recipient_rejected,
            "endpointSpecificResealReady": endpoint_specific_reseal_ready,
            "transferAckPurged": transfer_ack_purged,
            "resealedManifestCiphertextHash": resealed_manifest.ciphertext_hash,
            "resealedChunkCiphertextHash": resealed_chunk.ciphertext_hash,
            "resealedManifestCiphertextSize": resealed_manifest.sealed.ciphertext_size,
            "resealedChunkCiphertextSize": resealed_chunk.sealed.ciphertext_size,
            "receivedChunkCount": receipt.received_chunk_count,
            "ackRequiredBeforeAck": receipt.ack_required,
            "completeBeforeAck": receipt.complete,
            "ackBeforeReceiveConfirmationRejected": ack_before_confirmation_rejected,
            "ackRequiredAfterAck": acknowledged.ack_required,
            "purgeLocalCiphertext": acknowledged.purge_local_ciphertext,
            "purgedCiphertextBytes": purged_ciphertext_bytes
        }));
    }

    let recipient_count = recipient_endpoints.len();
    let multi_recipient_independent_reseal_ready = recipient_count > 1
        && resealed_manifest_hashes.len() == recipient_count
        && resealed_chunk_hashes.len() == recipient_count;
    let route = evaluate_file_route_json(&json!({ "manifest": manifest_to_json(&manifest) }))?;
    let approved_root = json_optional_text(params, &["approvedRoot", "receiveRoot"])
        .unwrap_or_else(|| std::env::temp_dir().to_string_lossy().into_owned());
    let receive_destination = evaluate_file_receive_destination_json(&json!({
        "manifest": manifest_to_json(&manifest),
        "approvedRoot": approved_root
    }))?;
    let receive_confirmation = evaluate_file_receive_confirmation_json(&json!({
        "manifest": manifest_to_json(&manifest),
        "approvedRoot": approved_root
    }))?;

    let server_visible = json!({
        "sourceManifest": source_manifest_delivery,
        "sourceChunk": source_chunk_delivery,
        "recipientDeliveries": recipient_server_visible,
        "route": route,
        "receiveDestination": receive_destination,
        "receiveConfirmation": receive_confirmation
    });
    let forbidden_canaries_absent = handoff_forbidden_canaries_absent(&server_visible);
    let endpoint_specific_reseal_ready =
        all_recipients_endpoint_specific_reseal_ready && multi_recipient_independent_reseal_ready;
    let transfer_queue_status = transfer_queue.redacted_status();
    let transfer_queue_drained = transfer_queue_status["activeTransferCount"].as_u64() == Some(0)
        && transfer_queue_status["queuedCiphertextBytes"].as_u64() == Some(0);

    Ok(json!({
        "ok": true,
        "fileProtocolVersion": crate::core::secure_mesh::SECURE_MESH_FILE_PROTOCOL_VERSION,
        "proofKind": "endpoint_specific_file_handoff_reseal",
        "metadataEncrypted": true,
        "bodyRedacted": true,
        "sourceOpenedByDesktop": true,
        "recipientOpenedResealed": all_recipients_opened_resealed,
        "wrongRecipientRejected": all_wrong_recipients_rejected,
        "endpointSpecificResealReady": endpoint_specific_reseal_ready,
        "recipientCount": recipient_count,
        "allRecipientsOpenedResealed": all_recipients_opened_resealed,
        "allRecipientsWrongRecipientRejected": all_wrong_recipients_rejected,
        "allRecipientsEndpointSpecificResealReady": all_recipients_endpoint_specific_reseal_ready,
        "multiRecipientIndependentResealReady": multi_recipient_independent_reseal_ready,
        "allRecipientTransfersAckPurged": all_transfers_ack_purged,
        "boundedTransferQueueReady": transfer_queue_drained,
        "deliveryJsonRedacted": forbidden_canaries_absent,
        "serverVisibleNoPlaintext": forbidden_canaries_absent,
        "routePolicyReady": route["route"]["metadataEncrypted"].as_bool() == Some(true),
        "receiveDestinationPolicyReady": receive_destination["receivePolicy"]["destinationApproved"].as_bool() == Some(true) &&
            receive_destination["receivePolicy"]["destinationPathRedacted"].as_bool() == Some(true),
        "receiveConfirmationPolicyReady": receive_confirmation["receiveConfirmation"]["required"].as_bool() == Some(true) &&
            receive_confirmation["receiveConfirmation"]["userVisibleConfirmationRequired"].as_bool() == Some(true) &&
            receive_confirmation["receiveConfirmation"]["writeAllowed"].as_bool() == Some(false) &&
            receive_confirmation["receiveConfirmation"]["autoPreviewEnabled"].as_bool() == Some(false) &&
            receive_confirmation["receiveConfirmation"]["autoIngestionEnabled"].as_bool() == Some(false),
        "transfer": {
            "chunkCount": manifest.chunk_count,
            "recipientCount": recipient_count,
            "allRecipientTransfersAckPurged": all_transfers_ack_purged,
            "boundedTransferQueueReady": transfer_queue_drained,
            "queue": transfer_queue_status
        },
        "recipientDeliveries": recipient_deliveries,
        "delivery": {
            "sourceManifestCiphertextHash": encrypted_source_manifest.ciphertext_hash,
            "sourceChunkCiphertextHash": encrypted_source_chunk.ciphertext_hash,
            "resealedManifestCiphertextHash": first_resealed_manifest_hash,
            "resealedChunkCiphertextHash": first_resealed_chunk_hash,
            "sourceManifestCiphertextSize": encrypted_source_manifest.sealed.ciphertext_size,
            "sourceChunkCiphertextSize": encrypted_source_chunk.sealed.ciphertext_size,
            "resealedManifestCiphertextSize": first_resealed_manifest_size,
            "resealedChunkCiphertextSize": first_resealed_chunk_size
        }
    }))
}

fn manifest_from_json(value: &Value) -> Result<SecureMeshFileManifest> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("secure mesh file manifest must be an object"))?;
    let manifest = SecureMeshFileManifest {
        file_id: json_text(object, &["fileId", "file_id"])?,
        file_name: json_text(object, &["fileName", "file_name"])?,
        mime_type: json_text(object, &["mimeType", "mime_type"])?,
        relative_path: json_text(object, &["relativePath", "relative_path"])?,
        total_size: json_u64(object, &["totalSize", "total_size"])?,
        chunk_size: json_u32(object, &["chunkSize", "chunk_size"])?,
        chunk_count: json_u32(object, &["chunkCount", "chunk_count"])?,
    };
    validate_manifest_for_transfer(&manifest)?;
    Ok(manifest)
}

fn manifest_to_json(manifest: &SecureMeshFileManifest) -> Value {
    json!({
        "fileId": &manifest.file_id,
        "fileName": &manifest.file_name,
        "mimeType": &manifest.mime_type,
        "relativePath": &manifest.relative_path,
        "totalSize": manifest.total_size,
        "chunkSize": manifest.chunk_size,
        "chunkCount": manifest.chunk_count
    })
}

fn json_optional_text(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn handoff_recipient_endpoints(params: &Value) -> Result<Vec<String>> {
    let mut endpoints = if let Some(values) = params.get("recipientEndpoints") {
        let array = values.as_array().ok_or_else(|| {
            anyhow!("secure mesh file handoff recipientEndpoints must be an array")
        })?;
        array
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
            .collect::<Vec<_>>()
    } else if let Some(endpoint) = json_optional_text(params, &["recipientEndpoint"]) {
        vec![endpoint, "secondary-phone-recipient-endpoint".to_string()]
    } else {
        vec![
            "iphone-recipient-endpoint".to_string(),
            "android-recipient-endpoint".to_string(),
        ]
    };
    endpoints.sort();
    endpoints.dedup();
    ensure!(
        endpoints.len() >= 2,
        "secure mesh file handoff requires at least two recipient endpoints"
    );
    Ok(endpoints)
}

fn json_bool(value: &Value, keys: &[&str]) -> Option<bool> {
    keys.iter().find_map(|key| {
        let value = value.get(*key)?;
        if let Some(flag) = value.as_bool() {
            return Some(flag);
        }
        match value.as_str()?.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Some(true),
            "0" | "false" | "no" | "off" => Some(false),
            _ => None,
        }
    })
}

fn json_text(object: &serde_json::Map<String, Value>, keys: &[&str]) -> Result<String> {
    let value = keys
        .iter()
        .find_map(|key| object.get(*key))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    ensure!(
        !value.is_empty(),
        "secure mesh file manifest text field is required"
    );
    Ok(value)
}

fn json_u64(object: &serde_json::Map<String, Value>, keys: &[&str]) -> Result<u64> {
    let value = keys
        .iter()
        .find_map(|key| object.get(*key))
        .ok_or_else(|| anyhow!("secure mesh file manifest integer field is required"))?;
    if let Some(number) = value.as_u64() {
        return Ok(number);
    }
    value
        .as_str()
        .unwrap_or_default()
        .trim()
        .parse::<u64>()
        .map_err(|_| anyhow!("secure mesh file manifest integer field is invalid"))
}

fn json_u32(object: &serde_json::Map<String, Value>, keys: &[&str]) -> Result<u32> {
    let value = json_u64(object, keys)?;
    u32::try_from(value)
        .map_err(|_| anyhow!("secure mesh file manifest integer field is too large"))
}

fn validate_manifest(manifest: &SecureMeshFileManifest) -> Result<()> {
    validate_text("file_id", &manifest.file_id, MAX_FILE_NAME_BYTES)?;
    validate_text("file_name", &manifest.file_name, MAX_FILE_NAME_BYTES)?;
    validate_file_name_segment(&manifest.file_name)?;
    validate_text("mime_type", &manifest.mime_type, MAX_MIME_BYTES)?;
    validate_relative_path(&manifest.relative_path)?;
    ensure!(
        manifest.chunk_size > 0,
        "secure mesh file chunk size is required"
    );
    ensure!(
        manifest.chunk_count > 0 && manifest.chunk_count <= MAX_CHUNK_COUNT,
        "secure mesh file chunk count is outside bounds"
    );
    Ok(())
}

fn validate_manifest_for_transfer(manifest: &SecureMeshFileManifest) -> Result<()> {
    validate_manifest(manifest)?;
    ensure!(
        manifest.total_size > 0,
        "secure mesh file total size is required"
    );
    let expected_count = manifest.total_size.div_ceil(u64::from(manifest.chunk_size));
    ensure!(
        expected_count == u64::from(manifest.chunk_count),
        "secure mesh file manifest chunk count does not match total size"
    );
    Ok(())
}

fn validate_chunk_plaintext_matches_manifest(
    manifest: &SecureMeshFileManifest,
    chunk: &SecureMeshFileChunk,
) -> Result<()> {
    ensure!(
        chunk.file_id == manifest.file_id,
        "secure mesh file handoff chunk file id mismatch"
    );
    ensure!(
        chunk.chunk_index == 0 && manifest.chunk_count == 1,
        "secure mesh file handoff proof currently requires one chunk"
    );
    ensure!(
        u64::try_from(chunk.bytes.len()).unwrap_or(u64::MAX) == manifest.total_size,
        "secure mesh file handoff chunk size does not match manifest"
    );
    Ok(())
}

fn default_handoff_proof_manifest() -> SecureMeshFileManifest {
    let chunk = default_handoff_proof_chunk_bytes();
    SecureMeshFileManifest {
        file_id: "handoff-proof-file-id-private-file-canary".to_string(),
        file_name: "handoff-proof-private-file-canary.pdf".to_string(),
        mime_type: "application/x-handoff-private-file-canary".to_string(),
        relative_path: "phone/handoff/private-relative-canary".to_string(),
        total_size: chunk.len() as u64,
        chunk_size: chunk.len() as u32,
        chunk_count: 1,
    }
}

fn default_handoff_proof_chunk_bytes() -> Vec<u8> {
    b"file-body-plaintext-secret-canary-content".to_vec()
}

fn handoff_proof_chunk_bytes(params: &Value, manifest: &SecureMeshFileManifest) -> Result<Vec<u8>> {
    if let Some(encoded) = json_optional_text(params, &["chunkBytesBase64url", "chunkBase64url"]) {
        let bytes = general_purpose::URL_SAFE_NO_PAD
            .decode(encoded)
            .context("secure mesh file handoff chunk is not base64url")?;
        ensure!(!bytes.is_empty(), "secure mesh file handoff chunk is empty");
        return Ok(bytes);
    }
    if manifest.file_id == "handoff-proof-file-id-private-file-canary" {
        return Ok(default_handoff_proof_chunk_bytes());
    }
    let size = usize::try_from(manifest.total_size)
        .map_err(|_| anyhow!("secure mesh file handoff chunk size is too large"))?;
    ensure!(size > 0, "secure mesh file handoff chunk is empty");
    Ok(vec![0xA5; size])
}

fn handoff_context(
    envelope: &str,
    message: &str,
    sender: &str,
    recipient: &str,
    session: &str,
) -> SecureMeshContentContext {
    SecureMeshContentContext::new(
        format!("env_{envelope}"),
        message,
        "mailbox_file_handoff",
        sender,
        recipient,
        session,
        "2026-01-01T00:00:00.000Z",
        "2026-01-01T00:10:00.000Z",
    )
}

fn handoff_forbidden_canaries_absent(value: &Value) -> bool {
    let serialized = value.to_string();
    [
        "handoff-proof-file-id-private-file-canary",
        "handoff-proof-private-file-canary.pdf",
        "application/x-handoff-private-file-canary",
        "private-relative-canary",
        "file-body-plaintext-secret-canary-content",
    ]
    .iter()
    .all(|forbidden| !serialized.contains(forbidden))
}

fn receive_relative_path(manifest: &SecureMeshFileManifest) -> Result<PathBuf> {
    validate_manifest(manifest)?;
    let mut path = PathBuf::new();
    if !manifest.relative_path.trim().is_empty() {
        path.push(normalized_relative_path(&manifest.relative_path)?);
    }
    path.push(&manifest.file_name);
    validate_relative_path(&path_to_string(&path)?)?;
    Ok(path)
}

fn validate_receive_destination(root: &Path, relative_path: &Path) -> Result<PathBuf> {
    ensure!(
        root.is_absolute(),
        "secure mesh file approved destination root must be absolute"
    );
    ensure!(
        path_is_clean_relative(relative_path),
        "secure mesh file destination relative path is outside approved root"
    );
    let destination = root.join(relative_path);
    ensure!(
        destination.starts_with(root),
        "secure mesh file destination path is outside approved root"
    );
    Ok(destination)
}

fn validate_chunk_plaintext_size(
    state: &SecureMeshFileTransferState,
    chunk_index: u32,
    plaintext_size: usize,
) -> Result<()> {
    ensure!(
        plaintext_size > 0,
        "secure mesh file transfer chunk is empty"
    );
    let expected_size = expected_chunk_size(state, chunk_index)?;
    ensure!(
        plaintext_size == expected_size,
        "secure mesh file transfer chunk size does not match manifest"
    );
    Ok(())
}

fn expected_chunk_size(state: &SecureMeshFileTransferState, chunk_index: u32) -> Result<usize> {
    ensure!(
        chunk_index < state.chunk_count,
        "secure mesh file transfer chunk index is outside manifest bounds"
    );
    if chunk_index + 1 < state.chunk_count {
        return usize::try_from(state.chunk_size)
            .map_err(|_| anyhow!("secure mesh file chunk size is too large"));
    }
    let consumed_before_last = u64::from(state.chunk_size) * u64::from(state.chunk_count - 1);
    usize::try_from(state.total_size - consumed_before_last)
        .map_err(|_| anyhow!("secure mesh file final chunk size is too large"))
}

fn ensure_transfer_total_matches_receipts(state: &SecureMeshFileTransferState) -> Result<()> {
    if state.received_chunks.iter().any(Option::is_none) {
        return Ok(());
    }
    let total = state
        .received_chunks
        .iter()
        .filter_map(|receipt| receipt.as_ref())
        .map(|receipt| receipt.plaintext_size as u64)
        .sum::<u64>();
    ensure!(
        total == state.total_size,
        "secure mesh file transfer received size does not match manifest"
    );
    Ok(())
}

fn sealed_payload_json(sealed: &SealedSecureMeshPayload) -> Value {
    json!({
        "protocolVersion": sealed.protocol_version,
        "cipherSuite": sealed.cipher_suite,
        "encryptedHeader": sealed.encrypted_header,
        "ciphertext": sealed.ciphertext,
        "ciphertextSize": sealed.ciphertext_size
    })
}

fn validate_chunk(chunk: &SecureMeshFileChunk) -> Result<()> {
    validate_text("file_id", &chunk.file_id, MAX_FILE_NAME_BYTES)?;
    ensure!(
        chunk.bytes.len() <= MAX_CHUNK_BYTES,
        "secure mesh file chunk body is too large"
    );
    Ok(())
}

fn validate_text(label: &str, value: &str, max: usize) -> Result<()> {
    ensure!(
        !value.trim().is_empty(),
        "secure mesh file {label} is required"
    );
    ensure!(value.len() <= max, "secure mesh file {label} is too large");
    Ok(())
}

fn validate_crypto_context_text(label: &str, value: &str, max: usize) -> Result<()> {
    validate_text(label, value, max)?;
    ensure!(
        value == value.trim() && !value.chars().any(char::is_control),
        "secure mesh file {label} is not canonical"
    );
    Ok(())
}

fn validate_relative_path(value: &str) -> Result<()> {
    ensure!(
        value.len() <= MAX_RELATIVE_PATH_BYTES,
        "secure mesh file relative path is too large"
    );
    ensure!(
        !value.starts_with('/') && !value.starts_with('\\'),
        "secure mesh file relative path must be relative"
    );
    for segment in value.split(['/', '\\']) {
        ensure!(
            segment != "." && segment != "..",
            "secure mesh file relative path must not traverse"
        );
    }
    Ok(())
}

fn validate_file_name_segment(value: &str) -> Result<()> {
    ensure!(
        !value.contains('/') && !value.contains('\\'),
        "secure mesh file name must not contain path separators"
    );
    ensure!(
        value != "." && value != "..",
        "secure mesh file name must be a file name segment"
    );
    Ok(())
}

fn normalized_relative_path(value: &str) -> Result<PathBuf> {
    validate_relative_path(value)?;
    let mut path = PathBuf::new();
    for segment in value
        .split(['/', '\\'])
        .filter(|segment| !segment.is_empty())
    {
        path.push(segment);
    }
    Ok(path)
}

fn path_is_clean_relative(path: &Path) -> bool {
    !path.is_absolute()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_) | Component::CurDir))
}

fn path_to_string(path: &Path) -> Result<String> {
    path.to_str()
        .map(ToString::to_string)
        .ok_or_else(|| anyhow!("secure mesh file path is not valid UTF-8"))
}

fn path_to_bytes(path: &Path) -> Vec<u8> {
    path.to_string_lossy().as_bytes().to_vec()
}

fn encode_manifest(manifest: &SecureMeshFileManifest) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(FILE_MANIFEST_MAGIC);
    append_len_prefixed_bytes(&mut out, manifest.file_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, manifest.file_name.as_bytes())?;
    append_len_prefixed_bytes(&mut out, manifest.mime_type.as_bytes())?;
    append_len_prefixed_bytes(&mut out, manifest.relative_path.as_bytes())?;
    out.extend_from_slice(&manifest.total_size.to_be_bytes());
    out.extend_from_slice(&manifest.chunk_size.to_be_bytes());
    out.extend_from_slice(&manifest.chunk_count.to_be_bytes());
    Ok(out)
}

fn decode_manifest(bytes: &[u8]) -> Result<SecureMeshFileManifest> {
    let mut reader = SliceReader::new(bytes);
    reader.expect_bytes(FILE_MANIFEST_MAGIC)?;
    let manifest = SecureMeshFileManifest {
        file_id: read_string(&mut reader, "file_id")?,
        file_name: read_string(&mut reader, "file_name")?,
        mime_type: read_string(&mut reader, "mime_type")?,
        relative_path: read_string(&mut reader, "relative_path")?,
        total_size: reader.read_u64()?,
        chunk_size: reader.read_u32()?,
        chunk_count: reader.read_u32()?,
    };
    ensure!(
        reader.is_empty(),
        "secure mesh file manifest has trailing bytes"
    );
    validate_manifest(&manifest)?;
    Ok(manifest)
}

fn encode_chunk(chunk: &SecureMeshFileChunk) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(FILE_CHUNK_MAGIC);
    append_len_prefixed_bytes(&mut out, chunk.file_id.as_bytes())?;
    out.extend_from_slice(&chunk.chunk_index.to_be_bytes());
    append_len_prefixed_bytes(&mut out, &chunk.bytes)?;
    Ok(out)
}

fn decode_chunk(bytes: &[u8]) -> Result<SecureMeshFileChunk> {
    let mut reader = SliceReader::new(bytes);
    reader.expect_bytes(FILE_CHUNK_MAGIC)?;
    let chunk = SecureMeshFileChunk {
        file_id: read_string(&mut reader, "file_id")?,
        chunk_index: reader.read_u32()?,
        bytes: reader.read_len_prefixed_bytes()?.to_vec(),
    };
    ensure!(
        reader.is_empty(),
        "secure mesh file chunk has trailing bytes"
    );
    validate_chunk(&chunk)?;
    Ok(chunk)
}

fn ciphertext_hash(sealed: &SealedSecureMeshPayload) -> Result<String> {
    let ciphertext = general_purpose::URL_SAFE_NO_PAD
        .decode(&sealed.ciphertext)
        .context("secure mesh file ciphertext is not base64url")?;
    Ok(hash_bytes(&ciphertext))
}

fn hash_bytes(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    format!("sha256:{}", general_purpose::URL_SAFE_NO_PAD.encode(digest))
}

fn validate_file_hash(label: &str, value: &str) -> Result<()> {
    let encoded = value
        .strip_prefix("sha256:")
        .ok_or_else(|| anyhow!("secure mesh file {label} algorithm is unsupported"))?;
    decode_exact_base64url(label, encoded, 32)?;
    Ok(())
}

fn validate_authenticated_digest(label: &str, value: &str) -> Result<()> {
    let encoded = value
        .strip_prefix("sha256:")
        .or_else(|| value.strip_prefix("hmac-sha256:"))
        .ok_or_else(|| anyhow!("secure mesh file {label} algorithm is unsupported"))?;
    decode_exact_base64url(label, encoded, 32)?;
    Ok(())
}

fn validate_file_chunk_hash(label: &str, value: &str) -> Result<()> {
    let encoded = value
        .strip_prefix("hmac-sha256:")
        .ok_or_else(|| anyhow!("secure mesh file {label} algorithm is unsupported"))?;
    decode_exact_base64url(label, encoded, 32)?;
    Ok(())
}

fn decode_exact_base64url(label: &str, value: &str, expected_len: usize) -> Result<Vec<u8>> {
    ensure!(
        !value.contains('=')
            && !value
                .chars()
                .any(|character| matches!(character, '+' | '/')),
        "secure mesh {label} is not canonical base64url"
    );
    let decoded = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .with_context(|| format!("secure mesh {label} is not base64url"))?;
    ensure!(
        decoded.len() == expected_len,
        "secure mesh {label} length is invalid"
    );
    ensure!(
        general_purpose::URL_SAFE_NO_PAD.encode(&decoded) == value,
        "secure mesh {label} is not canonical base64url"
    );
    Ok(decoded)
}

fn read_string(reader: &mut SliceReader<'_>, label: &str) -> Result<String> {
    let bytes = reader.read_len_prefixed_bytes()?;
    String::from_utf8(bytes.to_vec())
        .map_err(|_| anyhow!("secure mesh file {label} is not valid UTF-8"))
}

fn append_len_prefixed_bytes(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len =
        u32::try_from(value.len()).map_err(|_| anyhow!("secure mesh file field is too large"))?;
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
        ensure!(actual == expected, "secure mesh file magic is invalid");
        Ok(())
    }

    fn read_u32(&mut self) -> Result<u32> {
        let bytes = self.read_exact(4)?;
        Ok(u32::from_be_bytes(
            bytes
                .try_into()
                .map_err(|_| anyhow!("secure mesh file u32 is invalid"))?,
        ))
    }

    fn read_u64(&mut self) -> Result<u64> {
        let bytes = self.read_exact(8)?;
        Ok(u64::from_be_bytes(
            bytes
                .try_into()
                .map_err(|_| anyhow!("secure mesh file u64 is invalid"))?,
        ))
    }

    fn read_len_prefixed_bytes(&mut self) -> Result<&'a [u8]> {
        let len = self.read_u32()? as usize;
        self.read_exact(len)
    }

    fn read_exact(&mut self, len: usize) -> Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(len)
            .ok_or_else(|| anyhow!("secure mesh file length overflow"))?;
        ensure!(
            end <= self.bytes.len(),
            "secure mesh file payload is truncated"
        );
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
    use crate::core::secure_mesh_pairwise::{
        SecureMeshPairwisePrivateKey, SecureMeshPairwiseSession,
    };
    use crate::core::secure_mesh_pqxdh::SecureMeshMlKem1024PreKeySeed;
    use crate::core::secure_mesh_prekey::{
        SecureMeshPairwisePreKeyBundle, SecureMeshPreKeyKind, SecureMeshPreKeyValidationPolicy,
        authorize_test_pairwise_prekey_bundle, sign_prekey_record,
    };
    use crate::core::secure_mesh_trust::{DeviceTrustPublicIdentity, DeviceTrustState};
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;
    use time::{OffsetDateTime, format_description::well_known::Rfc3339};

    #[test]
    fn secure_mesh_file_manifest_and_chunk_round_trip_without_outer_metadata_leak() {
        let key = key_fixture();
        let manifest = manifest_fixture();
        let manifest_context = context_fixture("manifest", "msg_manifest", &manifest);
        let encrypted_manifest = seal_file_manifest(&key, &manifest_context, &manifest).unwrap();
        let serialized_outer = format!("{:?}", encrypted_manifest);
        assert!(!serialized_outer.contains(&manifest.file_name));
        assert!(!serialized_outer.contains(&manifest.mime_type));
        assert!(!serialized_outer.contains(&manifest.relative_path));
        let opened_manifest =
            open_file_manifest(&key, &manifest_context, &encrypted_manifest).unwrap();
        assert_eq!(opened_manifest, manifest);

        let chunk = SecureMeshFileChunk {
            file_id: manifest.file_id.clone(),
            chunk_index: 0,
            bytes: b"encrypted file chunk bytes".to_vec(),
        };
        let chunk_context = context_fixture("chunk_0", "msg_chunk_0", &manifest);
        let encrypted_chunk = seal_file_chunk(&key, &chunk_context, &chunk).unwrap();
        assert_ne!(
            encrypted_chunk.ciphertext_hash,
            hash_bytes(chunk.bytes.as_slice())
        );
        assert!(encrypted_chunk.chunk_hash.starts_with("hmac-sha256:"));
        assert_ne!(
            encrypted_chunk.chunk_hash,
            hash_bytes(chunk.bytes.as_slice())
        );
        let opened_chunk = open_file_chunk(&key, &chunk_context, &encrypted_chunk).unwrap();
        assert_eq!(opened_chunk, chunk);
    }

    #[test]
    fn file_root_key_is_random_redacted_and_hkdf_domains_are_disjoint() {
        let first = FileRootKey::generate();
        let second = FileRootKey::generate();
        assert_ne!(first.as_bytes(), second.as_bytes());
        assert_eq!(format!("{first:?}"), "FileRootKey([redacted])");

        let manifest = manifest_fixture();
        let context = context_fixture("domain", "msg_domain", &manifest);
        let manifest_aad = file_authenticated_data(
            &context,
            FILE_AAD_MANIFEST_PURPOSE,
            None,
            context.file_hash(),
        )
        .unwrap();
        let chunk_zero_aad = file_authenticated_data(
            &context,
            FILE_AAD_CHUNK_PURPOSE,
            Some(0),
            context.file_hash(),
        )
        .unwrap();
        let chunk_one_aad = file_authenticated_data(
            &context,
            FILE_AAD_CHUNK_PURPOSE,
            Some(1),
            context.file_hash(),
        )
        .unwrap();
        let chunk_hash_aad = file_authenticated_data(
            &context,
            FILE_AAD_CHUNK_HASH_PURPOSE,
            Some(0),
            context.file_hash(),
        )
        .unwrap();
        let receipt_hash = hash_bytes(b"receipt-ciphertext");
        let receipt_aad =
            file_authenticated_data(&context, FILE_AAD_RECEIPT_PURPOSE, Some(0), &receipt_hash)
                .unwrap();
        let key_wrap_aad = file_authenticated_data(
            &context,
            FILE_AAD_KEY_WRAP_PURPOSE,
            None,
            context.file_hash(),
        )
        .unwrap();
        let keys = [
            derive_file_key(first.as_bytes(), FILE_HKDF_MANIFEST_DOMAIN, &manifest_aad).unwrap(),
            derive_file_key(first.as_bytes(), FILE_HKDF_CHUNK_DOMAIN, &chunk_zero_aad).unwrap(),
            derive_file_key(first.as_bytes(), FILE_HKDF_CHUNK_DOMAIN, &chunk_one_aad).unwrap(),
            derive_file_key(
                first.as_bytes(),
                FILE_HKDF_CHUNK_HASH_DOMAIN,
                &chunk_hash_aad,
            )
            .unwrap(),
            derive_file_key(first.as_bytes(), FILE_HKDF_RECEIPT_DOMAIN, &receipt_aad).unwrap(),
            derive_file_key(first.as_bytes(), FILE_HKDF_KEY_WRAP_DOMAIN, &key_wrap_aad).unwrap(),
        ];
        assert_eq!(
            keys.into_iter()
                .map(|key| key.as_ref().to_vec())
                .collect::<HashSet<_>>()
                .len(),
            6
        );
    }

    #[test]
    fn pairwise_file_key_envelopes_are_per_device_and_reject_duplicate_recipients() {
        let root_key = FileRootKey::from_bytes([0x31; FILE_ROOT_KEY_BYTES]);
        let manifest = manifest_fixture();
        let file_hash = hash_bytes(b"pairwise-multi-device-file");
        let first_context = pairwise_context_fixture(
            "pairwise_key_one",
            "pairwise_key_one",
            &manifest,
            "sender:endpoint",
            "recipient:one",
            "pairwise:session:one",
            &file_hash,
            1_800_000_000,
        );
        let second_context = pairwise_context_fixture(
            "pairwise_key_two",
            "pairwise_key_two",
            &manifest,
            "sender:endpoint",
            "recipient:two",
            "pairwise:session:two",
            &file_hash,
            1_800_000_000,
        );
        let first_secret = FileKeyWrapSecret::from_bytes([0x32; FILE_KEY_WRAP_SECRET_BYTES]);
        let second_secret = FileKeyWrapSecret::from_bytes([0x33; FILE_KEY_WRAP_SECRET_BYTES]);
        let envelopes = seal_file_root_key_for_pairwise_devices(
            &root_key,
            [
                (&first_secret, &first_context),
                (&second_secret, &second_context),
            ],
        )
        .unwrap();
        assert_eq!(envelopes.len(), 2);
        assert_ne!(envelopes[0].ciphertext, envelopes[1].ciphertext);
        let first_opened = open_file_root_key_for_pairwise_device(
            &envelopes[0],
            &first_secret,
            &first_context,
            1_700_000_000,
        )
        .unwrap();
        let second_opened = open_file_root_key_for_pairwise_device(
            &envelopes[1],
            &second_secret,
            &second_context,
            1_700_000_000,
        )
        .unwrap();
        assert_eq!(first_opened.as_bytes(), root_key.as_bytes());
        assert_eq!(second_opened.as_bytes(), root_key.as_bytes());
        assert!(
            open_file_root_key_for_pairwise_device(
                &envelopes[0],
                &second_secret,
                &second_context,
                1_700_000_000,
            )
            .is_err()
        );

        let duplicate_context = pairwise_context_fixture(
            "pairwise_key_duplicate",
            "pairwise_key_duplicate",
            &manifest,
            "sender:endpoint",
            "recipient:one",
            "pairwise:session:duplicate",
            &file_hash,
            1_800_000_000,
        );
        assert!(
            seal_file_root_key_for_pairwise_devices(
                &root_key,
                [
                    (&first_secret, &first_context),
                    (&second_secret, &duplicate_context),
                ],
            )
            .unwrap_err()
            .to_string()
            .contains("duplicated")
        );
    }

    #[test]
    fn mls_file_key_envelope_rejects_wrong_epoch_context_expiry_tamper_and_old_format() {
        let root_key = FileRootKey::from_bytes([0x41; FILE_ROOT_KEY_BYTES]);
        let exporter_secret = FileKeyWrapSecret::from_bytes([0x42; FILE_KEY_WRAP_SECRET_BYTES]);
        let manifest = manifest_fixture();
        let file_hash = hash_bytes(b"mls-epoch-file");
        let context = mls_context_fixture(
            "mls_key",
            "mls_key",
            &manifest,
            "sender:endpoint",
            "recipient:endpoint",
            "mls:session",
            &file_hash,
            "mls:group",
            7,
            1_800_000_000,
        );
        let envelope =
            seal_file_root_key_for_mls_epoch(&root_key, &exporter_secret, &context).unwrap();
        let opened = open_file_root_key_for_mls_epoch(
            &envelope,
            &exporter_secret,
            &context,
            7,
            1_700_000_000,
        )
        .unwrap();
        assert_eq!(opened.as_bytes(), root_key.as_bytes());
        assert!(
            open_file_root_key_for_mls_epoch(
                &envelope,
                &exporter_secret,
                &context,
                8,
                1_700_000_000,
            )
            .is_err()
        );
        assert!(
            open_file_root_key_for_mls_epoch(
                &envelope,
                &exporter_secret,
                &context,
                7,
                1_800_000_001,
            )
            .is_err()
        );

        let wrong_context = mls_context_fixture(
            "mls_key",
            "mls_key",
            &manifest,
            "sender:endpoint",
            "recipient:attacker",
            "mls:session",
            &file_hash,
            "mls:group",
            7,
            1_800_000_000,
        );
        assert!(
            open_file_root_key_for_mls_epoch(
                &envelope,
                &exporter_secret,
                &wrong_context,
                7,
                1_700_000_000,
            )
            .is_err()
        );

        let mut tampered: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
        let mut ciphertext = general_purpose::URL_SAFE_NO_PAD
            .decode(tampered["ciphertext"].as_str().unwrap())
            .unwrap();
        ciphertext[0] ^= 1;
        tampered["ciphertext"] = json!(general_purpose::URL_SAFE_NO_PAD.encode(ciphertext));
        let tampered =
            FileKeyEnvelope::from_json(&serde_json::to_string(&tampered).unwrap()).unwrap();
        assert!(
            open_file_root_key_for_mls_epoch(
                &tampered,
                &exporter_secret,
                &context,
                7,
                1_700_000_000,
            )
            .is_err()
        );
        assert!(FileKeyEnvelope::from_json(r#"{"fileKeyBytes":[1,2,3]}"#).is_err());
        let mut unknown: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
        unknown["legacyFileKey"] = json!("forbidden");
        assert!(FileKeyEnvelope::from_json(&serde_json::to_string(&unknown).unwrap()).is_err());
    }

    #[test]
    fn file_receipt_authentication_rejects_hash_tag_context_and_expiry_tampering() {
        let root_key = key_fixture();
        let manifest = manifest_fixture();
        let context = context_fixture("receipt_chunk", "receipt_chunk", &manifest);
        let chunk = SecureMeshFileChunk {
            file_id: manifest.file_id.clone(),
            chunk_index: 0,
            bytes: vec![0x51; manifest.chunk_size as usize],
        };
        let encrypted = seal_file_chunk(&root_key, &context, &chunk).unwrap();
        let receipt =
            authenticate_file_chunk_receipt(&root_key, &context, &encrypted, 1_700_000_000)
                .unwrap();
        verify_file_chunk_receipt(&root_key, &context, &receipt, 1_700_000_000).unwrap();

        let mut tampered_hash = receipt.clone();
        tampered_hash.ciphertext_hash = hash_bytes(b"tampered-ciphertext");
        assert!(
            verify_file_chunk_receipt(&root_key, &context, &tampered_hash, 1_700_000_000,).is_err()
        );
        let mut tampered_tag = receipt.clone();
        tampered_tag.authentication_tag = general_purpose::URL_SAFE_NO_PAD.encode([0u8; 32]);
        assert!(
            verify_file_chunk_receipt(&root_key, &context, &tampered_tag, 1_700_000_000,).is_err()
        );
        let wrong_context = pairwise_context_fixture(
            "receipt_chunk",
            "receipt_chunk",
            &manifest,
            "desktop_gui:alpha",
            "mobile:attacker",
            "file_session_test",
            context.file_hash(),
            1_800_000_000,
        );
        assert!(
            verify_file_chunk_receipt(&root_key, &wrong_context, &receipt, 1_700_000_000,).is_err()
        );
        assert!(verify_file_chunk_receipt(&root_key, &context, &receipt, 1_800_000_001).is_err());
    }

    #[test]
    fn file_payload_aad_rejects_every_bound_context_dimension_and_metadata_tamper() {
        let root_key = key_fixture();
        let manifest = manifest_fixture();
        let file_hash = hash_bytes(b"canonical-complete-file-hash");
        let context = pairwise_context_fixture(
            "aad_bound",
            "aad_bound",
            &manifest,
            "sender:endpoint",
            "recipient:endpoint",
            "pairwise:session",
            &file_hash,
            1_800_000_000,
        );
        let chunk = SecureMeshFileChunk {
            file_id: manifest.file_id.clone(),
            chunk_index: 0,
            bytes: vec![0x61; manifest.chunk_size as usize],
        };
        let encrypted_manifest = seal_file_manifest(&root_key, &context, &manifest).unwrap();
        let encrypted_chunk = seal_file_chunk(&root_key, &context, &chunk).unwrap();

        let context_variants = [
            pairwise_context_fixture(
                "aad_bound",
                "aad_bound",
                &manifest,
                "sender:attacker",
                "recipient:endpoint",
                "pairwise:session",
                &file_hash,
                1_800_000_000,
            ),
            pairwise_context_fixture(
                "aad_bound",
                "aad_bound",
                &manifest,
                "sender:endpoint",
                "recipient:attacker",
                "pairwise:session",
                &file_hash,
                1_800_000_000,
            ),
            pairwise_context_fixture(
                "aad_bound",
                "aad_bound",
                &manifest,
                "sender:endpoint",
                "recipient:endpoint",
                "pairwise:session:wrong",
                &file_hash,
                1_800_000_000,
            ),
            pairwise_context_fixture(
                "aad_bound",
                "aad_bound",
                &manifest,
                "sender:endpoint",
                "recipient:endpoint",
                "pairwise:session",
                &hash_bytes(b"wrong-file-hash"),
                1_800_000_000,
            ),
            pairwise_context_fixture(
                "aad_bound",
                "aad_bound",
                &manifest,
                "sender:endpoint",
                "recipient:endpoint",
                "pairwise:session",
                &file_hash,
                1_800_000_001,
            ),
        ];
        for wrong_context in context_variants {
            assert!(open_file_manifest(&root_key, &wrong_context, &encrypted_manifest).is_err());
            assert!(open_file_chunk(&root_key, &wrong_context, &encrypted_chunk).is_err());
        }

        let mut wrong_file_manifest = manifest.clone();
        wrong_file_manifest.file_id = "wrong-file-id".to_string();
        let wrong_file_context = pairwise_context_fixture(
            "aad_bound",
            "aad_bound",
            &wrong_file_manifest,
            "sender:endpoint",
            "recipient:endpoint",
            "pairwise:session",
            &file_hash,
            1_800_000_000,
        );
        assert!(open_file_manifest(&root_key, &wrong_file_context, &encrypted_manifest).is_err());

        let mut wrong_count_manifest = manifest.clone();
        wrong_count_manifest.chunk_count -= 1;
        let wrong_count_context = pairwise_context_fixture(
            "aad_bound",
            "aad_bound",
            &wrong_count_manifest,
            "sender:endpoint",
            "recipient:endpoint",
            "pairwise:session",
            &file_hash,
            1_800_000_000,
        );
        assert!(open_file_manifest(&root_key, &wrong_count_context, &encrypted_manifest).is_err());

        let mut tampered_manifest = encrypted_manifest.clone();
        tampered_manifest.file_aad_digest = general_purpose::URL_SAFE_NO_PAD.encode([0x62u8; 32]);
        assert!(open_file_manifest(&root_key, &context, &tampered_manifest).is_err());
        let mut wrong_suite_chunk = encrypted_chunk.clone();
        wrong_suite_chunk.file_key_suite = "removed-file-key-suite-v1".to_string();
        assert!(open_file_chunk(&root_key, &context, &wrong_suite_chunk).is_err());
        let mut wrong_index_chunk = encrypted_chunk;
        wrong_index_chunk.chunk_index = 1;
        assert!(open_file_chunk(&root_key, &context, &wrong_index_chunk).is_err());
    }

    #[test]
    fn secure_mesh_file_delivery_json_hides_manifest_and_chunk_plaintext() {
        let key = key_fixture();
        let manifest = SecureMeshFileManifest {
            file_id: "file-sensitive-id-canary".to_string(),
            file_name: "user-tax-return-secret-canary.pdf".to_string(),
            mime_type: "application/x-secret-canary".to_string(),
            relative_path: "private/folder/secret-path-canary".to_string(),
            total_size: 40,
            chunk_size: 40,
            chunk_count: 1,
        };
        let encrypted_manifest = seal_file_manifest(
            &key,
            &context_fixture("manifest", "msg_manifest", &manifest),
            &manifest,
        )
        .unwrap();
        let chunk = SecureMeshFileChunk {
            file_id: manifest.file_id.clone(),
            chunk_index: 0,
            bytes: b"file-body-plaintext-secret-canary-content".to_vec(),
        };
        let encrypted_chunk = seal_file_chunk(
            &key,
            &context_fixture("chunk", "msg_chunk", &manifest),
            &chunk,
        )
        .unwrap();

        let manifest_delivery = file_manifest_delivery_json(&encrypted_manifest);
        let chunk_delivery = file_chunk_delivery_json(&encrypted_chunk);
        assert_eq!(manifest_delivery["metadataEncrypted"], true);
        assert_eq!(manifest_delivery["bodyRedacted"], true);
        assert_eq!(chunk_delivery["metadataEncrypted"], true);
        assert_eq!(chunk_delivery["bodyRedacted"], true);

        let serialized = serde_json::to_string(&json!({
            "manifest": manifest_delivery,
            "chunk": chunk_delivery
        }))
        .unwrap();
        for forbidden in [
            "file-sensitive-id-canary",
            "user-tax-return-secret-canary.pdf",
            "application/x-secret-canary",
            "secret-path-canary",
            "file-body-plaintext-secret-canary-content",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "server-visible file delivery leaked {forbidden}"
            );
        }
        assert!(serialized.contains("fileIdHash"));
        assert!(serialized.contains("ciphertextHash"));
        assert!(serialized.contains("ciphertextSize"));
    }

    #[test]
    fn secure_mesh_file_chunk_rejects_corrupted_ciphertext_hash() {
        let key = key_fixture();
        let chunk = SecureMeshFileChunk {
            file_id: "file_test".to_string(),
            chunk_index: 1,
            bytes: b"chunk".to_vec(),
        };
        let manifest = manifest_fixture();
        let context = context_fixture("chunk_1", "msg_chunk_1", &manifest);
        let mut encrypted = seal_file_chunk(&key, &context, &chunk).unwrap();
        encrypted.ciphertext_hash = "sha256:tampered".to_string();
        let error = open_file_chunk(&key, &context, &encrypted).unwrap_err();
        assert!(error.to_string().contains("ciphertext hash mismatch"));
    }

    #[test]
    fn secure_mesh_file_chunk_rejects_tampered_or_legacy_chunk_hash() {
        let key = key_fixture();
        let chunk = SecureMeshFileChunk {
            file_id: "file_test".to_string(),
            chunk_index: 1,
            bytes: b"chunk".to_vec(),
        };
        let manifest = manifest_fixture();
        let context = context_fixture("chunk_hash_1", "msg_chunk_hash_1", &manifest);
        let encrypted = seal_file_chunk(&key, &context, &chunk).unwrap();

        let mut tampered = encrypted.clone();
        tampered.chunk_hash = format!(
            "hmac-sha256:{}",
            general_purpose::URL_SAFE_NO_PAD.encode([0xA5; 32])
        );
        assert!(open_file_chunk(&key, &context, &tampered).is_err());

        let mut legacy = encrypted;
        legacy.chunk_hash = hash_bytes(chunk.bytes.as_slice());
        let error = open_file_chunk(&key, &context, &legacy).unwrap_err();
        assert!(error.to_string().contains("algorithm is unsupported"));
    }

    #[test]
    fn secure_mesh_file_manifest_rejects_path_traversal() {
        let key = key_fixture();
        let mut manifest = manifest_fixture();
        manifest.relative_path = "../secrets".to_string();
        let error = seal_file_manifest(
            &key,
            &context_fixture("manifest", "msg_manifest", &manifest),
            &manifest,
        )
        .unwrap_err();
        assert!(error.to_string().contains("must not traverse"));
    }

    #[test]
    fn secure_mesh_file_transfer_tracks_resume_ack_and_purge_state() {
        let key = key_fixture();
        let manifest = manifest_fixture();
        let mut state = start_file_transfer(&manifest).unwrap();
        let chunks = encrypted_chunks_fixture(&key, &manifest);

        let report = record_file_chunk_receipt(&mut state, &chunks[0]).unwrap();
        assert_eq!(report.received_chunk_count, 1);
        assert_eq!(report.missing_chunk_indices, vec![1, 2]);
        assert!(!report.complete);

        let report = record_file_chunk_receipt(&mut state, &chunks[2]).unwrap();
        assert_eq!(report.missing_chunk_indices, vec![1]);
        assert!(!report.ack_required);

        let duplicate = record_file_chunk_receipt(&mut state, &chunks[2]).unwrap();
        assert_eq!(duplicate.missing_chunk_indices, vec![1]);

        let complete = record_file_chunk_receipt(&mut state, &chunks[1]).unwrap();
        assert!(complete.complete);
        assert!(complete.ack_required);
        assert!(!complete.purge_local_ciphertext);

        let acknowledged =
            acknowledge_file_transfer(&mut state, "2026-01-01T00:01:00.000Z").unwrap();
        assert!(acknowledged.complete);
        assert!(!acknowledged.ack_required);
        assert!(acknowledged.purge_local_ciphertext);
    }

    #[test]
    fn secure_mesh_file_transfer_queue_is_bounded_confirmed_and_purged() {
        let key = key_fixture();
        let manifest = manifest_fixture();
        let chunks = encrypted_chunks_fixture(&key, &manifest);
        let total_ciphertext_bytes = chunks
            .iter()
            .map(|chunk| chunk.sealed.ciphertext_size)
            .sum::<usize>();
        let mut queue = SecureMeshFileTransferQueue::new(1, total_ciphertext_bytes).unwrap();
        let transfer_id = queue
            .enqueue(&manifest, "recipient:endpoint:queue")
            .unwrap();
        assert!(
            queue
                .enqueue(&manifest, "recipient:endpoint:second")
                .unwrap_err()
                .to_string()
                .contains("queue is full")
        );
        for chunk in &chunks {
            queue.record_chunk(&transfer_id, chunk).unwrap();
        }
        let duplicate = queue.record_chunk(&transfer_id, &chunks[0]).unwrap();
        assert!(duplicate.complete);
        assert!(
            queue
                .acknowledge(&transfer_id, "2026-01-01T00:01:00.000Z")
                .unwrap_err()
                .to_string()
                .contains("receive confirmation")
        );
        queue.confirm_receive(&transfer_id).unwrap();
        let acknowledged = queue
            .acknowledge(&transfer_id, "2026-01-01T00:01:01.000Z")
            .unwrap();
        assert!(acknowledged.purge_local_ciphertext);
        assert_eq!(
            queue.purge_acknowledged(&transfer_id).unwrap(),
            total_ciphertext_bytes
        );
        let status = queue.redacted_status();
        assert_eq!(status["activeTransferCount"], 0);
        assert_eq!(status["queuedCiphertextBytes"], 0);
        let serialized = serde_json::to_string(&status).unwrap();
        assert!(!serialized.contains(&manifest.file_id));
        assert!(!serialized.contains("recipient:endpoint:queue"));
    }

    #[test]
    fn secure_mesh_file_transfer_queue_rejects_ciphertext_byte_overflow_without_mutation() {
        let key = key_fixture();
        let manifest = manifest_fixture();
        let chunks = encrypted_chunks_fixture(&key, &manifest);
        let mut queue =
            SecureMeshFileTransferQueue::new(1, chunks[0].sealed.ciphertext_size.saturating_sub(1))
                .unwrap();
        let transfer_id = queue
            .enqueue(&manifest, "recipient:endpoint:bounded")
            .unwrap();
        assert!(
            queue
                .record_chunk(&transfer_id, &chunks[0])
                .unwrap_err()
                .to_string()
                .contains("ciphertext-byte bound exceeded")
        );
        let status = queue.redacted_status();
        assert_eq!(status["queuedCiphertextBytes"], 0);
        assert_eq!(status["activeTransferCount"], 1);
    }

    #[test]
    fn secure_mesh_file_transfer_rejects_conflicting_duplicate_chunk() {
        let key = key_fixture();
        let manifest = manifest_fixture();
        let mut state = start_file_transfer(&manifest).unwrap();
        let chunks = encrypted_chunks_fixture(&key, &manifest);
        record_file_chunk_receipt(&mut state, &chunks[0]).unwrap();

        let mut conflicting = chunks[0].clone();
        conflicting.ciphertext_hash = "sha256:conflicting".to_string();
        let error = record_file_chunk_receipt(&mut state, &conflicting).unwrap_err();
        assert!(error.to_string().contains("conflicting hash"));
    }

    #[test]
    fn secure_mesh_file_transfer_rejects_manifest_chunk_count_mismatch() {
        let mut manifest = manifest_fixture();
        manifest.total_size = 25;
        let error = start_file_transfer(&manifest).unwrap_err();
        assert!(error.to_string().contains("chunk count does not match"));
    }

    #[test]
    fn secure_mesh_file_route_json_uses_default_route_without_metadata_leak() {
        let manifest = manifest_fixture();
        let route = evaluate_file_route_json(&json!({
            "manifest": manifest_json(&manifest)
        }))
        .unwrap();
        assert_eq!(
            route["route"]["uploadOperation"],
            "secure_mesh.file_chunk.upload"
        );
        assert_eq!(
            route["route"]["fetchOperation"],
            "secure_mesh.file_chunk.fetch"
        );
        assert_eq!(route["route"]["metadataEncrypted"], true);
        assert_eq!(route["transfer"]["chunkCount"], manifest.chunk_count);
        let serialized = serde_json::to_string(&route).unwrap();
        assert!(!serialized.contains(&manifest.file_name));
        assert!(!serialized.contains(&manifest.mime_type));
        assert!(!serialized.contains(&manifest.relative_path));
    }

    #[test]
    fn secure_mesh_file_receive_destination_redacts_local_paths_and_metadata() {
        let manifest = SecureMeshFileManifest {
            file_id: "file-receive-policy-canary".to_string(),
            file_name: "settlement-private-file-canary.xlsx".to_string(),
            mime_type: "application/x-private-spreadsheet-canary".to_string(),
            relative_path: "approved/subdir/private-relative-canary".to_string(),
            total_size: 16,
            chunk_size: 8,
            chunk_count: 2,
        };
        let approved_root = std::env::temp_dir()
            .join("lico-approved-root-canary")
            .join(uuid::Uuid::new_v4().to_string());
        let decision = evaluate_file_receive_destination_json(&json!({
            "manifest": manifest_json(&manifest),
            "approvedRoot": approved_root.to_string_lossy(),
            "conflictPolicy": "fail_if_exists"
        }))
        .unwrap();

        assert_eq!(decision["receivePolicy"]["destinationApproved"], true);
        assert_eq!(decision["receivePolicy"]["destinationPathRedacted"], true);
        assert_eq!(
            decision["receivePolicy"]["conflictPolicy"],
            "fail_if_exists"
        );
        assert_eq!(decision["manifest"]["metadataEncrypted"], true);
        assert_eq!(decision["manifest"]["bodyRedacted"], true);
        let serialized = serde_json::to_string(&decision).unwrap();
        for forbidden in [
            "file-receive-policy-canary",
            "settlement-private-file-canary.xlsx",
            "application/x-private-spreadsheet-canary",
            "private-relative-canary",
            "lico-approved-root-canary",
            approved_root.to_string_lossy().as_ref(),
        ] {
            assert!(
                !serialized.contains(forbidden),
                "receive destination decision leaked {forbidden}"
            );
        }
        assert!(serialized.contains("approvedRootHash"));
        assert!(serialized.contains("resolvedPathHash"));
    }

    #[test]
    fn secure_mesh_file_receive_destination_rejects_unapproved_paths() {
        let mut manifest = manifest_fixture();
        manifest.file_name = "../evil.txt".to_string();
        let rejected_name = evaluate_file_receive_destination_json(&json!({
            "manifest": manifest_json(&manifest),
            "approvedRoot": std::env::temp_dir().to_string_lossy()
        }))
        .unwrap_err();
        assert!(rejected_name.to_string().contains("path separators"));

        let mut manifest = manifest_fixture();
        manifest.relative_path = "safe/../../escape".to_string();
        let rejected_traversal = evaluate_file_receive_destination_json(&json!({
            "manifest": manifest_json(&manifest),
            "approvedRoot": std::env::temp_dir().to_string_lossy()
        }))
        .unwrap_err();
        assert!(rejected_traversal.to_string().contains("must not traverse"));

        let rejected_root = evaluate_file_receive_destination_json(&json!({
            "manifest": manifest_json(&manifest_fixture()),
            "approvedRoot": "relative-root"
        }))
        .unwrap_err();
        assert!(rejected_root.to_string().contains("must be absolute"));
    }

    #[test]
    fn secure_mesh_file_receive_confirmation_requires_user_action_and_disables_auto_open() {
        let manifest = SecureMeshFileManifest {
            file_id: "file-confirmation-policy-canary".to_string(),
            file_name: "private-confirmation-file-canary.pdf".to_string(),
            mime_type: "application/x-confirmation-canary".to_string(),
            relative_path: "phone/private-confirmation-relative-canary".to_string(),
            total_size: 16,
            chunk_size: 8,
            chunk_count: 2,
        };
        let approved_root = std::env::temp_dir()
            .join("lico-confirmation-approved-root-canary")
            .join(uuid::Uuid::new_v4().to_string());
        let pending = evaluate_file_receive_confirmation_json(&json!({
            "manifest": manifest_json(&manifest),
            "approvedRoot": approved_root.to_string_lossy()
        }))
        .unwrap();

        assert_eq!(pending["receiveConfirmation"]["required"], true);
        assert_eq!(
            pending["receiveConfirmation"]["userVisibleConfirmationRequired"],
            true
        );
        assert_eq!(pending["receiveConfirmation"]["userConfirmed"], false);
        assert_eq!(pending["receiveConfirmation"]["writeAllowed"], false);
        assert_eq!(
            pending["receiveConfirmation"]["localWriteDeferredUntilConfirmed"],
            true
        );
        assert_eq!(
            pending["receiveConfirmation"]["decryptedBytesHiddenUntilConfirmed"],
            true
        );
        assert_eq!(pending["receiveConfirmation"]["autoPreviewEnabled"], false);
        assert_eq!(
            pending["receiveConfirmation"]["autoIngestionEnabled"],
            false
        );

        let confirmed = evaluate_file_receive_confirmation_json(&json!({
            "manifest": manifest_json(&manifest),
            "approvedRoot": approved_root.to_string_lossy(),
            "userConfirmed": true
        }))
        .unwrap();
        assert_eq!(confirmed["receiveConfirmation"]["userConfirmed"], true);
        assert_eq!(confirmed["receiveConfirmation"]["writeAllowed"], true);
        assert_eq!(
            confirmed["receiveConfirmation"]["autoPreviewEnabled"],
            false
        );
        assert_eq!(
            confirmed["receiveConfirmation"]["autoIngestionEnabled"],
            false
        );

        let rejected_preview = evaluate_file_receive_confirmation_json(&json!({
            "manifest": manifest_json(&manifest),
            "approvedRoot": approved_root.to_string_lossy(),
            "autoPreview": true
        }))
        .unwrap_err();
        assert!(rejected_preview.to_string().contains("auto-preview"));

        let rejected_ingestion = evaluate_file_receive_confirmation_json(&json!({
            "manifest": manifest_json(&manifest),
            "approvedRoot": approved_root.to_string_lossy(),
            "autoIngestion": true
        }))
        .unwrap_err();
        assert!(rejected_ingestion.to_string().contains("auto-ingestion"));

        let serialized = serde_json::to_string(&json!({
            "pending": pending,
            "confirmed": confirmed
        }))
        .unwrap();
        for forbidden in [
            "file-confirmation-policy-canary",
            "private-confirmation-file-canary.pdf",
            "application/x-confirmation-canary",
            "private-confirmation-relative-canary",
            "lico-confirmation-approved-root-canary",
            approved_root.to_string_lossy().as_ref(),
        ] {
            assert!(
                !serialized.contains(forbidden),
                "receive confirmation leaked {forbidden}"
            );
        }
    }

    #[test]
    fn secure_mesh_file_handoff_proof_reseals_endpoint_specific_ciphertext() {
        let proof = evaluate_file_handoff_proof_json(&json!({})).unwrap();
        assert_eq!(proof["ok"], true);
        assert_eq!(proof["sourceOpenedByDesktop"], true);
        assert_eq!(proof["recipientOpenedResealed"], true);
        assert_eq!(proof["wrongRecipientRejected"], true);
        assert_eq!(proof["endpointSpecificResealReady"], true);
        assert_eq!(proof["recipientCount"], 2);
        assert_eq!(proof["allRecipientsOpenedResealed"], true);
        assert_eq!(proof["allRecipientsWrongRecipientRejected"], true);
        assert_eq!(proof["allRecipientsEndpointSpecificResealReady"], true);
        assert_eq!(proof["multiRecipientIndependentResealReady"], true);
        assert_eq!(proof["allRecipientTransfersAckPurged"], true);
        assert_eq!(proof["deliveryJsonRedacted"], true);
        assert_eq!(proof["serverVisibleNoPlaintext"], true);
        assert_eq!(proof["routePolicyReady"], true);
        assert_eq!(proof["receiveDestinationPolicyReady"], true);
        assert_eq!(proof["receiveConfirmationPolicyReady"], true);
        assert_eq!(proof["transfer"]["recipientCount"], 2);
        assert_eq!(proof["transfer"]["allRecipientTransfersAckPurged"], true);
        assert_eq!(proof["recipientDeliveries"].as_array().unwrap().len(), 2);

        let serialized = serde_json::to_string(&proof).unwrap();
        for forbidden in [
            "handoff-proof-file-id-private-file-canary",
            "handoff-proof-private-file-canary.pdf",
            "application/x-handoff-private-file-canary",
            "private-relative-canary",
            "file-body-plaintext-secret-canary-content",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "handoff proof leaked {forbidden}"
            );
        }
    }

    #[test]
    fn secure_mesh_file_handoff_proof_reseals_distinct_ciphertext_for_multiple_recipients() {
        let proof = evaluate_file_handoff_proof_json(&json!({
            "recipientEndpoints": [
                "iphone-recipient-endpoint",
                "android-recipient-endpoint"
            ]
        }))
        .unwrap();
        assert_eq!(proof["ok"], true);
        assert_eq!(proof["recipientCount"], 2);
        assert_eq!(proof["allRecipientsOpenedResealed"], true);
        assert_eq!(proof["allRecipientsWrongRecipientRejected"], true);
        assert_eq!(proof["allRecipientsEndpointSpecificResealReady"], true);
        assert_eq!(proof["multiRecipientIndependentResealReady"], true);
        assert_eq!(proof["allRecipientTransfersAckPurged"], true);
        assert_eq!(proof["serverVisibleNoPlaintext"], true);

        let deliveries = proof["recipientDeliveries"].as_array().unwrap();
        assert_eq!(deliveries.len(), 2);
        assert_ne!(
            deliveries[0]["resealedManifestCiphertextHash"],
            deliveries[1]["resealedManifestCiphertextHash"]
        );
        assert_ne!(
            deliveries[0]["resealedChunkCiphertextHash"],
            deliveries[1]["resealedChunkCiphertextHash"]
        );
        for delivery in deliveries {
            assert_eq!(delivery["recipientOpenedResealed"], true);
            assert_eq!(delivery["wrongRecipientRejected"], true);
            assert_eq!(delivery["endpointSpecificResealReady"], true);
            assert_eq!(delivery["transferAckPurged"], true);
        }

        let serialized = serde_json::to_string(&proof).unwrap();
        for forbidden in [
            "handoff-proof-file-id-private-file-canary",
            "handoff-proof-private-file-canary.pdf",
            "application/x-handoff-private-file-canary",
            "private-relative-canary",
            "file-body-plaintext-secret-canary-content",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "multi-recipient handoff proof leaked {forbidden}"
            );
        }
    }

    #[test]
    fn secure_mesh_file_key_wraps_through_pairwise_session_before_file_open() {
        let (mut alice_session, mut bob_session) = pairwise_file_sessions();
        let file_key_bytes = [41u8; 32];
        let file_key = FileRootKey::from_bytes(file_key_bytes);
        let wrap_secret = FileKeyWrapSecret::from_bytes([42u8; 32]);
        let manifest = SecureMeshFileManifest {
            file_id: "file-key-wrap-integration".to_string(),
            file_name: "pairwise-wrapped-file.txt".to_string(),
            mime_type: "text/plain".to_string(),
            relative_path: "pairwise/wrapped".to_string(),
            total_size: 25,
            chunk_size: 25,
            chunk_count: 1,
        };
        let chunk = SecureMeshFileChunk {
            file_id: manifest.file_id.clone(),
            chunk_index: 0,
            bytes: b"pairwise sealed file bytes".to_vec(),
        };
        let file_hash = hash_bytes(&chunk.bytes);
        let manifest_context = pairwise_file_protection_context(
            &alice_session,
            "env_file_manifest_pairwise_wrapped",
            "msg_file_manifest_pairwise_wrapped",
            &manifest,
            &file_hash,
        );
        let chunk_context = pairwise_file_protection_context(
            &alice_session,
            "env_file_chunk_pairwise_wrapped",
            "msg_file_chunk_pairwise_wrapped",
            &manifest,
            &file_hash,
        );
        let encrypted_manifest =
            seal_file_manifest(&file_key, &manifest_context, &manifest).unwrap();
        let encrypted_chunk = seal_file_chunk(&file_key, &chunk_context, &chunk).unwrap();

        let key_wrap_context = pairwise_file_protection_context(
            &alice_session,
            "env_file_key_pairwise_wrapped",
            "msg_file_key_pairwise_wrapped",
            &manifest,
            &file_hash,
        );
        let wrapped_file_key =
            seal_file_root_key_for_pairwise_device(&file_key, &wrap_secret, &key_wrap_context)
                .unwrap();
        let key_wrap_body = wrapped_file_key.to_json().unwrap().into_bytes();
        let key_envelope = alice_session
            .seal_payload_envelope(
                key_wrap_context.content_context(),
                &SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, key_wrap_body)
                    .with_content_type(SECURE_MESH_FILE_KEY_ENVELOPE_CONTENT_TYPE),
            )
            .unwrap();
        let opened_key = bob_session
            .open_payload_envelope(&key_envelope, SecureMeshPayloadKind::Command)
            .unwrap();
        assert_eq!(
            opened_key.content_type.as_deref(),
            Some(SECURE_MESH_FILE_KEY_ENVELOPE_CONTENT_TYPE)
        );
        let wrapped_file_key =
            FileKeyEnvelope::from_json(std::str::from_utf8(&opened_key.body).unwrap()).unwrap();
        let recovered_key = open_file_root_key_for_pairwise_device(
            &wrapped_file_key,
            &wrap_secret,
            &key_wrap_context,
            1_700_000_000,
        )
        .unwrap();

        let opened_manifest =
            open_file_manifest(&recovered_key, &manifest_context, &encrypted_manifest).unwrap();
        let opened_chunk =
            open_file_chunk(&recovered_key, &chunk_context, &encrypted_chunk).unwrap();
        assert_eq!(opened_manifest, manifest);
        assert_eq!(opened_chunk, chunk);

        let replay_error = bob_session
            .open_payload_envelope(&key_envelope, SecureMeshPayloadKind::Command)
            .unwrap_err();
        assert!(replay_error.to_string().contains("replay"));
    }

    #[test]
    fn secure_mesh_file_key_wraps_out_of_order_and_revocation_fails_closed() {
        let (mut alice_session, mut bob_session) = pairwise_file_sessions();
        let first_key_bytes = [51u8; 32];
        let second_key_bytes = [52u8; 32];
        let first = encrypted_pairwise_file_fixture(
            &alice_session,
            "first",
            first_key_bytes,
            b"first out-of-order file",
        );
        let second = encrypted_pairwise_file_fixture(
            &alice_session,
            "second",
            second_key_bytes,
            b"second out-of-order file",
        );

        let first_envelope = pairwise_file_key_envelope(&mut alice_session, &first);
        let second_envelope = pairwise_file_key_envelope(&mut alice_session, &second);

        let second_opened = bob_session
            .open_payload_envelope(&second_envelope, SecureMeshPayloadKind::Command)
            .unwrap();
        assert_eq!(bob_session.skipped_key_count(), 1);
        let second_recovered = recovered_file_root_key(&second_opened.body, &second);
        assert_eq!(
            open_file_chunk(
                &second_recovered,
                &second.chunk_context,
                &second.encrypted_chunk
            )
            .unwrap()
            .bytes,
            second.chunk.bytes
        );

        let first_opened = bob_session
            .open_payload_envelope(&first_envelope, SecureMeshPayloadKind::Command)
            .unwrap();
        assert_eq!(bob_session.skipped_key_count(), 0);
        let first_recovered = recovered_file_root_key(&first_opened.body, &first);
        assert_eq!(
            open_file_chunk(
                &first_recovered,
                &first.chunk_context,
                &first.encrypted_chunk
            )
            .unwrap()
            .bytes,
            first.chunk.bytes
        );

        let revoked =
            encrypted_pairwise_file_fixture(&alice_session, "revoked", [53u8; 32], b"revoked file");
        let revoked_envelope = pairwise_file_key_envelope(&mut alice_session, &revoked);
        bob_session.revoke();
        let revoked_error = bob_session
            .open_payload_envelope(&revoked_envelope, SecureMeshPayloadKind::Command)
            .unwrap_err();
        assert!(revoked_error.to_string().contains("revoked"));
    }

    fn manifest_fixture() -> SecureMeshFileManifest {
        SecureMeshFileManifest {
            file_id: "file_test".to_string(),
            file_name: "quarterly-plan.pdf".to_string(),
            mime_type: "application/pdf".to_string(),
            relative_path: "workspace/reports".to_string(),
            total_size: 24,
            chunk_size: 8,
            chunk_count: 3,
        }
    }

    fn manifest_json(manifest: &SecureMeshFileManifest) -> Value {
        json!({
            "fileId": &manifest.file_id,
            "fileName": &manifest.file_name,
            "mimeType": &manifest.mime_type,
            "relativePath": &manifest.relative_path,
            "totalSize": manifest.total_size,
            "chunkSize": manifest.chunk_size,
            "chunkCount": manifest.chunk_count
        })
    }

    fn encrypted_chunks_fixture(
        key: &FileRootKey,
        manifest: &SecureMeshFileManifest,
    ) -> Vec<EncryptedSecureMeshFileChunk> {
        (0..manifest.chunk_count)
            .map(|index| {
                let chunk = SecureMeshFileChunk {
                    file_id: manifest.file_id.clone(),
                    chunk_index: index,
                    bytes: vec![index as u8; manifest.chunk_size as usize],
                };
                seal_file_chunk(
                    key,
                    &context_fixture(
                        &format!("chunk_{index}"),
                        &format!("msg_chunk_{index}"),
                        manifest,
                    ),
                    &chunk,
                )
                .unwrap()
            })
            .collect()
    }

    fn context_fixture(
        envelope: &str,
        message: &str,
        manifest: &SecureMeshFileManifest,
    ) -> SecureMeshFileProtectionContext {
        pairwise_context_fixture(
            envelope,
            message,
            manifest,
            "desktop_gui:alpha",
            "mobile:beta",
            "file_session_test",
            &hash_bytes(format!("fixture-file-hash:{}", manifest.file_id).as_bytes()),
            1_800_000_000,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn pairwise_context_fixture(
        envelope: &str,
        message: &str,
        manifest: &SecureMeshFileManifest,
        sender_endpoint_id: &str,
        recipient_endpoint_id: &str,
        session_id: &str,
        file_hash: &str,
        expires_at_unix_seconds: u64,
    ) -> SecureMeshFileProtectionContext {
        SecureMeshFileProtectionContext::for_pairwise_device(
            SecureMeshContentContext::new(
                format!("env_{envelope}"),
                message,
                "mailbox_file",
                sender_endpoint_id,
                recipient_endpoint_id,
                session_id,
                "2026-01-01T00:00:00.000Z",
                "2026-01-01T00:10:00.000Z",
            ),
            manifest.file_id.clone(),
            manifest.chunk_count,
            file_hash,
            expires_at_unix_seconds,
        )
        .unwrap()
    }

    #[allow(clippy::too_many_arguments)]
    fn mls_context_fixture(
        envelope: &str,
        message: &str,
        manifest: &SecureMeshFileManifest,
        sender_endpoint_id: &str,
        recipient_endpoint_id: &str,
        session_id: &str,
        file_hash: &str,
        group_id: &str,
        epoch: u64,
        expires_at_unix_seconds: u64,
    ) -> SecureMeshFileProtectionContext {
        SecureMeshFileProtectionContext::for_mls_epoch(
            SecureMeshContentContext::new(
                format!("env_{envelope}"),
                message,
                "mailbox_file",
                sender_endpoint_id,
                recipient_endpoint_id,
                session_id,
                "2026-01-01T00:00:00.000Z",
                "2026-01-01T00:10:00.000Z",
            ),
            manifest.file_id.clone(),
            manifest.chunk_count,
            file_hash,
            group_id,
            epoch,
            expires_at_unix_seconds,
        )
        .unwrap()
    }

    fn key_fixture() -> FileRootKey {
        FileRootKey::from_bytes([23; 32])
    }

    struct PairwiseFileEndpoint {
        identity: DeviceTrustPublicIdentity,
        identity_secret: SecureMeshPairwisePrivateKey,
        signing_key: SigningKey,
    }

    struct PairwiseFilePrekeys {
        signed_secret: SecureMeshPairwisePrivateKey,
        one_time_secret: SecureMeshPairwisePrivateKey,
        one_time_mlkem1024_prekey_seed: SecureMeshMlKem1024PreKeySeed,
        bundle: SecureMeshPairwisePreKeyBundle,
    }

    fn pairwise_file_sessions() -> (SecureMeshPairwiseSession, SecureMeshPairwiseSession) {
        let alice = pairwise_file_endpoint("desktop_gui:file-wrap-alice");
        let bob = pairwise_file_endpoint("mobile:file-wrap-bob");
        let bob_prekeys = pairwise_file_prekeys(&bob);
        let bob_directory = authorize_test_pairwise_prekey_bundle(&bob_prekeys.bundle);
        let now = OffsetDateTime::parse("2026-06-26T00:00:01Z", &Rfc3339).unwrap();
        let (mut alice_session, intro) = SecureMeshPairwiseSession::initiate(
            &alice.identity,
            &alice.identity_secret,
            &alice.signing_key,
            &bob_prekeys.bundle,
            &bob_directory,
            &SecureMeshPreKeyValidationPolicy::default(),
            &crate::core::secure_mesh_pairwise::secure_mesh_pairwise_test_capability_evaluation()
                .unwrap(),
            now,
        )
        .unwrap();
        let (mut bob_session, accepted) = SecureMeshPairwiseSession::accept(
            &bob.identity,
            &bob.identity_secret,
            &bob.signing_key,
            &alice.identity,
            &bob_prekeys.signed_secret,
            Some(&bob_prekeys.one_time_secret),
            &bob_prekeys.one_time_mlkem1024_prekey_seed,
            &intro,
            &crate::core::secure_mesh_pairwise::secure_mesh_pairwise_test_capability_evaluation()
                .unwrap(),
            now,
            &mut crate::core::secure_mesh_session_negotiation::CapabilityProofReplayGuard::default(
            ),
        )
        .unwrap();
        let finished = alice_session
            .complete_initiator_handshake(
                &alice.identity,
                &bob.identity,
                &accepted,
                now,
                &mut crate::core::secure_mesh_session_negotiation::CapabilityProofReplayGuard::default(),
            )
            .unwrap();
        bob_session.complete_responder_handshake(&finished).unwrap();
        (alice_session, bob_session)
    }

    fn pairwise_file_endpoint(endpoint_id: &str) -> PairwiseFileEndpoint {
        let identity_secret = SecureMeshPairwisePrivateKey::generate();
        let signing_key = SigningKey::generate(&mut OsRng);
        let identity = DeviceTrustPublicIdentity::new(
            endpoint_id,
            identity_secret.public_key(),
            signing_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        PairwiseFileEndpoint {
            identity,
            identity_secret,
            signing_key,
        }
    }

    fn pairwise_file_prekeys(endpoint: &PairwiseFileEndpoint) -> PairwiseFilePrekeys {
        let signed_secret = SecureMeshPairwisePrivateKey::generate();
        let one_time_secret = SecureMeshPairwisePrivateKey::generate();
        let one_time_mlkem1024_prekey_seed = SecureMeshMlKem1024PreKeySeed::generate();
        let signed_prekey = sign_prekey_record(
            &endpoint.signing_key,
            &endpoint.identity,
            SecureMeshPreKeyKind::SignedPreKey,
            "file-wrap-spk-1",
            signed_secret.public_key(),
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        let one_time_prekey = sign_prekey_record(
            &endpoint.signing_key,
            &endpoint.identity,
            SecureMeshPreKeyKind::OneTimePreKey,
            "file-wrap-otpk-1",
            one_time_secret.public_key(),
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        let one_time_mlkem1024_prekey = sign_prekey_record(
            &endpoint.signing_key,
            &endpoint.identity,
            SecureMeshPreKeyKind::OneTimeMlKem1024PreKey,
            "file-wrap-pqotpk-1",
            one_time_mlkem1024_prekey_seed.public_key(),
            "2026-06-26T00:00:00Z",
            "2026-07-26T00:00:00Z",
        )
        .unwrap();
        PairwiseFilePrekeys {
            signed_secret,
            one_time_secret,
            one_time_mlkem1024_prekey_seed,
            bundle: SecureMeshPairwisePreKeyBundle {
                endpoint_identity: endpoint.identity.clone(),
                trust_state: DeviceTrustState::Verified,
                signed_prekey,
                one_time_prekey: Some(one_time_prekey),
                one_time_mlkem1024_prekey,
                prekey_publication_version: 1,
            },
        }
    }

    fn pairwise_file_context(
        session: &SecureMeshPairwiseSession,
        envelope_id: &str,
        message_id: &str,
    ) -> SecureMeshContentContext {
        SecureMeshContentContext::new(
            general_purpose::URL_SAFE_NO_PAD.encode(&Sha256::digest(envelope_id.as_bytes())[..24]),
            message_id,
            general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(b"mailbox_file_key_wrap")),
            session.local_endpoint_id.clone(),
            session.remote_endpoint_id.clone(),
            session.session_id.clone(),
            "2026-01-01T00:00:00.000Z",
            "2026-01-01T00:10:00.000Z",
        )
    }

    fn pairwise_file_protection_context(
        session: &SecureMeshPairwiseSession,
        envelope_id: &str,
        message_id: &str,
        manifest: &SecureMeshFileManifest,
        file_hash: &str,
    ) -> SecureMeshFileProtectionContext {
        SecureMeshFileProtectionContext::for_pairwise_device(
            pairwise_file_context(session, envelope_id, message_id),
            manifest.file_id.clone(),
            manifest.chunk_count,
            file_hash,
            1_800_000_000,
        )
        .unwrap()
    }

    struct EncryptedPairwiseFileFixture {
        root_key_bytes: [u8; FILE_ROOT_KEY_BYTES],
        wrap_secret_bytes: [u8; FILE_KEY_WRAP_SECRET_BYTES],
        chunk: SecureMeshFileChunk,
        encrypted_chunk: EncryptedSecureMeshFileChunk,
        chunk_context: SecureMeshFileProtectionContext,
        key_context: SecureMeshFileProtectionContext,
    }

    fn encrypted_pairwise_file_fixture(
        session: &SecureMeshPairwiseSession,
        label: &str,
        key_bytes: [u8; 32],
        bytes: &[u8],
    ) -> EncryptedPairwiseFileFixture {
        let key = FileRootKey::from_bytes(key_bytes);
        let manifest = SecureMeshFileManifest {
            file_id: format!("file-key-wrap-out-of-order-{label}"),
            file_name: format!("pairwise-wrapped-{label}.txt"),
            mime_type: "text/plain".to_string(),
            relative_path: format!("pairwise/wrapped/{label}"),
            total_size: bytes.len() as u64,
            chunk_size: bytes.len().try_into().unwrap(),
            chunk_count: 1,
        };
        let file_hash = hash_bytes(bytes);
        let manifest_context = pairwise_file_protection_context(
            session,
            &format!("env_file_manifest_out_of_order_{label}"),
            &format!("msg_file_manifest_out_of_order_{label}"),
            &manifest,
            &file_hash,
        );
        let encrypted_manifest = seal_file_manifest(&key, &manifest_context, &manifest).unwrap();
        assert_eq!(
            open_file_manifest(&key, &manifest_context, &encrypted_manifest).unwrap(),
            manifest
        );
        let chunk = SecureMeshFileChunk {
            file_id: manifest.file_id.clone(),
            chunk_index: 0,
            bytes: bytes.to_vec(),
        };
        let chunk_context = pairwise_file_protection_context(
            session,
            &format!("env_file_chunk_out_of_order_{label}"),
            &format!("msg_file_chunk_out_of_order_{label}"),
            &manifest,
            &file_hash,
        );
        let encrypted_chunk = seal_file_chunk(&key, &chunk_context, &chunk).unwrap();
        let key_context = pairwise_file_protection_context(
            session,
            &format!("env_file_key_out_of_order_{label}"),
            &format!("msg_file_key_out_of_order_{label}"),
            &manifest,
            &file_hash,
        );
        EncryptedPairwiseFileFixture {
            root_key_bytes: key_bytes,
            wrap_secret_bytes: [key_bytes[0].wrapping_add(64); FILE_KEY_WRAP_SECRET_BYTES],
            chunk,
            encrypted_chunk,
            chunk_context,
            key_context,
        }
    }

    fn pairwise_file_key_envelope(
        session: &mut SecureMeshPairwiseSession,
        fixture: &EncryptedPairwiseFileFixture,
    ) -> crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope {
        let root_key = FileRootKey::from_bytes(fixture.root_key_bytes);
        let wrap_secret = FileKeyWrapSecret::from_bytes(fixture.wrap_secret_bytes);
        let file_key_envelope =
            seal_file_root_key_for_pairwise_device(&root_key, &wrap_secret, &fixture.key_context)
                .unwrap();
        let body = file_key_envelope.to_json().unwrap().into_bytes();
        session
            .seal_payload_envelope(
                fixture.key_context.content_context(),
                &SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, body)
                    .with_content_type(SECURE_MESH_FILE_KEY_ENVELOPE_CONTENT_TYPE),
            )
            .unwrap()
    }

    fn recovered_file_root_key(body: &[u8], fixture: &EncryptedPairwiseFileFixture) -> FileRootKey {
        let envelope = FileKeyEnvelope::from_json(std::str::from_utf8(body).unwrap()).unwrap();
        open_file_root_key_for_pairwise_device(
            &envelope,
            &FileKeyWrapSecret::from_bytes(fixture.wrap_secret_bytes),
            &fixture.key_context,
            1_700_000_000,
        )
        .unwrap()
    }
}
