//! Cross-device skill-sync package transfer over the Secure Mesh file substrate.
//!
//! Seals a skill package as an encrypted file manifest/chunk transfer with
//! `secure_mesh.skill_sync.v1` metadata. Does not claim production evidence;
//! install still requires local confirmation on the receiving client.

use anyhow::{Result, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::secure_mesh_crypto::SecureMeshContentContext;
use super::secure_mesh_file::{
    EncryptedSecureMeshFileChunk, EncryptedSecureMeshFileManifest, FileRootKey,
    SecureMeshFileChunk, SecureMeshFileManifest, SecureMeshFileProtectionContext,
    file_chunk_delivery_json, file_manifest_delivery_json, seal_file_chunk, seal_file_manifest,
};

pub const SECURE_MESH_SKILL_SYNC_PROTOCOL: &str = "secure_mesh.skill_sync.v1";
pub const SECURE_MESH_SKILL_SYNC_CONTENT_TYPE: &str =
    "application/licomesh.secure-mesh.skill-sync.v1+json";

const MAX_PACKAGE_BYTES: usize = 8 * 1024 * 1024;
const DEFAULT_CHUNK_SIZE: u32 = 64 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkillSyncPackageManifest {
    pub skill_id: String,
    pub version: String,
    pub source_agent_id: String,
    pub target_agent_id: String,
    pub package_digest: String,
    pub install_strategy: String,
    pub activate: bool,
    pub file: SecureMeshFileManifest,
}

/// Seal a skill package body for encrypted mesh delivery.
pub fn seal_skill_sync_package(
    root_key: &FileRootKey,
    skill_id: &str,
    version: &str,
    source_agent_id: &str,
    target_agent_id: &str,
    package_bytes: &[u8],
    activate: bool,
) -> Result<(
    SkillSyncPackageManifest,
    EncryptedSecureMeshFileManifest,
    Vec<EncryptedSecureMeshFileChunk>,
)> {
    ensure!(
        !skill_id.trim().is_empty(),
        "skill sync skill id is required"
    );
    ensure!(!version.trim().is_empty(), "skill sync version is required");
    ensure!(
        !package_bytes.is_empty() && package_bytes.len() <= MAX_PACKAGE_BYTES,
        "skill sync package size is out of bounds"
    );
    let package_digest = format!("{:x}", Sha256::digest(package_bytes));
    let chunk_size = DEFAULT_CHUNK_SIZE;
    let chunk_count = package_bytes.len().div_ceil(chunk_size as usize) as u32;
    let file_id = format!("skill-sync-{skill_id}-{version}");
    let file = SecureMeshFileManifest {
        file_id: file_id.clone(),
        file_name: format!("{skill_id}-{version}.skill.pkg"),
        mime_type: SECURE_MESH_SKILL_SYNC_CONTENT_TYPE.to_string(),
        relative_path: format!("skills/{skill_id}/{version}.pkg"),
        total_size: package_bytes.len() as u64,
        chunk_size,
        chunk_count,
    };
    let file_hash = {
        use base64::{Engine as _, engine::general_purpose};
        format!(
            "sha256:{}",
            general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(package_bytes))
        )
    };
    let manifest_context = protection_context(
        "skill_sync_manifest",
        "skill_sync_manifest_msg",
        &file,
        source_agent_id,
        target_agent_id,
        &file_hash,
    )?;
    let encrypted_manifest = seal_file_manifest(root_key, &manifest_context, &file)?;
    let mut encrypted_chunks = Vec::with_capacity(chunk_count as usize);
    for index in 0..chunk_count {
        let start = (index as usize).saturating_mul(chunk_size as usize);
        let end = (start + chunk_size as usize).min(package_bytes.len());
        let chunk = SecureMeshFileChunk {
            file_id: file_id.clone(),
            chunk_index: index,
            bytes: package_bytes[start..end].to_vec(),
        };
        let chunk_context = protection_context(
            "skill_sync_chunk",
            &format!("skill_sync_chunk_msg_{index}"),
            &file,
            source_agent_id,
            target_agent_id,
            &file_hash,
        )?;
        encrypted_chunks.push(seal_file_chunk(root_key, &chunk_context, &chunk)?);
    }
    let package = SkillSyncPackageManifest {
        skill_id: skill_id.to_string(),
        version: version.to_string(),
        source_agent_id: source_agent_id.to_string(),
        target_agent_id: target_agent_id.to_string(),
        package_digest,
        install_strategy: "skill_hub_apply".to_string(),
        activate,
        file,
    };
    Ok((package, encrypted_manifest, encrypted_chunks))
}

