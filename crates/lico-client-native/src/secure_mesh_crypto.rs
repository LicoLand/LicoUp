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

use crate::secure_mesh::SECURE_MESH_PROTOCOL_VERSION;

pub const SECURE_MESH_CONTENT_CIPHER_SUITE: &str = "v0.0.1:strategy:secure-file-1:aead-1";
pub const SECURE_MESH_CONTENT_CRYPTO_STATUS: &str = "content_and_file_aead_available_pairwise_session_key_and_mls_group_exporter_payload_codec_available_mls_cross_implementation_interop_verified_reviewed_signal_audit_blocked";

const CONTENT_KEY_LEN: usize = 32;
const CONTENT_NONCE_LEN: usize = 12;
const AAD_HASH_LEN: usize = 32;
const MAX_CONTENT_BYTES: usize = 16 * 1024 * 1024;
const MAX_CONTEXT_FIELD_BYTES: usize = 4096;
const MAX_CONTENT_TYPE_BYTES: usize = 255;
const AAD_MAGIC: &[u8] = b"LCOSM-AAD-v1";
const PLAINTEXT_MAGIC: &[u8] = b"LCOSM-PT-v1";
const HEADER_MAGIC: &[u8] = b"LCOSM-HDR-v1";
const HKDF_SALT_DOMAIN: &[u8] = b"licolite.secure-mesh.payload-aead.hkdf-salt.v1";
const HKDF_INFO_DOMAIN: &[u8] = b"licolite.secure-mesh.payload-aead.hkdf-info.v1";

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
}

impl SecureMeshPayloadKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Command => "command",
            Self::ResultPayload => "result",
            Self::Error => "error",
            Self::FileChunk => "file_chunk",
            Self::FileManifest => "file_manifest",
        }
    }

    fn tag(self) -> u8 {
        match self {
            Self::Command => 1,
            Self::ResultPayload => 2,
            Self::Error => 3,
            Self::FileChunk => 4,
            Self::FileManifest => 5,
        }
    }

    fn from_tag(tag: u8) -> Result<Self> {
        match tag {
            1 => Ok(Self::Command),
            2 => Ok(Self::ResultPayload),
            3 => Ok(Self::Error),
            4 => Ok(Self::FileChunk),
            5 => Ok(Self::FileManifest),
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

pub fn seal_payload(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
) -> Result<SealedSecureMeshPayload> {
    let mut nonce = [0u8; CONTENT_NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    seal_payload_with_nonce(key, context, plaintext, nonce)
}

pub fn open_payload(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    sealed: &SealedSecureMeshPayload,
    expected_kind: SecureMeshPayloadKind,
) -> Result<OpenedSecureMeshPayload> {
    context.validate()?;
    ensure!(
        sealed.protocol_version == SECURE_MESH_PROTOCOL_VERSION,
        "secure mesh payload protocol version is unsupported"
    );
    ensure!(
        sealed.cipher_suite == SECURE_MESH_CONTENT_CIPHER_SUITE,
        "secure mesh payload cipher suite is unsupported"
    );

    let (nonce, aad_hash) = decode_header(&sealed.encrypted_header)?;
    let aad = build_aad(context, expected_kind)?;
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
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            AeadPayload {
                msg: &ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| anyhow!("secure mesh payload authentication failed"))?;
    let opened = decode_plaintext(&plaintext)?;
    ensure!(
        opened.kind == expected_kind,
        "secure mesh payload kind mismatch"
    );
    Ok(opened)
}

fn seal_payload_with_nonce(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
    nonce: [u8; CONTENT_NONCE_LEN],
) -> Result<SealedSecureMeshPayload> {
    context.validate()?;
    validate_plaintext(plaintext)?;
    let aad = build_aad(context, plaintext.kind)?;
    let derived_key = derive_aead_key(key, context, plaintext.kind, &aad)?;
    let encoded_plaintext = encode_plaintext(context, plaintext)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(derived_key.as_slice()));
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            AeadPayload {
                msg: encoded_plaintext.as_slice(),
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

fn validate_context_field(label: &str, value: &str) -> Result<()> {
    let trimmed = value.trim();
    ensure!(
        !trimmed.is_empty(),
        "secure mesh context {label} is required"
    );
    ensure!(
        trimmed.len() <= MAX_CONTEXT_FIELD_BYTES,
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

fn build_aad(context: &SecureMeshContentContext, kind: SecureMeshPayloadKind) -> Result<Vec<u8>> {
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
    Ok(out)
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

fn decode_header(value: &str) -> Result<([u8; CONTENT_NONCE_LEN], [u8; AAD_HASH_LEN])> {
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
    fn secure_mesh_content_crypto_has_stable_test_vector() {
        let context = context_fixture();
        let payload = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::Command,
            br#"{"op":"client.snapshot.request"}"#,
        );
        let sealed = seal_payload_with_nonce(
            &key_fixture(42),
            &context,
            &payload,
            [11u8; CONTENT_NONCE_LEN],
        )
        .unwrap();
        assert_eq!(
            sealed.encrypted_header,
            "TENPU00tSERSLXYxCwsLCwsLCwsLCwsLQq0BMQibXPaDQDSexdRKiihKjgD5Vsl7TYGqCI0zYL4"
        );
        assert_eq!(
            sealed.ciphertext,
            "lSpV0CzNUIAZTo3RZFJiDAKUwG0SF-gUKw_UwFCodgP8Shl5kWHhNy5wnFw2bUX8B_UP_nurW8zhUi767b5uAiev7zJR_rDH6s41K59Yu71q9hhzEusB8yjwWNV69Bzt-RWh3pD422GSgcjRq9h0Fh1B02cUf5dglg"
        );
        assert_eq!(sealed.ciphertext_size, 121);
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
