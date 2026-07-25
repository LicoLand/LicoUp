//! Owner-private digest-bound workflow artifacts.
//!
//! Handles and digests may cross the control plane. Artifact bytes stay under
//! the orchestrator state root and are never journaled.

use anyhow::{Result, anyhow};
use sha2::{Digest, Sha256};
#[cfg(test)]
use std::fs;
use std::path::{Path, PathBuf};

use super::super::file_security;

const MAX_ARTIFACT_BYTES: usize = 1024 * 1024;
const MAX_HANDLE_BYTES: usize = 128;

#[derive(Clone, Debug)]
pub struct PrivateArtifactStore {
    root: PathBuf,
}

impl PrivateArtifactStore {
    pub fn open(state_root: &Path) -> Result<Self> {
        let root = state_root.join("artifacts");
        file_security::ensure_private_dir(&root)?;
        Ok(Self { root })
    }

    pub fn put(&self, handle: &str, bytes: &[u8]) -> Result<String> {
        validate_handle(handle)?;
        if bytes.len() > MAX_ARTIFACT_BYTES {
            return Err(anyhow!("artifact_too_large"));
        }
        let text = std::str::from_utf8(bytes).map_err(|_| anyhow!("artifact_not_utf8"))?;
        let digest = format!("{:x}", Sha256::digest(bytes));
        file_security::atomic_write_private_text_bounded(
            &self.path_for(handle)?,
            text,
            MAX_ARTIFACT_BYTES,
        )?;
        Ok(digest)
    }

    pub fn put_text(&self, handle: &str, text: &str) -> Result<String> {
        self.put(handle, text.as_bytes())
    }

    pub fn read_verified(&self, handle: &str, expected_digest: &str) -> Result<Vec<u8>> {
        validate_handle(handle)?;
        let expected = normalize_digest(expected_digest)?;
        let text =
            file_security::read_private_text_bounded(&self.path_for(handle)?, MAX_ARTIFACT_BYTES)?
                .ok_or_else(|| anyhow!("artifact_unavailable"))?;
        let bytes = text.into_bytes();
        let actual = format!("{:x}", Sha256::digest(&bytes));
        if actual != expected {
            return Err(anyhow!("artifact_digest_mismatch"));
        }
        Ok(bytes)
    }

    fn path_for(&self, handle: &str) -> Result<PathBuf> {
        Ok(self.root.join(format!("{handle}.txt")))
    }
}

fn validate_handle(handle: &str) -> Result<()> {
    if handle.is_empty()
        || handle.len() > MAX_HANDLE_BYTES
        || handle.contains('/')
        || handle.contains('\\')
        || !handle
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return Err(anyhow!("invalid_artifact_handle"));
    }
    Ok(())
}

fn normalize_digest(value: &str) -> Result<String> {
    let hex = value.strip_prefix("sha256:").unwrap_or(value);
    if hex.len() != 64 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(anyhow!("invalid_artifact_digest"));
    }
    Ok(hex.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_and_read_round_trip_verifies_digest() {
        let root = std::env::temp_dir().join(format!(
            "lico-artifact-store-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::create_dir_all(&root).unwrap();
        let store = PrivateArtifactStore::open(&root).unwrap();
        let digest = store.put("artifact-input-01", b"hello-plan").unwrap();
        let bytes = store.read_verified("artifact-input-01", &digest).unwrap();
        assert_eq!(bytes, b"hello-plan");
        assert!(
            store
                .read_verified("artifact-input-01", &"b".repeat(64))
                .is_err()
        );
        let _ = fs::remove_dir_all(root);
    }
}
