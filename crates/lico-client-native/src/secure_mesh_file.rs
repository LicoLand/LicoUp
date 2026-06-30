use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::secure_mesh_crypto::{
    ContentKey, SealedSecureMeshPayload, SecureMeshContentContext, SecureMeshPayloadKind,
    SecureMeshPlaintext, open_payload, seal_payload,
};

pub const SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE: &str = "application/v0.0.1:secure-mesh:file-1";
pub const SECURE_MESH_FILE_CHUNK_CONTENT_TYPE: &str = "application/v0.0.1:secure-mesh:file-1";
pub const SECURE_MESH_FILE_CRYPTO_STATUS: &str =
    "file_manifest_chunk_resume_ack_state_default_route_gui_binding_available";
const FILE_MANIFEST_MAGIC: &[u8] = b"LCOSM-FM-v1";
const FILE_CHUNK_MAGIC: &[u8] = b"LCOSM-FC-v1";
const MAX_FILE_NAME_BYTES: usize = 255;
const MAX_MIME_BYTES: usize = 255;
const MAX_RELATIVE_PATH_BYTES: usize = 4096;
const MAX_CHUNK_BYTES: usize = 8 * 1024 * 1024;
const MAX_CHUNK_COUNT: u32 = 100_000;

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
    pub sealed: SealedSecureMeshPayload,
    pub ciphertext_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EncryptedSecureMeshFileChunk {
    pub file_id_hash: String,
    pub chunk_index: u32,
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

pub fn seal_file_manifest(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    manifest: &SecureMeshFileManifest,
) -> Result<EncryptedSecureMeshFileManifest> {
    validate_manifest(manifest)?;
    let sealed = seal_payload(
        key,
        context,
        &SecureMeshPlaintext::new(
            SecureMeshPayloadKind::FileManifest,
            encode_manifest(manifest)?,
        )
        .with_content_type(SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE),
    )?;
    let ciphertext_hash = ciphertext_hash(&sealed)?;
    Ok(EncryptedSecureMeshFileManifest {
        sealed,
        ciphertext_hash,
    })
}

pub fn open_file_manifest(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    encrypted: &EncryptedSecureMeshFileManifest,
) -> Result<SecureMeshFileManifest> {
    ensure!(
        ciphertext_hash(&encrypted.sealed)? == encrypted.ciphertext_hash,
        "secure mesh file manifest ciphertext hash mismatch"
    );
    let opened = open_payload(
        key,
        context,
        &encrypted.sealed,
        SecureMeshPayloadKind::FileManifest,
    )?;
    ensure!(
        opened.content_type.as_deref() == Some(SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE),
        "secure mesh file manifest content type mismatch"
    );
    decode_manifest(&opened.body)
}

pub fn seal_file_chunk(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    chunk: &SecureMeshFileChunk,
) -> Result<EncryptedSecureMeshFileChunk> {
    validate_chunk(chunk)?;
    let sealed = seal_payload(
        key,
        context,
        &SecureMeshPlaintext::new(SecureMeshPayloadKind::FileChunk, encode_chunk(chunk)?)
            .with_content_type(SECURE_MESH_FILE_CHUNK_CONTENT_TYPE),
    )?;
    Ok(EncryptedSecureMeshFileChunk {
        file_id_hash: hash_bytes(chunk.file_id.as_bytes()),
        chunk_index: chunk.chunk_index,
        plaintext_size: chunk.bytes.len(),
        ciphertext_hash: ciphertext_hash(&sealed)?,
        sealed,
    })
}

pub fn open_file_chunk(
    key: &ContentKey,
    context: &SecureMeshContentContext,
    encrypted: &EncryptedSecureMeshFileChunk,
) -> Result<SecureMeshFileChunk> {
    ensure!(
        ciphertext_hash(&encrypted.sealed)? == encrypted.ciphertext_hash,
        "secure mesh file chunk ciphertext hash mismatch"
    );
    let opened = open_payload(
        key,
        context,
        &encrypted.sealed,
        SecureMeshPayloadKind::FileChunk,
    )?;
    ensure!(
        opened.content_type.as_deref() == Some(SECURE_MESH_FILE_CHUNK_CONTENT_TYPE),
        "secure mesh file chunk content type mismatch"
    );
    let chunk = decode_chunk(&opened.body)?;
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
    Ok(chunk)
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
        "fileProtocolVersion": crate::secure_mesh::SECURE_MESH_FILE_PROTOCOL_VERSION,
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

    #[test]
    fn secure_mesh_file_manifest_and_chunk_round_trip_without_outer_metadata_leak() {
        let key = key_fixture();
        let manifest = manifest_fixture();
        let manifest_context = context_fixture("manifest", "msg_manifest");
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
        let chunk_context = context_fixture("chunk_0", "msg_chunk_0");
        let encrypted_chunk = seal_file_chunk(&key, &chunk_context, &chunk).unwrap();
        assert_ne!(
            encrypted_chunk.ciphertext_hash,
            hash_bytes(chunk.bytes.as_slice())
        );
        let opened_chunk = open_file_chunk(&key, &chunk_context, &encrypted_chunk).unwrap();
        assert_eq!(opened_chunk, chunk);
    }

    #[test]
    fn secure_mesh_file_chunk_rejects_corrupted_ciphertext_hash() {
        let key = key_fixture();
        let chunk = SecureMeshFileChunk {
            file_id: "file_test".to_string(),
            chunk_index: 1,
            bytes: b"chunk".to_vec(),
        };
        let context = context_fixture("chunk_1", "msg_chunk_1");
        let mut encrypted = seal_file_chunk(&key, &context, &chunk).unwrap();
        encrypted.ciphertext_hash = "sha256:tampered".to_string();
        let error = open_file_chunk(&key, &context, &encrypted).unwrap_err();
        assert!(error.to_string().contains("ciphertext hash mismatch"));
    }

    #[test]
    fn secure_mesh_file_manifest_rejects_path_traversal() {
        let key = key_fixture();
        let mut manifest = manifest_fixture();
        manifest.relative_path = "../secrets".to_string();
        let error = seal_file_manifest(
            &key,
            &context_fixture("manifest", "msg_manifest"),
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
        key: &ContentKey,
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
                    &context_fixture(&format!("chunk_{index}"), &format!("msg_chunk_{index}")),
                    &chunk,
                )
                .unwrap()
            })
            .collect()
    }

    fn context_fixture(envelope: &str, message: &str) -> SecureMeshContentContext {
        SecureMeshContentContext::new(
            format!("env_{envelope}"),
            message,
            "mailbox_file",
            "desktop_gui:alpha",
            "mobile:beta",
            "file_session_test",
            "2026-01-01T00:00:00.000Z",
            "2026-01-01T00:10:00.000Z",
        )
    }

    fn key_fixture() -> ContentKey {
        ContentKey::from_bytes([23; 32])
    }
}