fn protection_context(
    envelope: &str,
    message: &str,
    manifest: &SecureMeshFileManifest,
    sender_endpoint_id: &str,
    recipient_endpoint_id: &str,
    file_hash: &str,
) -> Result<SecureMeshFileProtectionContext> {
    SecureMeshFileProtectionContext::for_pairwise_device(
        SecureMeshContentContext::new(
            format!("env_{envelope}"),
            message,
            "mailbox_file",
            sender_endpoint_id,
            recipient_endpoint_id,
            "skill_sync_session",
            "2026-01-01T00:00:00.000Z",
            "2099-01-01T00:10:00.000Z",
        ),
        manifest.file_id.clone(),
        manifest.chunk_count,
        file_hash,
        1_800_000_000,
    )
}

/// Delivery-store projection for a sealed skill-sync transfer (no plaintext body).
pub fn skill_sync_delivery_json(
    package: &SkillSyncPackageManifest,
    encrypted_manifest: &EncryptedSecureMeshFileManifest,
    encrypted_chunks: &[EncryptedSecureMeshFileChunk],
) -> Value {
    json!({
        "ok": true,
        "protocolVersion": SECURE_MESH_SKILL_SYNC_PROTOCOL,
        "contentType": SECURE_MESH_SKILL_SYNC_CONTENT_TYPE,
        "skillId": package.skill_id,
        "version": package.version,
        "sourceAgentId": package.source_agent_id,
        "targetAgentId": package.target_agent_id,
        "packageDigest": package.package_digest,
        "installStrategy": package.install_strategy,
        "activate": package.activate,
        "plaintextRelayBlocked": true,
        "productionEvidence": false,
        "file": {
            "manifest": file_manifest_delivery_json(encrypted_manifest),
            "chunks": encrypted_chunks
                .iter()
                .map(file_chunk_delivery_json)
                .collect::<Vec<_>>(),
            "chunkCount": encrypted_chunks.len(),
        }
    })
}

/// Evaluate a skill-sync package transfer plan from JSON params (test/CLI helper).
pub fn evaluate_skill_sync_package_json(params: &Value) -> Result<Value> {
    let skill_id = params
        .get("skillId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let version = params
        .get("version")
        .and_then(Value::as_str)
        .unwrap_or("0.0.1")
        .trim()
        .to_string();
    let source_agent_id = params
        .get("sourceAgentId")
        .and_then(Value::as_str)
        .unwrap_or("local")
        .to_string();
    let target_agent_id = params
        .get("targetAgentId")
        .and_then(Value::as_str)
        .unwrap_or("remote")
        .to_string();
    let activate = params
        .get("activate")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let package_bytes = if let Some(text) = params.get("packageUtf8").and_then(Value::as_str) {
        text.as_bytes().to_vec()
    } else if let Some(b64) = params.get("packageBase64").and_then(Value::as_str) {
        use base64::{Engine as _, engine::general_purpose};
        general_purpose::STANDARD
            .decode(b64)
            .map_err(|_| anyhow::anyhow!("skill sync packageBase64 is invalid"))?
    } else {
        anyhow::bail!("skill sync packageUtf8 or packageBase64 is required");
    };
    let root_key = FileRootKey::generate();
    let (package, encrypted_manifest, encrypted_chunks) = seal_skill_sync_package(
        &root_key,
        &skill_id,
        &version,
        &source_agent_id,
        &target_agent_id,
        &package_bytes,
        activate,
    )?;
    let mut delivery = skill_sync_delivery_json(&package, &encrypted_manifest, &encrypted_chunks);
    let wire = serde_json::to_string(&delivery)?;
    if let Ok(plaintext) = std::str::from_utf8(&package_bytes) {
        ensure!(
            !wire.contains(plaintext),
            "skill sync delivery projection leaked plaintext package body"
        );
    }
    if let Some(object) = delivery.as_object_mut() {
        object.insert(
            "relativePath".to_string(),
            Value::String(package.file.relative_path.clone()),
        );
        object.insert("totalSize".to_string(), json!(package.file.total_size));
    }
    Ok(delivery)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skill_sync_seals_package_without_plaintext_on_delivery() {
        let canary = "SKILL_SYNC_PLAINTEXT_CANARY_BODY_42";
        let delivery = evaluate_skill_sync_package_json(&json!({
            "skillId": "demo-skill",
            "version": "1.2.3",
            "sourceAgentId": "desktop",
            "targetAgentId": "phone",
            "packageUtf8": canary,
            "activate": false,
        }))
        .unwrap();
        assert_eq!(delivery["ok"], true);
        assert_eq!(delivery["protocolVersion"], SECURE_MESH_SKILL_SYNC_PROTOCOL);
        assert_eq!(delivery["plaintextRelayBlocked"], true);
        assert_eq!(delivery["productionEvidence"], false);
        assert!(delivery["file"]["chunkCount"].as_u64().unwrap_or(0) >= 1);
        let wire = serde_json::to_string(&delivery).unwrap();
        assert!(!wire.contains(canary));
        assert!(wire.contains("packageDigest"));
        assert!(!wire.contains("packageUtf8"));
    }
}
