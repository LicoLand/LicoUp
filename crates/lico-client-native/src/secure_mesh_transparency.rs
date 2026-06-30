use anyhow::{Result, anyhow, bail, ensure};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub const SECURE_MESH_TRANSPARENCY_STATUS: &str =
    "append_only_hash_chain_inclusion_consistency_cache_available_device_policy_interop_blocked";

const TRANSPARENCY_PROOF_TYPE: &str = "append-only-hash-chain";
const GENESIS_TREE_HEAD: &str = "GENESIS";
const MAX_TRANSPARENCY_FIELD_BYTES: usize = 8192;
const MAX_TRANSPARENCY_LEAVES: usize = 100_000;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshTransparencyLeafBody {
    pub tenant_id: String,
    pub account_id: String,
    pub workspace_id: String,
    pub endpoint_id: String,
    pub endpoint_kind: String,
    pub identity_public_key: String,
    pub signing_public_key: String,
    pub fingerprint: String,
    pub rotation_epoch: u64,
    pub trust_state: String,
    pub updated_at: String,
}

impl SecureMeshTransparencyLeafBody {
    pub fn leaf_hash(&self) -> Result<String> {
        validate_leaf_body(self)?;
        let value = serde_json::json!({
            "tenantId": self.tenant_id,
            "accountId": self.account_id,
            "workspaceId": self.workspace_id,
            "endpointId": self.endpoint_id,
            "endpointKind": self.endpoint_kind,
            "identityPublicKey": self.identity_public_key,
            "signingPublicKey": self.signing_public_key,
            "fingerprint": self.fingerprint,
            "rotationEpoch": self.rotation_epoch,
            "trustState": self.trust_state,
            "updatedAt": self.updated_at,
        });
        Ok(sha256_hex(canonical_json(&value)?.as_bytes()))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshTransparencyLeaf {
    pub index: u64,
    pub tenant_id: String,
    pub account_id: String,
    pub endpoint_id: String,
    pub leaf_hash: String,
    pub previous_tree_head: String,
    pub tree_head: String,
    pub created_at: String,
    pub roster_metadata_hash: String,
}

impl SecureMeshTransparencyLeaf {
    pub fn validate_hash_chain_link(&self) -> Result<()> {
        validate_leaf(self)?;
        let expected = compute_tree_head(&self.previous_tree_head, &self.leaf_hash);
        ensure!(
            self.tree_head == expected,
            "secure mesh transparency tree head mismatch"
        );
        Ok(())
    }

    pub fn matches_body(&self, body: &SecureMeshTransparencyLeafBody) -> Result<()> {
        ensure!(
            self.leaf_hash == body.leaf_hash()?,
            "secure mesh transparency leaf body hash mismatch"
        );
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshInclusionProof {
    pub proof_type: String,
    pub index: u64,
    pub previous_tree_head: String,
    pub tree_head: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshConsistencyProof {
    pub proof_type: String,
    pub from_index: u64,
    pub to_index: u64,
    pub leaves: Vec<SecureMeshTransparencyLeaf>,
    pub tree_head: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshCachedTreeHead {
    pub latest_index: u64,
    pub tree_head: String,
}

pub fn verify_transparency_inclusion(
    leaf: &SecureMeshTransparencyLeaf,
    proof: &SecureMeshInclusionProof,
) -> Result<SecureMeshCachedTreeHead> {
    leaf.validate_hash_chain_link()?;
    ensure!(
        proof.proof_type == TRANSPARENCY_PROOF_TYPE,
        "secure mesh transparency inclusion proof type is unsupported"
    );
    ensure!(
        proof.index == leaf.index,
        "secure mesh transparency inclusion index mismatch"
    );
    ensure!(
        proof.previous_tree_head == leaf.previous_tree_head,
        "secure mesh transparency inclusion previous tree head mismatch"
    );
    ensure!(
        proof.tree_head == leaf.tree_head,
        "secure mesh transparency inclusion tree head mismatch"
    );
    Ok(SecureMeshCachedTreeHead {
        latest_index: leaf.index,
        tree_head: leaf.tree_head.clone(),
    })
}

pub fn verify_transparency_consistency(
    proof: &SecureMeshConsistencyProof,
    cached: Option<&SecureMeshCachedTreeHead>,
) -> Result<SecureMeshCachedTreeHead> {
    ensure!(
        proof.proof_type == TRANSPARENCY_PROOF_TYPE,
        "secure mesh transparency consistency proof type is unsupported"
    );
    ensure!(
        proof.leaves.len() <= MAX_TRANSPARENCY_LEAVES,
        "secure mesh transparency consistency proof has too many leaves"
    );
    let Some(first) = proof.leaves.first() else {
        if let Some(cached) = cached {
            ensure!(
                proof.tree_head == cached.tree_head,
                "secure mesh transparency empty proof tree head changed"
            );
            return Ok(cached.clone());
        }
        bail!("secure mesh transparency consistency proof has no leaves");
    };
    ensure!(
        first.index == proof.from_index,
        "secure mesh transparency consistency fromIndex mismatch"
    );
    let mut expected_index = proof.from_index;
    let mut latest = None::<SecureMeshCachedTreeHead>;
    let mut previous_head = first.previous_tree_head.clone();
    if let Some(cached) = cached {
        ensure!(
            proof.from_index <= cached.latest_index + 1,
            "secure mesh transparency consistency proof starts after cached tree head"
        );
        if proof.from_index == cached.latest_index + 1 {
            ensure!(
                first.previous_tree_head == cached.tree_head,
                "secure mesh transparency cached tree head mismatch"
            );
        }
    }
    for leaf in &proof.leaves {
        validate_leaf(leaf)?;
        ensure!(
            leaf.index == expected_index,
            "secure mesh transparency consistency proof has non-contiguous index"
        );
        ensure!(
            leaf.previous_tree_head == previous_head,
            "secure mesh transparency consistency proof has non-contiguous tree head"
        );
        leaf.validate_hash_chain_link()?;
        previous_head = leaf.tree_head.clone();
        latest = Some(SecureMeshCachedTreeHead {
            latest_index: leaf.index,
            tree_head: leaf.tree_head.clone(),
        });
        expected_index += 1;
    }
    let latest = latest.expect("non-empty leaves");
    ensure!(
        proof.to_index == latest.latest_index,
        "secure mesh transparency consistency toIndex mismatch"
    );
    ensure!(
        proof.tree_head == latest.tree_head,
        "secure mesh transparency consistency advertised tree head mismatch"
    );
    if let Some(cached) = cached {
        ensure!(
            latest.latest_index >= cached.latest_index,
            "secure mesh transparency rollback detected"
        );
        if latest.latest_index == cached.latest_index {
            ensure!(
                latest.tree_head == cached.tree_head,
                "secure mesh transparency split-view detected"
            );
        }
    }
    Ok(latest)
}

fn validate_leaf_body(body: &SecureMeshTransparencyLeafBody) -> Result<()> {
    validate_text("tenant_id", &body.tenant_id)?;
    validate_text("account_id", &body.account_id)?;
    validate_text("workspace_id", &body.workspace_id)?;
    validate_text("endpoint_id", &body.endpoint_id)?;
    validate_text("endpoint_kind", &body.endpoint_kind)?;
    validate_text("identity_public_key", &body.identity_public_key)?;
    validate_text("signing_public_key", &body.signing_public_key)?;
    validate_text("fingerprint", &body.fingerprint)?;
    validate_text("trust_state", &body.trust_state)?;
    validate_text("updated_at", &body.updated_at)?;
    Ok(())
}

fn validate_leaf(leaf: &SecureMeshTransparencyLeaf) -> Result<()> {
    validate_text("tenant_id", &leaf.tenant_id)?;
    validate_text("account_id", &leaf.account_id)?;
    validate_text("endpoint_id", &leaf.endpoint_id)?;
    validate_hex_hash("leaf_hash", &leaf.leaf_hash)?;
    validate_hex_hash("tree_head", &leaf.tree_head)?;
    if !leaf.previous_tree_head.is_empty() {
        validate_hex_hash("previous_tree_head", &leaf.previous_tree_head)?;
    }
    validate_text("created_at", &leaf.created_at)?;
    validate_hex_hash("roster_metadata_hash", &leaf.roster_metadata_hash)?;
    Ok(())
}

fn validate_text(label: &str, value: &str) -> Result<()> {
    ensure!(
        !value.trim().is_empty(),
        "secure mesh transparency {label} is required"
    );
    ensure!(
        value.len() <= MAX_TRANSPARENCY_FIELD_BYTES,
        "secure mesh transparency {label} is too large"
    );
    Ok(())
}

fn validate_hex_hash(label: &str, value: &str) -> Result<()> {
    validate_text(label, value)?;
    ensure!(
        value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "secure mesh transparency {label} is not a sha256 hex digest"
    );
    Ok(())
}

fn compute_tree_head(previous_tree_head: &str, leaf_hash: &str) -> String {
    let previous = if previous_tree_head.is_empty() {
        GENESIS_TREE_HEAD
    } else {
        previous_tree_head
    };
    sha256_hex(format!("{previous}:{leaf_hash}").as_bytes())
}

fn canonical_json(value: &Value) -> Result<String> {
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {
            serde_json::to_string(value).map_err(Into::into)
        }
        Value::Array(items) => {
            let mut out = String::from("[");
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                out.push_str(&canonical_json(item)?);
            }
            out.push(']');
            Ok(out)
        }
        Value::Object(map) => {
            let mut keys = map.keys().collect::<Vec<_>>();
            keys.sort();
            let mut out = String::from("{");
            for (index, key) in keys.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(key).map_err(|error| anyhow!(error))?);
                out.push(':');
                out.push_str(&canonical_json(&map[*key])?);
            }
            out.push('}');
            Ok(out)
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secure_mesh_transparency_verifies_leaf_body_inclusion_and_consistency() {
        let body_a = leaf_body("pc-a", "desktop_sidecar", 0, "unverified");
        let leaf_a = chain_leaf(0, "", &body_a);
        let body_b = leaf_body("pc-b", "desktop_sidecar", 0, "verified");
        let leaf_b = chain_leaf(1, &leaf_a.tree_head, &body_b);

        leaf_a.matches_body(&body_a).unwrap();
        leaf_b.matches_body(&body_b).unwrap();
        let inclusion = verify_transparency_inclusion(
            &leaf_b,
            &SecureMeshInclusionProof {
                proof_type: TRANSPARENCY_PROOF_TYPE.to_string(),
                index: leaf_b.index,
                previous_tree_head: leaf_b.previous_tree_head.clone(),
                tree_head: leaf_b.tree_head.clone(),
            },
        )
        .unwrap();
        assert_eq!(inclusion.latest_index, 1);
        assert_eq!(inclusion.tree_head, leaf_b.tree_head);

        let cached = verify_transparency_consistency(
            &SecureMeshConsistencyProof {
                proof_type: TRANSPARENCY_PROOF_TYPE.to_string(),
                from_index: 0,
                to_index: 1,
                leaves: vec![leaf_a.clone(), leaf_b.clone()],
                tree_head: leaf_b.tree_head.clone(),
            },
            None,
        )
        .unwrap();
        assert_eq!(cached.latest_index, 1);
        assert_eq!(cached.tree_head, leaf_b.tree_head);
    }

    #[test]
    fn secure_mesh_transparency_rejects_leaf_body_hash_mismatch() {
        let body = leaf_body("pc-a", "desktop_sidecar", 0, "unverified");
        let leaf = chain_leaf(0, "", &body);
        let changed = leaf_body("pc-a", "desktop_sidecar", 1, "unverified");
        let error = leaf.matches_body(&changed).unwrap_err();
        assert!(error.to_string().contains("leaf body hash mismatch"));
    }

    #[test]
    fn secure_mesh_transparency_detects_rollback() {
        let body_a = leaf_body("pc-a", "desktop_sidecar", 0, "unverified");
        let leaf_a = chain_leaf(0, "", &body_a);
        let body_b = leaf_body("pc-b", "desktop_sidecar", 0, "verified");
        let leaf_b = chain_leaf(1, &leaf_a.tree_head, &body_b);
        let cached = SecureMeshCachedTreeHead {
            latest_index: 2,
            tree_head: sha256_hex(b"future"),
        };
        let error = verify_transparency_consistency(
            &SecureMeshConsistencyProof {
                proof_type: TRANSPARENCY_PROOF_TYPE.to_string(),
                from_index: 0,
                to_index: 1,
                leaves: vec![leaf_a, leaf_b.clone()],
                tree_head: leaf_b.tree_head,
            },
            Some(&cached),
        )
        .unwrap_err();
        assert!(error.to_string().contains("rollback detected"));
    }

    #[test]
    fn secure_mesh_transparency_detects_split_view_at_cached_index() {
        let body_a = leaf_body("pc-a", "desktop_sidecar", 0, "unverified");
        let leaf_a = chain_leaf(0, "", &body_a);
        let cached = SecureMeshCachedTreeHead {
            latest_index: 0,
            tree_head: sha256_hex(b"different-tree-head"),
        };
        let error = verify_transparency_consistency(
            &SecureMeshConsistencyProof {
                proof_type: TRANSPARENCY_PROOF_TYPE.to_string(),
                from_index: 0,
                to_index: 0,
                leaves: vec![leaf_a.clone()],
                tree_head: leaf_a.tree_head,
            },
            Some(&cached),
        )
        .unwrap_err();
        assert!(error.to_string().contains("split-view detected"));
    }

    #[test]
    fn secure_mesh_transparency_detects_cached_consistency_gap() {
        let body_a = leaf_body("pc-a", "desktop_sidecar", 0, "unverified");
        let leaf_a = chain_leaf(0, "", &body_a);
        let body_b = leaf_body("pc-b", "desktop_sidecar", 0, "verified");
        let mut leaf_b = chain_leaf(1, &leaf_a.tree_head, &body_b);
        let cached = SecureMeshCachedTreeHead {
            latest_index: 0,
            tree_head: leaf_a.tree_head,
        };
        leaf_b.previous_tree_head = sha256_hex(b"wrong-previous");
        leaf_b.tree_head = compute_tree_head(&leaf_b.previous_tree_head, &leaf_b.leaf_hash);
        let error = verify_transparency_consistency(
            &SecureMeshConsistencyProof {
                proof_type: TRANSPARENCY_PROOF_TYPE.to_string(),
                from_index: 1,
                to_index: 1,
                leaves: vec![leaf_b.clone()],
                tree_head: leaf_b.tree_head,
            },
            Some(&cached),
        )
        .unwrap_err();
        assert!(error.to_string().contains("cached tree head mismatch"));
    }

    fn leaf_body(
        endpoint_id: &str,
        endpoint_kind: &str,
        rotation_epoch: u64,
        trust_state: &str,
    ) -> SecureMeshTransparencyLeafBody {
        SecureMeshTransparencyLeafBody {
            tenant_id: "tenant-a".to_string(),
            account_id: "account-a".to_string(),
            workspace_id: "workspace-a".to_string(),
            endpoint_id: endpoint_id.to_string(),
            endpoint_kind: endpoint_kind.to_string(),
            identity_public_key: format!("{endpoint_id}-identity-public"),
            signing_public_key: format!("{endpoint_id}-signing-public"),
            fingerprint: format!("{endpoint_id}-fingerprint"),
            rotation_epoch,
            trust_state: trust_state.to_string(),
            updated_at: "2026-01-01T00:00:00.000Z".to_string(),
        }
    }

    fn chain_leaf(
        index: u64,
        previous_tree_head: &str,
        body: &SecureMeshTransparencyLeafBody,
    ) -> SecureMeshTransparencyLeaf {
        let leaf_hash = body.leaf_hash().unwrap();
        let tree_head = compute_tree_head(previous_tree_head, &leaf_hash);
        let roster_metadata_hash = sha256_hex(
            canonical_json(&serde_json::json!({
                "accountId": body.account_id,
                "endpointId": body.endpoint_id,
                "fingerprint": body.fingerprint,
                "trustState": body.trust_state,
            }))
            .unwrap()
            .as_bytes(),
        );
        SecureMeshTransparencyLeaf {
            index,
            tenant_id: body.tenant_id.clone(),
            account_id: body.account_id.clone(),
            endpoint_id: body.endpoint_id.clone(),
            leaf_hash,
            previous_tree_head: previous_tree_head.to_string(),
            tree_head,
            created_at: body.updated_at.clone(),
            roster_metadata_hash,
        }
    }
}
