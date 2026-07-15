//! Verification-only Key Transparency primitives for the client.
//!
//! The release build deliberately contains no log signing key or log authority.  A client is
//! constructed with an explicit pin, verifies RFC 9162-style append-only proofs, verifies the
//! authenticated sparse directory map, and advances its durable checkpoint with a SQLite CAS.
//! A small signer exists at the bottom of this file only for tests or the explicit debug-only
//! acceptance mock feature; ordinary and release client builds contain verification only.

use anyhow::{Result, anyhow, bail, ensure};
use ed25519_dalek::{Signature, VerifyingKey};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::Path;

pub const SECURE_MESH_TRANSPARENCY_STATUS: &str =
    "verification_only_pinned_log_rfc9162_sparse_directory_sqlite_cas_gossip_fail_closed";
pub const SECURE_MESH_KT_PROTOCOL_VERSION: &str = "licolite.secure-mesh.kt.v2";
pub const SECURE_MESH_KT_GOSSIP_CONTENT_TYPE: &str =
    "application/vnd.licolite.secure-mesh.kt-sth-gossip+json";
pub const KT_PROTOCOL_MAX_STH_AGE_SECONDS: u64 = 24 * 60 * 60;
pub const KT_PROTOCOL_MAX_FUTURE_SKEW_SECONDS: u64 = 5 * 60;
pub const KT_PROTOCOL_MAX_GOSSIP_AGE_SECONDS: u64 = 15 * 60;
pub const KT_JSON_SAFE_INTEGER_MAX: u64 = 9_007_199_254_740_991;

const STH_SIGN_MAGIC: &[u8] = b"LCOSM-KT-STH-v2";
const DIRECTORY_SCOPE_COMMITMENT_DOMAIN: &[u8] = b"LCOSM-KT-DIRECTORY-SCOPE-v1";
const DIRECTORY_LABEL_DOMAIN: &[u8] = b"LCOSM-KT-DIRECTORY-LABEL-v1";
const MAP_KEY_DOMAIN: &[u8] = b"LCOSM-KT-MAP-KEY-v1";
const MAP_LEAF_DOMAIN: &[u8] = b"LCOSM-KT-MAP-LEAF-v1";
const MAP_EMPTY_DOMAIN: &[u8] = b"LCOSM-KT-MAP-EMPTY-v1";
const MAP_NODE_DOMAIN: &[u8] = b"LCOSM-KT-MAP-NODE-v1";
const COMBINED_MAP_ROOT_LOG_ENTRY_DOMAIN: &[u8] = b"LCOSM-KT-COMBINED-MAP-ROOT-v1";
const MAX_TRANSPARENCY_FIELD_BYTES: usize = 8_192;
#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
const MAX_TRANSPARENCY_LEAVES: usize = 100_000;
const MAX_INCLUSION_PROOF_HASHES: usize = 64;
const MAX_CONSISTENCY_PROOF_HASHES: usize = 65;
const MAX_PERSISTED_CHECKPOINTS: u64 = 64;
const MAX_PERSISTED_GOSSIP_OBSERVATIONS: u64 = 64;
const MAX_PERSISTED_DIRECTORY_LABELS: u64 = 4_096;
const MAX_PERSISTED_DIRECTORY_AUTHORIZATIONS: u64 = 8_192;
const KT_SCHEMA_VERSION: i64 = 7;
const KT_PREVIOUS_SCHEMA_VERSION: i64 = 6;
const KT_LEGACY_SCHEMA_VERSION: i64 = 5;
const KT_OLDEST_SUPPORTED_SCHEMA_VERSION: i64 = 4;
const SPARSE_MAP_DEPTH: usize = 256;
const HASH_LEN: usize = 32;

const KT_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS secure_mesh_kt_configuration (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    protocol_version TEXT NOT NULL,
    log_id TEXT NOT NULL,
    key_id TEXT NOT NULL,
    public_key_hex TEXT NOT NULL,
    provenance TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS secure_mesh_kt_guard (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    blocked INTEGER NOT NULL CHECK (blocked IN (0, 1)),
    reason_code TEXT
);
CREATE TABLE IF NOT EXISTS secure_mesh_kt_time_guard (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    max_observed_epoch_seconds INTEGER NOT NULL CHECK (max_observed_epoch_seconds >= 0)
);
CREATE TABLE IF NOT EXISTS secure_mesh_kt_checkpoints (
    log_id TEXT NOT NULL,
    tree_size INTEGER NOT NULL CHECK (tree_size >= 0),
    root_hash TEXT NOT NULL,
    map_root_hash TEXT NOT NULL,
    issued_at_epoch_seconds INTEGER NOT NULL CHECK (issued_at_epoch_seconds >= 0),
    key_id TEXT NOT NULL,
    PRIMARY KEY (log_id, tree_size)
);
CREATE TABLE IF NOT EXISTS secure_mesh_kt_directory_latest (
    log_id TEXT NOT NULL,
    stable_label TEXT NOT NULL,
    version INTEGER NOT NULL CHECK (version >= 0),
    leaf_hash TEXT NOT NULL,
    revoked INTEGER NOT NULL CHECK (revoked IN (0, 1)),
    identity_fingerprint TEXT NOT NULL,
    identity_rotation_epoch INTEGER NOT NULL CHECK (identity_rotation_epoch >= 0),
    identity_key_digest TEXT NOT NULL,
    pairwise_prekey_version INTEGER NOT NULL CHECK (pairwise_prekey_version >= 0),
    signed_prekey_digest TEXT NOT NULL,
    one_time_prekey_digest TEXT NOT NULL,
    mls_key_package_version INTEGER NOT NULL CHECK (mls_key_package_version >= 0),
    mls_key_package_digest TEXT NOT NULL,
    tree_size INTEGER NOT NULL CHECK (tree_size >= 0),
    PRIMARY KEY (log_id, stable_label)
);
CREATE TABLE IF NOT EXISTS secure_mesh_kt_directory_authorizations (
    log_id TEXT NOT NULL,
    stable_label TEXT NOT NULL,
    purpose TEXT NOT NULL,
    directory_version INTEGER NOT NULL CHECK (directory_version >= 0),
    leaf_hash TEXT NOT NULL,
    revoked INTEGER NOT NULL CHECK (revoked IN (0, 1)),
    tree_size INTEGER NOT NULL CHECK (tree_size >= 0),
    root_hash TEXT NOT NULL,
    map_root_hash TEXT NOT NULL,
    issued_at_epoch_seconds INTEGER NOT NULL CHECK (issued_at_epoch_seconds >= 0),
    observed_at_epoch_seconds INTEGER NOT NULL CHECK (observed_at_epoch_seconds >= 0),
    inclusion_json TEXT NOT NULL,
    map_proof_json TEXT NOT NULL,
    PRIMARY KEY (log_id, stable_label, purpose)
);
CREATE TABLE IF NOT EXISTS secure_mesh_kt_gossip_observations (
    log_id TEXT NOT NULL,
    tree_size INTEGER NOT NULL CHECK (tree_size >= 0),
    root_hash TEXT NOT NULL,
    map_root_hash TEXT NOT NULL,
    issued_at_epoch_seconds INTEGER NOT NULL CHECK (issued_at_epoch_seconds >= 0),
    observed_at_epoch_seconds INTEGER NOT NULL CHECK (observed_at_epoch_seconds >= 0),
    PRIMARY KEY (
        log_id, tree_size, root_hash, map_root_hash, issued_at_epoch_seconds
    )
);
CREATE INDEX IF NOT EXISTS secure_mesh_kt_gossip_observed_idx
    ON secure_mesh_kt_gossip_observations(log_id, observed_at_epoch_seconds);
"#;

/// Residual diagnostic helper. It is intentionally disconnected from every authority API.
pub const SECURE_MESH_DIAGNOSTIC_HASH_CHAIN_STATUS: &str =
    "diagnostic_only_unsigned_append_only_hash_chain_non_authorizing";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshTransparencyLeafBody {
    /// Opaque commitment computed locally from the directory tenancy scope. Raw tenant,
    /// account, and workspace identifiers never enter a directory proof or peer descriptor.
    pub directory_scope_commitment: String,
    pub endpoint_id: String,
    pub endpoint_kind: String,
    pub identity_public_key: String,
    pub signing_public_key: String,
    pub fingerprint: String,
    pub rotation_epoch: u64,
    pub directory_state: String,
    pub updated_at: String,
}

impl SecureMeshTransparencyLeafBody {
    /// RFC 9162-style leaf hash: `SHA-256(0x00 || canonical_leaf_bytes)`.
    pub fn leaf_hash(&self) -> Result<[u8; HASH_LEN]> {
        validate_leaf_body(self)?;
        let value = serde_json::json!({
            "directoryScopeCommitment": self.directory_scope_commitment,
            "endpointId": self.endpoint_id,
            "endpointKind": self.endpoint_kind,
            "identityPublicKey": self.identity_public_key,
            "signingPublicKey": self.signing_public_key,
            "fingerprint": self.fingerprint,
            "rotationEpoch": self.rotation_epoch,
            "directoryState": self.directory_state,
            "updatedAt": self.updated_at,
        });
        Ok(kt_log_leaf_hash(canonical_json(&value)?.as_bytes()))
    }

    pub fn leaf_hash_hex(&self) -> Result<String> {
        Ok(hex_encode(&self.leaf_hash()?))
    }

    /// Stable, unambiguous logical directory label. Version and mutable keys are excluded.
    pub fn directory_key(&self) -> String {
        stable_directory_label(&self.directory_scope_commitment, &self.endpoint_id)
    }

    pub fn is_revoked(&self) -> bool {
        self.directory_state.eq_ignore_ascii_case("revoked")
    }
}

pub fn directory_scope_commitment(tenant_id: &str, account_id: &str, workspace_id: &str) -> String {
    let mut transcript = Vec::new();
    append_len_prefixed(&mut transcript, tenant_id.as_bytes());
    append_len_prefixed(&mut transcript, account_id.as_bytes());
    append_len_prefixed(&mut transcript, workspace_id.as_bytes());
    hex_encode(&domain_hash(DIRECTORY_SCOPE_COMMITMENT_DOMAIN, &transcript))
}

pub fn stable_directory_label(directory_scope_commitment: &str, endpoint_id: &str) -> String {
    let mut transcript = Vec::new();
    append_len_prefixed(&mut transcript, directory_scope_commitment.as_bytes());
    append_len_prefixed(&mut transcript, endpoint_id.as_bytes());
    hex_encode(&domain_hash(DIRECTORY_LABEL_DOMAIN, &transcript))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum KtAuthorityProvenance {
    /// A public key explicitly configured by the user or local administrator. This verifies
    /// cryptography but does not by itself prove who operates the service.
    UserConfiguredExternal,
    #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
    LocalAcceptanceMock,
}

impl KtAuthorityProvenance {
    pub fn stable_code(&self) -> &'static str {
        match self {
            Self::UserConfiguredExternal => "user-configured-external",
            #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
            Self::LocalAcceptanceMock => "local-acceptance-mock",
        }
    }

    pub fn is_mock(&self) -> bool {
        match self {
            Self::UserConfiguredExternal => false,
            #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
            Self::LocalAcceptanceMock => true,
        }
    }

    /// A caller-supplied Ed25519 key proves signatures, not operator identity. Production
    /// service provenance remains false until a separately signed/release-pinned authority
    /// descriptor is implemented and verified.
    pub fn production_service_claim_allowed(&self) -> bool {
        false
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PinnedKtLogKey {
    log_id: String,
    key_id: String,
    public_key: [u8; 32],
    provenance: KtAuthorityProvenance,
}

impl PinnedKtLogKey {
    pub fn from_user_configured_ed25519_bytes(
        log_id: impl Into<String>,
        key_id: impl Into<String>,
        public_key: [u8; 32],
    ) -> Result<Self> {
        let value = Self {
            log_id: log_id.into(),
            key_id: key_id.into(),
            public_key,
            provenance: KtAuthorityProvenance::UserConfiguredExternal,
        };
        validate_text("log_id", &value.log_id)?;
        validate_text("key_id", &value.key_id)?;
        VerifyingKey::from_bytes(&value.public_key)
            .map_err(|_| anyhow!("secure mesh KT pinned public key is invalid"))?;
        Ok(value)
    }

    #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
    pub fn from_acceptance_mock_ed25519_bytes(
        log_id: impl Into<String>,
        key_id: impl Into<String>,
        public_key: [u8; 32],
    ) -> Result<Self> {
        let mut value = Self::from_user_configured_ed25519_bytes(log_id, key_id, public_key)?;
        value.provenance = KtAuthorityProvenance::LocalAcceptanceMock;
        Ok(value)
    }

    pub fn log_id(&self) -> &str {
        &self.log_id
    }

    pub fn key_id(&self) -> &str {
        &self.key_id
    }

    pub fn provenance(&self) -> &KtAuthorityProvenance {
        &self.provenance
    }

    pub fn public_key_hex(&self) -> String {
        hex_encode(&self.public_key)
    }

    fn verifying_key(&self) -> Result<VerifyingKey> {
        VerifyingKey::from_bytes(&self.public_key)
            .map_err(|_| anyhow!("secure mesh KT pinned public key is invalid"))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KtFreshnessPolicy {
    pub max_sth_age_seconds: u64,
    pub max_future_skew_seconds: u64,
}

impl KtFreshnessPolicy {
    pub fn strict(max_sth_age_seconds: u64, max_future_skew_seconds: u64) -> Result<Self> {
        ensure!(
            max_sth_age_seconds > 0,
            "secure mesh KT maximum STH age must be positive"
        );
        ensure!(
            max_sth_age_seconds <= KT_PROTOCOL_MAX_STH_AGE_SECONDS,
            "secure mesh KT maximum STH age exceeds the protocol hard limit"
        );
        ensure!(
            max_future_skew_seconds <= KT_PROTOCOL_MAX_FUTURE_SKEW_SECONDS,
            "secure mesh KT maximum future skew exceeds the protocol hard limit"
        );
        Ok(Self {
            max_sth_age_seconds,
            max_future_skew_seconds,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedKtFreshness {
    pub observed_at_epoch_seconds: u64,
    pub issued_at_epoch_seconds: u64,
    pub max_sth_age_seconds: u64,
    pub max_future_skew_seconds: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshSignedTreeHead {
    pub protocol_version: String,
    pub log_id: String,
    pub key_id: String,
    pub tree_size: u64,
    pub root_hash: String,
    pub map_root_hash: String,
    pub issued_at_epoch_seconds: u64,
    pub signature: String,
}

impl SecureMeshSignedTreeHead {
    pub fn verify(
        &self,
        pin: &PinnedKtLogKey,
        freshness_policy: KtFreshnessPolicy,
        now_epoch_seconds: u64,
    ) -> Result<VerifiedKtFreshness> {
        self.verify_authenticity(pin)?;
        self.verify_freshness(freshness_policy, now_epoch_seconds)
    }

    fn verify_authenticity(&self, pin: &PinnedKtLogKey) -> Result<()> {
        ensure!(
            self.protocol_version == SECURE_MESH_KT_PROTOCOL_VERSION,
            "secure mesh KT protocol version is unsupported"
        );
        ensure!(
            self.log_id == pin.log_id,
            "secure mesh KT log id is not pinned"
        );
        ensure!(
            self.key_id == pin.key_id,
            "secure mesh KT key id is not pinned"
        );
        ensure!(
            self.tree_size <= KT_JSON_SAFE_INTEGER_MAX
                && self.issued_at_epoch_seconds <= KT_JSON_SAFE_INTEGER_MAX,
            "secure mesh KT signed tree head integer exceeds the cross-language safe range"
        );
        validate_hex_hash("root_hash", &self.root_hash)?;
        validate_hex_hash("map_root_hash", &self.map_root_hash)?;
        let payload = sth_sign_payload(self)?;
        let signature = parse_signature(&self.signature)?;
        pin.verifying_key()?
            .verify_strict(&payload, &signature)
            .map_err(|_| anyhow!("secure mesh KT signed tree head signature is invalid"))?;
        Ok(())
    }

    fn verify_freshness(
        &self,
        freshness_policy: KtFreshnessPolicy,
        now_epoch_seconds: u64,
    ) -> Result<VerifiedKtFreshness> {
        ensure!(
            self.issued_at_epoch_seconds
                <= now_epoch_seconds.saturating_add(freshness_policy.max_future_skew_seconds),
            "secure mesh KT signed tree head is from the future"
        );
        ensure!(
            now_epoch_seconds
                <= self
                    .issued_at_epoch_seconds
                    .saturating_add(freshness_policy.max_sth_age_seconds),
            "secure mesh KT signed tree head is stale"
        );
        Ok(VerifiedKtFreshness {
            observed_at_epoch_seconds: now_epoch_seconds,
            issued_at_epoch_seconds: self.issued_at_epoch_seconds,
            max_sth_age_seconds: freshness_policy.max_sth_age_seconds,
            max_future_skew_seconds: freshness_policy.max_future_skew_seconds,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshKtInclusionProof {
    pub leaf_index: u64,
    pub tree_size: u64,
    pub leaf_hash: String,
    /// RFC 9162 audit path, ordered from the leaf level towards the root.
    pub siblings: Vec<String>,
    pub signed_tree_head: SecureMeshSignedTreeHead,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshKtConsistencyProof {
    pub first_tree_size: u64,
    pub second_tree_size: u64,
    pub first_root_hash: String,
    /// RFC 9162 consistency path. Never contains the full leaf set.
    pub path: Vec<String>,
    pub second_signed_tree_head: SecureMeshSignedTreeHead,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshKtMapEntry {
    pub leaf_hash: String,
    pub version: u64,
    pub revoked: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshKtMapProof {
    pub stable_label: String,
    /// `None` proves non-inclusion through the sparse-map empty leaf.
    pub entry: Option<SecureMeshKtMapEntry>,
    /// Exactly 256 hashes, ordered from leaf level to root.
    pub siblings: Vec<String>,
    pub signed_tree_head: SecureMeshSignedTreeHead,
}

pub type SecureMeshKtNonInclusionProof = SecureMeshKtMapProof;

pub(crate) struct DirectoryComponentCommitments<'a> {
    pub identity_fingerprint: &'a str,
    pub identity_rotation_epoch: u64,
    pub identity_key_digest: &'a str,
    pub pairwise_prekey_version: u64,
    pub signed_prekey_digest: &'a str,
    pub one_time_prekey_digest: &'a str,
    pub mls_key_package_version: u64,
    pub mls_key_package_digest: &'a str,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshKtCachedCheckpoint {
    pub tree_size: u64,
    pub root_hash: String,
    pub map_root_hash: String,
    pub issued_at_epoch_seconds: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshKtAuthorizationReceipt {
    pub stable_label: String,
    pub purpose: String,
    pub directory_version: u64,
    pub leaf_hash: String,
    pub revoked: bool,
    pub tree_size: u64,
    pub root_hash: String,
    pub map_root_hash: String,
    pub issued_at_epoch_seconds: u64,
    pub observed_at_epoch_seconds: u64,
    pub validated_at_epoch_seconds: u64,
    pub expires_at_epoch_seconds: u64,
    pub identity_fingerprint: String,
    pub identity_rotation_epoch: u64,
    pub identity_key_digest: String,
    pub pairwise_prekey_version: u64,
    pub signed_prekey_digest: String,
    pub one_time_prekey_digest: String,
    pub mls_key_package_version: u64,
    pub mls_key_package_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshKtGossipPayload {
    pub content_type: String,
    pub signed_tree_head: SecureMeshSignedTreeHead,
    pub consistency_proof: Option<SecureMeshKtConsistencyProof>,
}

impl SecureMeshKtGossipPayload {
    pub fn from_sth(
        signed_tree_head: SecureMeshSignedTreeHead,
        consistency_proof: Option<SecureMeshKtConsistencyProof>,
    ) -> Self {
        Self {
            content_type: SECURE_MESH_KT_GOSSIP_CONTENT_TYPE.to_string(),
            signed_tree_head,
            consistency_proof,
        }
    }

    pub fn to_json_bytes(&self) -> Result<Vec<u8>> {
        let consistency = self.consistency_proof.as_ref().map(consistency_to_json);
        Ok(serde_json::to_vec(&serde_json::json!({
            "contentType": self.content_type,
            "signedTreeHead": sth_to_json(&self.signed_tree_head),
            "consistencyProof": consistency,
        }))?)
    }

    pub fn from_json_bytes(bytes: &[u8]) -> Result<Self> {
        ensure!(
            bytes.len() <= MAX_TRANSPARENCY_FIELD_BYTES * 4,
            "secure mesh KT gossip payload is too large"
        );
        let value: Value = serde_json::from_slice(bytes)
            .map_err(|_| anyhow!("secure mesh KT gossip payload is invalid"))?;
        let sth = parse_sth_json(
            value
                .get("signedTreeHead")
                .ok_or_else(|| anyhow!("secure mesh KT gossip signedTreeHead is required"))?,
        )?;
        let consistency_proof = match value.get("consistencyProof") {
            None | Some(Value::Null) => None,
            Some(proof) => Some(parse_consistency_json(proof)?),
        };
        Ok(Self {
            content_type: required_json_text(&value, "contentType")?,
            signed_tree_head: sth,
            consistency_proof,
        })
    }
}

/// Durable verifier state. Construction always requires a preconfigured pin in release builds.
pub struct SecureMeshKtClientState {
    connection: Connection,
    pin: Option<PinnedKtLogKey>,
    freshness_policy: KtFreshnessPolicy,
}

impl SecureMeshKtClientState {
    pub fn open(
        path: impl AsRef<Path>,
        pin: PinnedKtLogKey,
        freshness_policy: KtFreshnessPolicy,
    ) -> Result<Self> {
        let connection = Connection::open(path)
            .map_err(|error| anyhow!("secure mesh KT state open failed: {error}"))?;
        Self::from_connection(connection, pin, freshness_policy)
    }

    pub fn open_in_memory(
        pin: PinnedKtLogKey,
        freshness_policy: KtFreshnessPolicy,
    ) -> Result<Self> {
        let connection = Connection::open_in_memory()
            .map_err(|error| anyhow!("secure mesh KT in-memory state open failed: {error}"))?;
        Self::from_connection(connection, pin, freshness_policy)
    }

    fn from_connection(
        connection: Connection,
        pin: PinnedKtLogKey,
        freshness_policy: KtFreshnessPolicy,
    ) -> Result<Self> {
        initialize_kt_schema(&connection)?;
        initialize_or_validate_pin(&connection, &pin)?;
        connection.execute(
            "INSERT OR IGNORE INTO secure_mesh_kt_guard(singleton, blocked, reason_code) VALUES(1, 0, NULL)",
            [],
        )?;
        connection.execute(
            "INSERT OR IGNORE INTO secure_mesh_kt_time_guard(singleton, max_observed_epoch_seconds) VALUES(1, 0)",
            [],
        )?;
        Ok(Self {
            connection,
            pin: Some(pin),
            freshness_policy,
        })
    }

    pub fn pin(&self) -> Result<&PinnedKtLogKey> {
        self.pin
            .as_ref()
            .ok_or_else(|| anyhow!("secure mesh KT explicit log pin is required"))
    }

    pub fn equivocation_detected(&self) -> Result<bool> {
        Ok(self.connection.query_row(
            "SELECT blocked FROM secure_mesh_kt_guard WHERE singleton = 1",
            [],
            |row| row.get::<_, i64>(0),
        )? != 0)
    }

    pub fn latest_checkpoint(&self) -> Result<Option<SecureMeshKtCachedCheckpoint>> {
        latest_checkpoint_connection(&self.connection, self.pin()?.log_id())
    }

    pub fn checkpoint_count(&self) -> Result<u64> {
        let count: i64 = self.connection.query_row(
            "SELECT COUNT(*) FROM secure_mesh_kt_checkpoints WHERE log_id = ?1",
            params![self.pin()?.log_id()],
            |row| row.get(0),
        )?;
        u64::try_from(count).map_err(|_| anyhow!("secure mesh KT checkpoint count is invalid"))
    }

    /// Verify and atomically persist an STH learned through gossip/monitoring.
    pub fn observe_peer_gossip_sth(
        &mut self,
        gossip: &SecureMeshKtGossipPayload,
        now_epoch_seconds: u64,
    ) -> Result<SecureMeshKtCachedCheckpoint> {
        ensure!(
            gossip.content_type == SECURE_MESH_KT_GOSSIP_CONTENT_TYPE,
            "secure mesh KT gossip content type is unsupported"
        );
        let checkpoint = self.observe_tree_head(
            &gossip.signed_tree_head,
            gossip.consistency_proof.as_ref(),
            now_epoch_seconds,
        )?;
        let pin = self.pin()?.clone();
        let effective_now_epoch_seconds =
            advance_durable_time_watermark(&mut self.connection, now_epoch_seconds)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        persist_gossip_observation_transaction(
            &transaction,
            &pin,
            &gossip.signed_tree_head,
            effective_now_epoch_seconds,
        )?;
        transaction.commit()?;
        Ok(checkpoint)
    }

    /// Verify an outgoing gossip payload against the already accepted local checkpoint without
    /// counting the local echo as independent peer/witness evidence.
    pub fn validate_outgoing_gossip_sth(
        &mut self,
        gossip: &SecureMeshKtGossipPayload,
        now_epoch_seconds: u64,
    ) -> Result<SecureMeshKtCachedCheckpoint> {
        ensure!(
            gossip.content_type == SECURE_MESH_KT_GOSSIP_CONTENT_TYPE,
            "secure mesh KT gossip content type is unsupported"
        );
        ensure!(
            gossip.consistency_proof.is_none(),
            "secure mesh KT outgoing current-checkpoint gossip must not carry a transition proof"
        );
        let pin = self.pin()?.clone();
        let effective_now_epoch_seconds =
            advance_durable_time_watermark(&mut self.connection, now_epoch_seconds)?;
        verify_authenticated_sth_freshness_or_block(
            &mut self.connection,
            &pin,
            self.freshness_policy,
            &gossip.signed_tree_head,
            effective_now_epoch_seconds,
        )?;
        let latest = latest_checkpoint_connection(&self.connection, pin.log_id())?
            .ok_or_else(|| anyhow!("secure mesh KT outgoing gossip checkpoint is unavailable"))?;
        ensure!(
            latest.tree_size == gossip.signed_tree_head.tree_size
                && latest.root_hash == gossip.signed_tree_head.root_hash
                && latest.map_root_hash == gossip.signed_tree_head.map_root_hash
                && latest.issued_at_epoch_seconds
                    == gossip.signed_tree_head.issued_at_epoch_seconds,
            "secure mesh KT outgoing gossip does not match the accepted local checkpoint"
        );
        Ok(latest)
    }

    pub fn observe_tree_head(
        &mut self,
        sth: &SecureMeshSignedTreeHead,
        consistency: Option<&SecureMeshKtConsistencyProof>,
        now_epoch_seconds: u64,
    ) -> Result<SecureMeshKtCachedCheckpoint> {
        let pin = self.pin()?.clone();
        let effective_now_epoch_seconds =
            advance_durable_time_watermark(&mut self.connection, now_epoch_seconds)?;
        verify_authenticated_sth_freshness_or_block(
            &mut self.connection,
            &pin,
            self.freshness_policy,
            sth,
            effective_now_epoch_seconds,
        )?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let transition = advance_checkpoint_transaction(
            &transaction,
            &pin,
            self.freshness_policy,
            sth,
            consistency,
            effective_now_epoch_seconds,
        )?;
        match transition {
            CheckpointTransition::Accepted(checkpoint) => {
                transaction.commit()?;
                Ok(checkpoint)
            }
            CheckpointTransition::SecurityBlock(reason) => {
                transaction.commit()?;
                bail!("secure mesh KT security block persisted: {reason}")
            }
        }
    }

    pub(crate) fn authorize_hashed_directory_view(
        &mut self,
        stable_label: &str,
        purpose: &str,
        version: u64,
        revoked: bool,
        expected_leaf_hash: &str,
        components: DirectoryComponentCommitments<'_>,
        inclusion: &SecureMeshKtInclusionProof,
        map_proof: &SecureMeshKtMapProof,
        consistency: Option<&SecureMeshKtConsistencyProof>,
        now_epoch_seconds: u64,
    ) -> Result<(SecureMeshKtCachedCheckpoint, VerifiedKtFreshness)> {
        validate_hex_hash("stable_label", stable_label)?;
        validate_text("authorization_purpose", purpose)?;
        validate_hex_hash("expected_leaf_hash", expected_leaf_hash)?;
        validate_text("identity_fingerprint", components.identity_fingerprint)?;
        validate_hex_hash("identity_key_digest", components.identity_key_digest)?;
        validate_hex_hash("signed_prekey_digest", components.signed_prekey_digest)?;
        validate_hex_hash("one_time_prekey_digest", components.one_time_prekey_digest)?;
        validate_hex_hash("mls_key_package_digest", components.mls_key_package_digest)?;
        let pin = self.pin()?.clone();
        let effective_now_epoch_seconds =
            advance_durable_time_watermark(&mut self.connection, now_epoch_seconds)?;
        verify_authenticated_sth_freshness_or_block(
            &mut self.connection,
            &pin,
            self.freshness_policy,
            &inclusion.signed_tree_head,
            effective_now_epoch_seconds,
        )?;
        let freshness = verify_kt_inclusion(
            inclusion,
            &pin,
            self.freshness_policy,
            effective_now_epoch_seconds,
        )?;
        let expected_map_root_log_leaf = hex_encode(&map_root_log_leaf_hash(
            &inclusion.signed_tree_head.map_root_hash,
        )?);
        ensure!(
            inclusion.leaf_hash == expected_map_root_log_leaf,
            "secure mesh KT append-log inclusion does not commit the authenticated map root"
        );
        ensure!(
            inclusion.signed_tree_head == map_proof.signed_tree_head,
            "secure mesh KT log and map proofs do not share one signed tree head"
        );
        verify_kt_map_inclusion(
            map_proof,
            stable_label,
            expected_leaf_hash,
            version,
            revoked,
            &pin,
            self.freshness_policy,
            effective_now_epoch_seconds,
        )?;

        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let checkpoint = match advance_checkpoint_transaction(
            &transaction,
            &pin,
            self.freshness_policy,
            &inclusion.signed_tree_head,
            consistency,
            effective_now_epoch_seconds,
        )? {
            CheckpointTransition::Accepted(checkpoint) => checkpoint,
            CheckpointTransition::SecurityBlock(reason) => {
                transaction.commit()?;
                bail!("secure mesh KT security block persisted: {reason}")
            }
        };
        require_fresh_gossip_observation_transaction(
            &transaction,
            &pin,
            &inclusion.signed_tree_head,
            self.freshness_policy,
            effective_now_epoch_seconds,
        )?;
        if let Some(reason) = enforce_directory_latest_transaction(
            &transaction,
            &pin,
            stable_label,
            version,
            expected_leaf_hash,
            revoked,
            &components,
            checkpoint.tree_size,
        )? {
            transaction.commit()?;
            bail!("secure mesh KT security block persisted: {reason}")
        }
        persist_directory_authorization_transaction(
            &transaction,
            &pin,
            stable_label,
            purpose,
            version,
            expected_leaf_hash,
            revoked,
            inclusion,
            map_proof,
            &freshness,
        )?;
        transaction.commit()?;
        Ok((checkpoint, freshness))
    }

    pub fn require_current_directory_authorization(
        &mut self,
        stable_label: &str,
        purpose: &str,
        now_epoch_seconds: u64,
    ) -> Result<SecureMeshKtAuthorizationReceipt> {
        validate_hex_hash("stable_label", stable_label)?;
        validate_text("authorization_purpose", purpose)?;
        let pin = self.pin()?.clone();
        let effective_now_epoch_seconds =
            advance_durable_time_watermark(&mut self.connection, now_epoch_seconds)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Deferred)?;
        let blocked = transaction.query_row(
            "SELECT blocked FROM secure_mesh_kt_guard WHERE singleton = 1",
            [],
            |row| row.get::<_, i64>(0),
        )? != 0;
        ensure!(
            !blocked,
            "secure mesh KT equivocation was previously persisted; authorization is blocked"
        );
        let latest = latest_checkpoint_connection(&transaction, pin.log_id())?
            .ok_or_else(|| anyhow!("secure mesh KT current checkpoint is unavailable"))?;
        let persisted = transaction
            .query_row(
                "SELECT directory_version, leaf_hash, revoked, tree_size, root_hash, map_root_hash, issued_at_epoch_seconds, observed_at_epoch_seconds, inclusion_json, map_proof_json
                 FROM secure_mesh_kt_directory_authorizations
                 WHERE log_id = ?1 AND stable_label = ?2 AND purpose = ?3",
                params![pin.log_id(), stable_label, purpose],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)? != 0,
                        row.get::<_, i64>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, i64>(6)?,
                        row.get::<_, i64>(7)?,
                        row.get::<_, String>(8)?,
                        row.get::<_, String>(9)?,
                    ))
                },
            )
            .optional()?
            .ok_or_else(|| anyhow!("secure mesh KT purpose-bound authorization is missing"))?;
        let directory_version = sql_to_u64(persisted.0, "directory version")?;
        let tree_size = sql_to_u64(persisted.3, "authorization tree size")?;
        let issued_at_epoch_seconds = sql_to_u64(persisted.6, "authorization issue time")?;
        let observed_at_epoch_seconds = sql_to_u64(persisted.7, "authorization observation time")?;
        let inclusion: SecureMeshKtInclusionProof = serde_json::from_str(&persisted.8)
            .map_err(|_| anyhow!("secure mesh KT persisted inclusion proof is invalid"))?;
        let map_proof: SecureMeshKtMapProof = serde_json::from_str(&persisted.9)
            .map_err(|_| anyhow!("secure mesh KT persisted map proof is invalid"))?;

        ensure!(
            tree_size == latest.tree_size
                && persisted.4 == latest.root_hash
                && persisted.5 == latest.map_root_hash,
            "secure mesh KT label authorization does not match the current accepted checkpoint"
        );
        let latest_directory = transaction
            .query_row(
                "SELECT version, leaf_hash, revoked, tree_size,
                        identity_fingerprint, identity_rotation_epoch, identity_key_digest,
                        pairwise_prekey_version, signed_prekey_digest, one_time_prekey_digest,
                        mls_key_package_version, mls_key_package_digest
                 FROM secure_mesh_kt_directory_latest
                 WHERE log_id = ?1 AND stable_label = ?2",
                params![pin.log_id(), stable_label],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)? != 0,
                        row.get::<_, i64>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, i64>(7)?,
                        row.get::<_, String>(8)?,
                        row.get::<_, String>(9)?,
                        row.get::<_, i64>(10)?,
                        row.get::<_, String>(11)?,
                    ))
                },
            )
            .optional()?
            .ok_or_else(|| anyhow!("secure mesh KT directory label is unavailable"))?;
        ensure!(
            sql_to_u64(latest_directory.0, "directory version")? == directory_version
                && latest_directory.1 == persisted.1
                && latest_directory.2 == persisted.2
                && sql_to_u64(latest_directory.3, "directory tree size")? == tree_size,
            "secure mesh KT purpose authorization is not bound to the latest directory claim"
        );
        ensure!(
            inclusion.signed_tree_head == map_proof.signed_tree_head
                && inclusion.signed_tree_head.tree_size == tree_size
                && inclusion.signed_tree_head.root_hash == persisted.4
                && inclusion.signed_tree_head.map_root_hash == persisted.5
                && inclusion.signed_tree_head.issued_at_epoch_seconds == issued_at_epoch_seconds,
            "secure mesh KT persisted authorization STH binding is invalid"
        );
        inclusion.signed_tree_head.verify_authenticity(&pin)?;
        if let Some(reason) = authenticated_sth_temporal_block_reason(
            &inclusion.signed_tree_head,
            self.freshness_policy,
            effective_now_epoch_seconds,
        ) {
            drop(transaction);
            persist_security_block_connection(&mut self.connection, reason)?;
            bail!("secure mesh KT terminal freshness block persisted: {reason}");
        }
        let freshness = verify_kt_inclusion(
            &inclusion,
            &pin,
            self.freshness_policy,
            effective_now_epoch_seconds,
        )?;
        ensure!(
            inclusion.leaf_hash
                == hex_encode(&map_root_log_leaf_hash(
                    &inclusion.signed_tree_head.map_root_hash,
                )?),
            "secure mesh KT persisted append-log proof does not commit the map root"
        );
        verify_kt_map_inclusion(
            &map_proof,
            stable_label,
            &persisted.1,
            directory_version,
            persisted.2,
            &pin,
            self.freshness_policy,
            effective_now_epoch_seconds,
        )?;
        ensure!(
            observed_at_epoch_seconds
                <= effective_now_epoch_seconds
                    .saturating_add(self.freshness_policy.max_future_skew_seconds)
                && effective_now_epoch_seconds
                    <= observed_at_epoch_seconds
                        .saturating_add(self.freshness_policy.max_sth_age_seconds),
            "secure mesh KT purpose authorization observation is stale or from the future"
        );
        ensure!(
            freshness.issued_at_epoch_seconds == issued_at_epoch_seconds,
            "secure mesh KT persisted authorization freshness binding is invalid"
        );
        require_fresh_gossip_checkpoint_transaction(
            &transaction,
            &pin,
            &latest,
            self.freshness_policy,
            effective_now_epoch_seconds,
        )?;
        transaction.commit()?;
        Ok(SecureMeshKtAuthorizationReceipt {
            stable_label: stable_label.to_string(),
            purpose: purpose.to_string(),
            directory_version,
            leaf_hash: persisted.1,
            revoked: persisted.2,
            tree_size,
            root_hash: persisted.4,
            map_root_hash: persisted.5,
            issued_at_epoch_seconds,
            observed_at_epoch_seconds,
            validated_at_epoch_seconds: effective_now_epoch_seconds,
            expires_at_epoch_seconds: issued_at_epoch_seconds
                .saturating_add(self.freshness_policy.max_sth_age_seconds),
            identity_fingerprint: latest_directory.4,
            identity_rotation_epoch: sql_to_u64(
                latest_directory.5,
                "directory identity rotation epoch",
            )?,
            identity_key_digest: latest_directory.6,
            pairwise_prekey_version: sql_to_u64(
                latest_directory.7,
                "directory pairwise prekey version",
            )?,
            signed_prekey_digest: latest_directory.8,
            one_time_prekey_digest: latest_directory.9,
            mls_key_package_version: sql_to_u64(
                latest_directory.10,
                "directory MLS KeyPackage version",
            )?,
            mls_key_package_digest: latest_directory.11,
        })
    }

    pub(crate) fn authorize_absence_view(
        &mut self,
        stable_label: &str,
        map_root_inclusion: &SecureMeshKtInclusionProof,
        map_proof: &SecureMeshKtMapProof,
        consistency: Option<&SecureMeshKtConsistencyProof>,
        now_epoch_seconds: u64,
    ) -> Result<(SecureMeshKtCachedCheckpoint, VerifiedKtFreshness)> {
        let pin = self.pin()?.clone();
        let effective_now_epoch_seconds =
            advance_durable_time_watermark(&mut self.connection, now_epoch_seconds)?;
        verify_authenticated_sth_freshness_or_block(
            &mut self.connection,
            &pin,
            self.freshness_policy,
            &map_root_inclusion.signed_tree_head,
            effective_now_epoch_seconds,
        )?;
        verify_kt_inclusion(
            map_root_inclusion,
            &pin,
            self.freshness_policy,
            effective_now_epoch_seconds,
        )?;
        ensure!(
            map_root_inclusion.signed_tree_head == map_proof.signed_tree_head,
            "secure mesh KT absence log and map proofs do not share one signed tree head"
        );
        ensure!(
            map_root_inclusion.leaf_hash
                == hex_encode(&map_root_log_leaf_hash(
                    &map_proof.signed_tree_head.map_root_hash,
                )?),
            "secure mesh KT absence append-log inclusion does not commit the authenticated map root"
        );
        let freshness = verify_kt_non_inclusion(
            map_proof,
            stable_label,
            &pin,
            self.freshness_policy,
            effective_now_epoch_seconds,
        )?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let checkpoint = match advance_checkpoint_transaction(
            &transaction,
            &pin,
            self.freshness_policy,
            &map_proof.signed_tree_head,
            consistency,
            effective_now_epoch_seconds,
        )? {
            CheckpointTransition::Accepted(checkpoint) => checkpoint,
            CheckpointTransition::SecurityBlock(reason) => {
                transaction.commit()?;
                bail!("secure mesh KT security block persisted: {reason}")
            }
        };
        require_fresh_gossip_observation_transaction(
            &transaction,
            &pin,
            &map_proof.signed_tree_head,
            self.freshness_policy,
            effective_now_epoch_seconds,
        )?;
        let previously_present = transaction
            .query_row(
                "SELECT 1 FROM secure_mesh_kt_directory_latest WHERE log_id = ?1 AND stable_label = ?2",
                params![pin.log_id(), stable_label],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if previously_present {
            persist_security_block(&transaction, "directory_present_to_absent")?;
            transaction.commit()?;
            bail!(
                "secure mesh KT security block persisted: previously present directory label became absent"
            )
        }
        transaction.commit()?;
        Ok((checkpoint, freshness))
    }
}

/// Destructively clear one local verifier database during an explicitly guarded authority reset.
/// The reset is transactional inside SQLite, so WAL/SHM state is reconciled by SQLite rather than
/// by unlinking database sidecars. Callers must hold their own persistent fail-closed reset guard
/// until the new pin/scope configuration has been durably committed.
pub fn reset_kt_persistent_authority_state(path: impl AsRef<Path>) -> Result<()> {
    let mut connection = Connection::open(path)
        .map_err(|_| anyhow!("secure mesh KT authority reset database open failed"))?;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| anyhow!("secure mesh KT authority reset transaction failed"))?;
    transaction.execute_batch(
        r#"
        DROP TABLE IF EXISTS secure_mesh_kt_configuration;
        DROP TABLE IF EXISTS secure_mesh_kt_guard;
        DROP TABLE IF EXISTS secure_mesh_kt_time_guard;
        DROP TABLE IF EXISTS secure_mesh_kt_checkpoints;
        DROP TABLE IF EXISTS secure_mesh_kt_directory_latest;
        DROP TABLE IF EXISTS secure_mesh_kt_directory_authorizations;
        DROP TABLE IF EXISTS secure_mesh_kt_gossip_observations;
        PRAGMA user_version = 0;
        "#,
    )?;
    transaction.commit()?;
    Ok(())
}

pub fn verify_kt_inclusion(
    proof: &SecureMeshKtInclusionProof,
    pin: &PinnedKtLogKey,
    freshness_policy: KtFreshnessPolicy,
    now_epoch_seconds: u64,
) -> Result<VerifiedKtFreshness> {
    let freshness = proof
        .signed_tree_head
        .verify(pin, freshness_policy, now_epoch_seconds)?;
    ensure!(
        proof.tree_size == proof.signed_tree_head.tree_size,
        "secure mesh KT inclusion tree size mismatch"
    );
    ensure!(
        proof.tree_size > 0,
        "secure mesh KT inclusion tree is empty"
    );
    ensure!(
        proof.leaf_index < proof.tree_size,
        "secure mesh KT inclusion leaf index is out of range"
    );
    ensure!(
        proof.siblings.len() <= MAX_INCLUSION_PROOF_HASHES,
        "secure mesh KT inclusion proof has too many hashes"
    );
    let leaf = parse_hash(&proof.leaf_hash)?;
    let path = parse_hash_path(&proof.siblings, MAX_INCLUSION_PROOF_HASHES)?;
    let root = fold_rfc9162_inclusion(leaf, proof.leaf_index, proof.tree_size, &path)?;
    ensure!(
        hex_encode(&root) == proof.signed_tree_head.root_hash,
        "secure mesh KT inclusion root mismatch"
    );
    Ok(freshness)
}

pub fn verify_kt_consistency(
    proof: &SecureMeshKtConsistencyProof,
    pin: &PinnedKtLogKey,
    freshness_policy: KtFreshnessPolicy,
    now_epoch_seconds: u64,
    cached: &SecureMeshKtCachedCheckpoint,
) -> Result<SecureMeshKtCachedCheckpoint> {
    proof
        .second_signed_tree_head
        .verify(pin, freshness_policy, now_epoch_seconds)?;
    ensure!(
        proof.first_tree_size == cached.tree_size,
        "secure mesh KT consistency cached tree size mismatch"
    );
    ensure!(
        proof.first_root_hash == cached.root_hash,
        "secure mesh KT consistency cached root mismatch"
    );
    ensure!(
        proof.second_tree_size == proof.second_signed_tree_head.tree_size,
        "secure mesh KT consistency second tree size mismatch"
    );
    ensure!(
        proof.first_tree_size <= proof.second_tree_size,
        "secure mesh KT consistency sizes are invalid"
    );
    ensure!(
        proof.first_tree_size <= KT_JSON_SAFE_INTEGER_MAX
            && proof.second_tree_size <= KT_JSON_SAFE_INTEGER_MAX,
        "secure mesh KT consistency size exceeds the cross-language safe range"
    );
    ensure!(
        proof.path.len() <= MAX_CONSISTENCY_PROOF_HASHES,
        "secure mesh KT consistency proof has too many hashes"
    );
    let first_root = parse_hash(&proof.first_root_hash)?;
    let second_root = parse_hash(&proof.second_signed_tree_head.root_hash)?;
    let path = parse_hash_path(&proof.path, MAX_CONSISTENCY_PROOF_HASHES)?;
    verify_rfc9162_consistency(
        proof.first_tree_size,
        proof.second_tree_size,
        first_root,
        second_root,
        &path,
    )?;
    Ok(checkpoint_from_sth(&proof.second_signed_tree_head))
}

pub fn verify_kt_map_inclusion(
    proof: &SecureMeshKtMapProof,
    expected_stable_label: &str,
    expected_leaf_hash: &str,
    expected_version: u64,
    expected_revoked: bool,
    pin: &PinnedKtLogKey,
    freshness_policy: KtFreshnessPolicy,
    now_epoch_seconds: u64,
) -> Result<VerifiedKtFreshness> {
    ensure!(
        proof.stable_label == expected_stable_label,
        "secure mesh KT sparse-map label substitution detected"
    );
    let entry = proof
        .entry
        .as_ref()
        .ok_or_else(|| anyhow!("secure mesh KT sparse-map entry is absent"))?;
    ensure!(
        entry.leaf_hash == expected_leaf_hash,
        "secure mesh KT sparse-map leaf is not latest"
    );
    ensure!(
        entry.version == expected_version,
        "secure mesh KT sparse-map version is not latest"
    );
    ensure!(
        entry.revoked == expected_revoked,
        "secure mesh KT sparse-map revocation state mismatch"
    );
    verify_kt_map_proof(proof, pin, freshness_policy, now_epoch_seconds)
}

pub fn verify_kt_non_inclusion(
    proof: &SecureMeshKtNonInclusionProof,
    expected_stable_label: &str,
    pin: &PinnedKtLogKey,
    freshness_policy: KtFreshnessPolicy,
    now_epoch_seconds: u64,
) -> Result<VerifiedKtFreshness> {
    ensure!(
        proof.stable_label == expected_stable_label,
        "secure mesh KT sparse-map label substitution detected"
    );
    ensure!(
        proof.entry.is_none(),
        "secure mesh KT sparse-map label is present; non-inclusion rejected"
    );
    verify_kt_map_proof(proof, pin, freshness_policy, now_epoch_seconds)
}

fn verify_kt_map_proof(
    proof: &SecureMeshKtMapProof,
    pin: &PinnedKtLogKey,
    freshness_policy: KtFreshnessPolicy,
    now_epoch_seconds: u64,
) -> Result<VerifiedKtFreshness> {
    let freshness = proof
        .signed_tree_head
        .verify(pin, freshness_policy, now_epoch_seconds)?;
    validate_hex_hash("stable_label", &proof.stable_label)?;
    ensure!(
        proof.siblings.len() == SPARSE_MAP_DEPTH,
        "secure mesh KT sparse-map proof depth is invalid"
    );
    let key = sparse_map_key(&proof.stable_label);
    let mut current = match &proof.entry {
        Some(entry) => {
            validate_hex_hash("map leaf_hash", &entry.leaf_hash)?;
            ensure!(
                entry.version <= KT_JSON_SAFE_INTEGER_MAX,
                "secure mesh KT sparse-map version exceeds the cross-language safe range"
            );
            sparse_map_leaf_hash(&key, entry)
        }
        None => sparse_map_default_hashes()[SPARSE_MAP_DEPTH],
    };
    let siblings = parse_hash_path(&proof.siblings, SPARSE_MAP_DEPTH)?;
    for (offset, sibling) in siblings.iter().enumerate() {
        let depth = SPARSE_MAP_DEPTH - 1 - offset;
        current = if bit_at(&key, depth) == 0 {
            sparse_map_node_hash(&current, sibling)
        } else {
            sparse_map_node_hash(sibling, &current)
        };
    }
    ensure!(
        hex_encode(&current) == proof.signed_tree_head.map_root_hash,
        "secure mesh KT sparse-map root mismatch"
    );
    Ok(freshness)
}

/// Diagnostic-only unsigned hash-chain helper. It cannot construct an authorized leaf.
pub fn diagnostic_hash_chain_tree_head(previous_tree_head: &str, leaf_hash: &str) -> String {
    let previous = if previous_tree_head.is_empty() {
        "GENESIS"
    } else {
        previous_tree_head
    };
    hex_encode(&Sha256::digest(
        format!("{previous}:{leaf_hash}").as_bytes(),
    ))
}

enum CheckpointTransition {
    Accepted(SecureMeshKtCachedCheckpoint),
    SecurityBlock(&'static str),
}

fn initialize_kt_schema(connection: &Connection) -> Result<()> {
    let schema_version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    let existing_kt_tables: i64 = connection.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name LIKE 'secure_mesh_kt_%'",
        [],
        |row| row.get(0),
    )?;
    if schema_version == 0 && existing_kt_tables > 0 {
        bail!(
            "secure mesh KT state schema is unversioned or legacy; explicit security reset and re-pairing are required"
        );
    }
    ensure!(
        matches!(
            schema_version,
            0 | KT_OLDEST_SUPPORTED_SCHEMA_VERSION
                | KT_LEGACY_SCHEMA_VERSION
                | KT_PREVIOUS_SCHEMA_VERSION
                | KT_SCHEMA_VERSION
        ),
        "secure mesh KT state schema version is unsupported; explicit security reset and re-pairing are required"
    );
    connection
        .execute_batch(KT_SCHEMA)
        .map_err(|error| anyhow!("secure mesh KT state schema failed: {error}"))?;
    if matches!(
        schema_version,
        KT_OLDEST_SUPPORTED_SCHEMA_VERSION | KT_LEGACY_SCHEMA_VERSION | KT_PREVIOUS_SCHEMA_VERSION
    ) {
        migrate_gossip_observation_binding(connection)?;
    }
    if schema_version == 0
        || schema_version == KT_OLDEST_SUPPORTED_SCHEMA_VERSION
        || schema_version == KT_LEGACY_SCHEMA_VERSION
        || schema_version == KT_PREVIOUS_SCHEMA_VERSION
    {
        connection.pragma_update(None, "user_version", KT_SCHEMA_VERSION)?;
    }
    let required_time_guard_columns = ["singleton", "max_observed_epoch_seconds"];
    let mut statement = connection.prepare("PRAGMA table_info(secure_mesh_kt_time_guard)")?;
    let time_guard_columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<std::collections::BTreeSet<_>>>()?;
    ensure!(
        required_time_guard_columns
            .iter()
            .all(|column| time_guard_columns.contains(*column)),
        "secure mesh KT time guard schema is incomplete; explicit security reset and re-pairing are required"
    );
    let required_latest_columns = [
        "log_id",
        "stable_label",
        "version",
        "leaf_hash",
        "revoked",
        "identity_fingerprint",
        "identity_rotation_epoch",
        "identity_key_digest",
        "pairwise_prekey_version",
        "signed_prekey_digest",
        "one_time_prekey_digest",
        "mls_key_package_version",
        "mls_key_package_digest",
        "tree_size",
    ];
    let mut statement = connection.prepare("PRAGMA table_info(secure_mesh_kt_directory_latest)")?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<std::collections::BTreeSet<_>>>()?;
    ensure!(
        required_latest_columns
            .iter()
            .all(|column| columns.contains(*column)),
        "secure mesh KT state schema is incomplete; explicit security reset and re-pairing are required"
    );
    let required_authorization_columns = [
        "log_id",
        "stable_label",
        "purpose",
        "directory_version",
        "leaf_hash",
        "revoked",
        "tree_size",
        "root_hash",
        "map_root_hash",
        "issued_at_epoch_seconds",
        "observed_at_epoch_seconds",
        "inclusion_json",
        "map_proof_json",
    ];
    let mut statement =
        connection.prepare("PRAGMA table_info(secure_mesh_kt_directory_authorizations)")?;
    let authorization_columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<std::collections::BTreeSet<_>>>()?;
    ensure!(
        required_authorization_columns
            .iter()
            .all(|column| authorization_columns.contains(*column)),
        "secure mesh KT authorization schema is incomplete; explicit security reset and re-pairing are required"
    );
    let required_gossip_columns = [
        "log_id",
        "tree_size",
        "root_hash",
        "map_root_hash",
        "issued_at_epoch_seconds",
        "observed_at_epoch_seconds",
    ];
    let mut statement =
        connection.prepare("PRAGMA table_info(secure_mesh_kt_gossip_observations)")?;
    let gossip_columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<std::collections::BTreeSet<_>>>()?;
    ensure!(
        required_gossip_columns
            .iter()
            .all(|column| gossip_columns.contains(*column)),
        "secure mesh KT gossip schema is incomplete; explicit security reset and re-pairing are required"
    );
    Ok(())
}

fn migrate_gossip_observation_binding(connection: &Connection) -> Result<()> {
    // Issuance time is authenticated by the STH signature, so it is part of the observation
    // identity rather than mutable metadata. Preserve every previously observed head while
    // replacing the superseded four-column key atomically.
    connection
        .execute_batch(
            r#"
            BEGIN IMMEDIATE;
            ALTER TABLE secure_mesh_kt_gossip_observations
                RENAME TO secure_mesh_kt_gossip_observations_superseded;
            CREATE TABLE secure_mesh_kt_gossip_observations (
                log_id TEXT NOT NULL,
                tree_size INTEGER NOT NULL CHECK (tree_size >= 0),
                root_hash TEXT NOT NULL,
                map_root_hash TEXT NOT NULL,
                issued_at_epoch_seconds INTEGER NOT NULL CHECK (issued_at_epoch_seconds >= 0),
                observed_at_epoch_seconds INTEGER NOT NULL CHECK (observed_at_epoch_seconds >= 0),
                PRIMARY KEY (
                    log_id, tree_size, root_hash, map_root_hash, issued_at_epoch_seconds
                )
            );
            INSERT INTO secure_mesh_kt_gossip_observations(
                log_id, tree_size, root_hash, map_root_hash,
                issued_at_epoch_seconds, observed_at_epoch_seconds
            )
            SELECT
                log_id, tree_size, root_hash, map_root_hash,
                issued_at_epoch_seconds, observed_at_epoch_seconds
            FROM secure_mesh_kt_gossip_observations_superseded;
            DROP TABLE secure_mesh_kt_gossip_observations_superseded;
            CREATE INDEX secure_mesh_kt_gossip_observed_idx
                ON secure_mesh_kt_gossip_observations(log_id, observed_at_epoch_seconds);
            COMMIT;
            "#,
        )
        .map_err(|error| anyhow!("secure mesh KT gossip schema migration failed: {error}"))?;
    Ok(())
}

fn initialize_or_validate_pin(connection: &Connection, pin: &PinnedKtLogKey) -> Result<()> {
    let existing = connection
        .query_row(
            "SELECT protocol_version, log_id, key_id, public_key_hex, provenance FROM secure_mesh_kt_configuration WHERE singleton = 1",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            },
        )
        .optional()?;
    if let Some((protocol, log_id, key_id, public_key, provenance)) = existing {
        ensure!(
            protocol == SECURE_MESH_KT_PROTOCOL_VERSION
                && log_id == pin.log_id
                && key_id == pin.key_id
                && public_key == pin.public_key_hex()
                && provenance == pin.provenance.stable_code(),
            "secure mesh KT persisted pin does not match configured authority"
        );
    } else {
        connection.execute(
            "INSERT INTO secure_mesh_kt_configuration(singleton, protocol_version, log_id, key_id, public_key_hex, provenance) VALUES(1, ?1, ?2, ?3, ?4, ?5)",
            params![
                SECURE_MESH_KT_PROTOCOL_VERSION,
                pin.log_id,
                pin.key_id,
                pin.public_key_hex(),
                pin.provenance.stable_code(),
            ],
        )?;
    }
    Ok(())
}

fn latest_checkpoint_connection(
    connection: &Connection,
    log_id: &str,
) -> Result<Option<SecureMeshKtCachedCheckpoint>> {
    connection
        .query_row(
            "SELECT tree_size, root_hash, map_root_hash, issued_at_epoch_seconds FROM secure_mesh_kt_checkpoints WHERE log_id = ?1 ORDER BY tree_size DESC LIMIT 1",
            params![log_id],
            |row| {
                let tree_size = row.get::<_, i64>(0)?;
                let issued = row.get::<_, i64>(3)?;
                Ok(SecureMeshKtCachedCheckpoint {
                    tree_size: u64::try_from(tree_size).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Integer,
                            Box::new(error),
                        )
                    })?,
                    root_hash: row.get(1)?,
                    map_root_hash: row.get(2)?,
                    issued_at_epoch_seconds: u64::try_from(issued).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            3,
                            rusqlite::types::Type::Integer,
                            Box::new(error),
                        )
                    })?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn persist_gossip_observation_transaction(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    sth: &SecureMeshSignedTreeHead,
    observed_at_epoch_seconds: u64,
) -> Result<()> {
    ensure!(
        sth.log_id == pin.log_id() && sth.key_id == pin.key_id(),
        "secure mesh KT gossip observation authority binding is invalid"
    );
    transaction.execute(
        r#"
        INSERT INTO secure_mesh_kt_gossip_observations(
            log_id, tree_size, root_hash, map_root_hash,
            issued_at_epoch_seconds, observed_at_epoch_seconds
        ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(
            log_id, tree_size, root_hash, map_root_hash, issued_at_epoch_seconds
        ) DO UPDATE SET
            observed_at_epoch_seconds = MAX(
                observed_at_epoch_seconds,
                excluded.observed_at_epoch_seconds
            )
        "#,
        params![
            pin.log_id(),
            u64_to_sql(sth.tree_size)?,
            sth.root_hash,
            sth.map_root_hash,
            u64_to_sql(sth.issued_at_epoch_seconds)?,
            u64_to_sql(observed_at_epoch_seconds)?,
        ],
    )?;
    transaction.execute(
        r#"
        DELETE FROM secure_mesh_kt_gossip_observations
        WHERE log_id = ?1 AND rowid NOT IN (
            SELECT rowid FROM secure_mesh_kt_gossip_observations
            WHERE log_id = ?1
            ORDER BY tree_size DESC, observed_at_epoch_seconds DESC
            LIMIT ?2
        )
        "#,
        params![pin.log_id(), u64_to_sql(MAX_PERSISTED_GOSSIP_OBSERVATIONS)?],
    )?;
    Ok(())
}

fn require_fresh_gossip_checkpoint_transaction(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    checkpoint: &SecureMeshKtCachedCheckpoint,
    freshness_policy: KtFreshnessPolicy,
    now_epoch_seconds: u64,
) -> Result<()> {
    require_fresh_gossip_binding_transaction(
        transaction,
        pin,
        checkpoint.tree_size,
        &checkpoint.root_hash,
        &checkpoint.map_root_hash,
        checkpoint.issued_at_epoch_seconds,
        freshness_policy,
        now_epoch_seconds,
    )
}

fn require_fresh_gossip_observation_transaction(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    sth: &SecureMeshSignedTreeHead,
    freshness_policy: KtFreshnessPolicy,
    now_epoch_seconds: u64,
) -> Result<()> {
    require_fresh_gossip_binding_transaction(
        transaction,
        pin,
        sth.tree_size,
        &sth.root_hash,
        &sth.map_root_hash,
        sth.issued_at_epoch_seconds,
        freshness_policy,
        now_epoch_seconds,
    )
}

#[allow(clippy::too_many_arguments)]
fn require_fresh_gossip_binding_transaction(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    tree_size: u64,
    root_hash: &str,
    map_root_hash: &str,
    issued_at_epoch_seconds: u64,
    freshness_policy: KtFreshnessPolicy,
    now_epoch_seconds: u64,
) -> Result<()> {
    let observation = transaction
        .query_row(
            r#"
            SELECT issued_at_epoch_seconds, observed_at_epoch_seconds
            FROM secure_mesh_kt_gossip_observations
            WHERE log_id = ?1 AND tree_size = ?2
              AND root_hash = ?3 AND map_root_hash = ?4
              AND issued_at_epoch_seconds = ?5
            "#,
            params![
                pin.log_id(),
                u64_to_sql(tree_size)?,
                root_hash,
                map_root_hash,
                u64_to_sql(issued_at_epoch_seconds)?,
            ],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?
        .ok_or_else(|| {
            anyhow!(
                "secure mesh KT fresh peer-gossip or witness observation is required before authorization"
            )
        })?;
    let observed_issued = sql_to_u64(observation.0, "gossip issue time")?;
    let observed_at = sql_to_u64(observation.1, "gossip observation time")?;
    let max_gossip_age_seconds = freshness_policy
        .max_sth_age_seconds
        .min(KT_PROTOCOL_MAX_GOSSIP_AGE_SECONDS);
    ensure!(
        observed_issued == issued_at_epoch_seconds,
        "secure mesh KT gossip observation signed-tree-head binding is invalid"
    );
    ensure!(
        observed_at <= now_epoch_seconds.saturating_add(freshness_policy.max_future_skew_seconds)
            && now_epoch_seconds <= observed_at.saturating_add(max_gossip_age_seconds),
        "secure mesh KT peer-gossip or witness observation is stale or from the future"
    );
    Ok(())
}

fn advance_checkpoint_transaction(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    freshness_policy: KtFreshnessPolicy,
    sth: &SecureMeshSignedTreeHead,
    consistency: Option<&SecureMeshKtConsistencyProof>,
    now_epoch_seconds: u64,
) -> Result<CheckpointTransition> {
    let blocked = transaction.query_row(
        "SELECT blocked FROM secure_mesh_kt_guard WHERE singleton = 1",
        [],
        |row| row.get::<_, i64>(0),
    )? != 0;
    ensure!(
        !blocked,
        "secure mesh KT equivocation was previously persisted; authorization is blocked"
    );
    let latest = latest_checkpoint_connection(transaction, pin.log_id())?;
    if let Some(cached) = &latest {
        if sth.tree_size < cached.tree_size {
            persist_security_block(transaction, "tree_rollback")?;
            return Ok(CheckpointTransition::SecurityBlock("tree rollback"));
        }
        if sth.tree_size == cached.tree_size {
            if sth.root_hash != cached.root_hash || sth.map_root_hash != cached.map_root_hash {
                persist_security_block(transaction, "same_size_split_view")?;
                return Ok(CheckpointTransition::SecurityBlock("same-size split view"));
            }
            transaction.execute(
                "UPDATE secure_mesh_kt_checkpoints SET issued_at_epoch_seconds = MAX(issued_at_epoch_seconds, ?1) WHERE log_id = ?2 AND tree_size = ?3",
                params![u64_to_sql(sth.issued_at_epoch_seconds)?, pin.log_id(), u64_to_sql(sth.tree_size)?],
            )?;
            return Ok(CheckpointTransition::Accepted(checkpoint_from_sth(sth)));
        }

        let proof = consistency.ok_or_else(|| {
            anyhow!("secure mesh KT consistency proof is required for tree advance")
        })?;
        ensure!(
            proof.second_signed_tree_head == *sth,
            "secure mesh KT consistency proof targets a different signed tree head"
        );
        verify_kt_consistency(proof, pin, freshness_policy, now_epoch_seconds, cached)?;
    }

    transaction.execute(
        "INSERT INTO secure_mesh_kt_checkpoints(log_id, tree_size, root_hash, map_root_hash, issued_at_epoch_seconds, key_id) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            pin.log_id(),
            u64_to_sql(sth.tree_size)?,
            sth.root_hash,
            sth.map_root_hash,
            u64_to_sql(sth.issued_at_epoch_seconds)?,
            pin.key_id(),
        ],
    )?;
    transaction.execute(
        "DELETE FROM secure_mesh_kt_checkpoints
         WHERE log_id = ?1 AND tree_size NOT IN (
             SELECT tree_size FROM secure_mesh_kt_checkpoints
             WHERE log_id = ?1 ORDER BY tree_size DESC LIMIT ?2
         )",
        params![pin.log_id(), u64_to_sql(MAX_PERSISTED_CHECKPOINTS)?],
    )?;
    Ok(CheckpointTransition::Accepted(checkpoint_from_sth(sth)))
}

fn enforce_directory_latest_transaction(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    stable_label: &str,
    version: u64,
    leaf_hash: &str,
    revoked: bool,
    components: &DirectoryComponentCommitments<'_>,
    tree_size: u64,
) -> Result<Option<&'static str>> {
    enforce_directory_label_quota(transaction, pin, stable_label)?;
    let prior = transaction
        .query_row(
            "SELECT version, leaf_hash, revoked, identity_fingerprint, identity_rotation_epoch, identity_key_digest, pairwise_prekey_version, signed_prekey_digest, one_time_prekey_digest, mls_key_package_version, mls_key_package_digest FROM secure_mesh_kt_directory_latest WHERE log_id = ?1 AND stable_label = ?2",
            params![pin.log_id(), stable_label],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? != 0,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, String>(8)?,
                    row.get::<_, i64>(9)?,
                    row.get::<_, String>(10)?,
                ))
            },
        )
        .optional()?;
    if let Some((
        prior_version_raw,
        prior_leaf_hash,
        prior_revoked,
        prior_identity_fingerprint,
        prior_identity_rotation_raw,
        prior_identity_key_digest,
        prior_pairwise_version_raw,
        prior_signed_prekey_digest,
        prior_one_time_prekey_digest,
        prior_mls_version_raw,
        prior_mls_digest,
    )) = prior
    {
        let prior_version = u64::try_from(prior_version_raw)
            .map_err(|_| anyhow!("secure mesh KT persisted directory version is invalid"))?;
        let prior_pairwise_version = u64::try_from(prior_pairwise_version_raw)
            .map_err(|_| anyhow!("secure mesh KT persisted Pairwise prekey version is invalid"))?;
        let prior_mls_version = u64::try_from(prior_mls_version_raw)
            .map_err(|_| anyhow!("secure mesh KT persisted MLS KeyPackage version is invalid"))?;
        let prior_identity_rotation = u64::try_from(prior_identity_rotation_raw)
            .map_err(|_| anyhow!("secure mesh KT persisted identity rotation epoch is invalid"))?;
        let reason = if version < prior_version {
            Some(("directory_version_rollback", "directory version rollback"))
        } else if version == prior_version
            && (leaf_hash != prior_leaf_hash || revoked != prior_revoked)
        {
            Some((
                "directory_same_version_split",
                "directory same-version split view",
            ))
        } else if prior_revoked && !revoked {
            Some((
                "directory_revoked_resurrection",
                "revoked identity resurrection",
            ))
        } else if components.identity_rotation_epoch < prior_identity_rotation {
            Some((
                "identity_rotation_epoch_rollback",
                "identity rotation epoch rollback",
            ))
        } else if components.identity_key_digest == prior_identity_key_digest
            && (components.identity_rotation_epoch != prior_identity_rotation
                || components.identity_fingerprint != prior_identity_fingerprint)
        {
            Some((
                "identity_epoch_changed_without_key_change",
                "identity epoch changed without identity material change",
            ))
        } else if components.identity_key_digest != prior_identity_key_digest
            && components.identity_rotation_epoch <= prior_identity_rotation
        {
            Some((
                "identity_key_changed_without_epoch_advance",
                "identity key changed without strict rotation epoch advance",
            ))
        } else if components.pairwise_prekey_version < prior_pairwise_version {
            Some((
                "pairwise_prekey_version_rollback",
                "Pairwise prekey version rollback",
            ))
        } else if components.pairwise_prekey_version == prior_pairwise_version
            && (components.signed_prekey_digest != prior_signed_prekey_digest
                || components.one_time_prekey_digest != prior_one_time_prekey_digest)
        {
            Some((
                "pairwise_prekey_same_version_split",
                "Pairwise prekey same-version split view",
            ))
        } else if components.mls_key_package_version < prior_mls_version {
            Some((
                "mls_key_package_version_rollback",
                "MLS KeyPackage version rollback",
            ))
        } else if components.mls_key_package_version == prior_mls_version
            && components.mls_key_package_digest != prior_mls_digest
        {
            Some((
                "mls_key_package_same_version_split",
                "MLS KeyPackage same-version split view",
            ))
        } else {
            None
        };
        if let Some((code, message)) = reason {
            persist_security_block(transaction, code)?;
            return Ok(Some(message));
        }
    }
    transaction.execute(
        "INSERT INTO secure_mesh_kt_directory_latest(log_id, stable_label, version, leaf_hash, revoked, identity_fingerprint, identity_rotation_epoch, identity_key_digest, pairwise_prekey_version, signed_prekey_digest, one_time_prekey_digest, mls_key_package_version, mls_key_package_digest, tree_size) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
         ON CONFLICT(log_id, stable_label) DO UPDATE SET version = excluded.version, leaf_hash = excluded.leaf_hash, revoked = excluded.revoked, identity_fingerprint = excluded.identity_fingerprint, identity_rotation_epoch = excluded.identity_rotation_epoch, identity_key_digest = excluded.identity_key_digest, pairwise_prekey_version = excluded.pairwise_prekey_version, signed_prekey_digest = excluded.signed_prekey_digest, one_time_prekey_digest = excluded.one_time_prekey_digest, mls_key_package_version = excluded.mls_key_package_version, mls_key_package_digest = excluded.mls_key_package_digest, tree_size = excluded.tree_size",
        params![
            pin.log_id(),
            stable_label,
            u64_to_sql(version)?,
            leaf_hash,
            i64::from(revoked),
            components.identity_fingerprint,
            u64_to_sql(components.identity_rotation_epoch)?,
            components.identity_key_digest,
            u64_to_sql(components.pairwise_prekey_version)?,
            components.signed_prekey_digest,
            components.one_time_prekey_digest,
            u64_to_sql(components.mls_key_package_version)?,
            components.mls_key_package_digest,
            u64_to_sql(tree_size)?,
        ],
    )?;
    Ok(None)
}

#[allow(clippy::too_many_arguments)]
fn persist_directory_authorization_transaction(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    stable_label: &str,
    purpose: &str,
    directory_version: u64,
    leaf_hash: &str,
    revoked: bool,
    inclusion: &SecureMeshKtInclusionProof,
    map_proof: &SecureMeshKtMapProof,
    freshness: &VerifiedKtFreshness,
) -> Result<()> {
    reclaim_stale_directory_authorizations(transaction, pin, inclusion.signed_tree_head.tree_size)?;
    enforce_directory_authorization_quota(transaction, pin, stable_label, purpose)?;
    let inclusion_json = serde_json::to_string(inclusion)?;
    let map_proof_json = serde_json::to_string(map_proof)?;
    transaction.execute(
        "INSERT INTO secure_mesh_kt_directory_authorizations(
            log_id, stable_label, purpose, directory_version, leaf_hash, revoked,
            tree_size, root_hash, map_root_hash, issued_at_epoch_seconds,
            observed_at_epoch_seconds, inclusion_json, map_proof_json
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
         ON CONFLICT(log_id, stable_label, purpose) DO UPDATE SET
            directory_version = excluded.directory_version,
            leaf_hash = excluded.leaf_hash,
            revoked = excluded.revoked,
            tree_size = excluded.tree_size,
            root_hash = excluded.root_hash,
            map_root_hash = excluded.map_root_hash,
            issued_at_epoch_seconds = excluded.issued_at_epoch_seconds,
            observed_at_epoch_seconds = excluded.observed_at_epoch_seconds,
            inclusion_json = excluded.inclusion_json,
            map_proof_json = excluded.map_proof_json",
        params![
            pin.log_id(),
            stable_label,
            purpose,
            u64_to_sql(directory_version)?,
            leaf_hash,
            i64::from(revoked),
            u64_to_sql(inclusion.signed_tree_head.tree_size)?,
            inclusion.signed_tree_head.root_hash,
            inclusion.signed_tree_head.map_root_hash,
            u64_to_sql(inclusion.signed_tree_head.issued_at_epoch_seconds)?,
            u64_to_sql(freshness.observed_at_epoch_seconds)?,
            inclusion_json,
            map_proof_json,
        ],
    )?;
    Ok(())
}

fn enforce_directory_label_quota(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    stable_label: &str,
) -> Result<()> {
    let exists = transaction
        .query_row(
            "SELECT 1 FROM secure_mesh_kt_directory_latest WHERE log_id = ?1 AND stable_label = ?2",
            params![pin.log_id(), stable_label],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if exists {
        return Ok(());
    }
    let count: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM secure_mesh_kt_directory_latest WHERE log_id = ?1",
        params![pin.log_id()],
        |row| row.get(0),
    )?;
    ensure!(
        sql_to_u64(count, "directory label count")? < MAX_PERSISTED_DIRECTORY_LABELS,
        "secure mesh KT directory label quota is exhausted"
    );
    Ok(())
}

fn reclaim_stale_directory_authorizations(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    current_tree_size: u64,
) -> Result<()> {
    transaction.execute(
        "DELETE FROM secure_mesh_kt_directory_authorizations WHERE log_id = ?1 AND tree_size <> ?2",
        params![pin.log_id(), u64_to_sql(current_tree_size)?],
    )?;
    Ok(())
}

fn enforce_directory_authorization_quota(
    transaction: &Transaction<'_>,
    pin: &PinnedKtLogKey,
    stable_label: &str,
    purpose: &str,
) -> Result<()> {
    let exists = transaction
        .query_row(
            "SELECT 1 FROM secure_mesh_kt_directory_authorizations WHERE log_id = ?1 AND stable_label = ?2 AND purpose = ?3",
            params![pin.log_id(), stable_label, purpose],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if exists {
        return Ok(());
    }
    let count: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM secure_mesh_kt_directory_authorizations WHERE log_id = ?1",
        params![pin.log_id()],
        |row| row.get(0),
    )?;
    ensure!(
        sql_to_u64(count, "directory authorization count")?
            < MAX_PERSISTED_DIRECTORY_AUTHORIZATIONS,
        "secure mesh KT directory authorization quota is exhausted"
    );
    Ok(())
}

fn persist_security_block(transaction: &Transaction<'_>, reason_code: &str) -> Result<()> {
    transaction.execute(
        "UPDATE secure_mesh_kt_guard SET blocked = 1, reason_code = ?1 WHERE singleton = 1",
        params![reason_code],
    )?;
    Ok(())
}

fn advance_durable_time_watermark(
    connection: &mut Connection,
    now_epoch_seconds: u64,
) -> Result<u64> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if now_epoch_seconds > KT_JSON_SAFE_INTEGER_MAX {
        persist_security_block(&transaction, "local_clock_out_of_range")?;
        transaction.commit()?;
        bail!(
            "secure mesh KT terminal freshness block persisted: local clock is outside the supported range"
        );
    }
    let (blocked, reason): (i64, Option<String>) = transaction.query_row(
        "SELECT blocked, reason_code FROM secure_mesh_kt_guard WHERE singleton = 1",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    ensure!(
        blocked == 0,
        "secure mesh KT security block was previously persisted ({})",
        reason.as_deref().unwrap_or("unspecified")
    );
    let persisted: i64 = transaction.query_row(
        "SELECT max_observed_epoch_seconds FROM secure_mesh_kt_time_guard WHERE singleton = 1",
        [],
        |row| row.get(0),
    )?;
    let persisted = sql_to_u64(persisted, "time watermark")?;
    let effective = persisted.max(now_epoch_seconds);
    transaction.execute(
        "UPDATE secure_mesh_kt_time_guard SET max_observed_epoch_seconds = ?1 WHERE singleton = 1",
        params![u64_to_sql(effective)?],
    )?;
    transaction.commit()?;
    Ok(effective)
}

fn authenticated_sth_temporal_block_reason(
    sth: &SecureMeshSignedTreeHead,
    freshness_policy: KtFreshnessPolicy,
    now_epoch_seconds: u64,
) -> Option<&'static str> {
    if sth.issued_at_epoch_seconds
        > now_epoch_seconds.saturating_add(freshness_policy.max_future_skew_seconds)
    {
        return Some("authenticated_sth_from_future");
    }
    if now_epoch_seconds
        > sth
            .issued_at_epoch_seconds
            .saturating_add(freshness_policy.max_sth_age_seconds)
    {
        return Some("authenticated_sth_expired");
    }
    None
}

fn verify_authenticated_sth_freshness_or_block(
    connection: &mut Connection,
    pin: &PinnedKtLogKey,
    freshness_policy: KtFreshnessPolicy,
    sth: &SecureMeshSignedTreeHead,
    now_epoch_seconds: u64,
) -> Result<VerifiedKtFreshness> {
    sth.verify_authenticity(pin)?;
    if let Some(reason) =
        authenticated_sth_temporal_block_reason(sth, freshness_policy, now_epoch_seconds)
    {
        persist_security_block_connection(connection, reason)?;
        bail!("secure mesh KT terminal freshness block persisted: {reason}");
    }
    sth.verify_freshness(freshness_policy, now_epoch_seconds)
}

fn persist_security_block_connection(connection: &mut Connection, reason: &str) -> Result<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    persist_security_block(&transaction, reason)?;
    transaction.commit()?;
    Ok(())
}

fn u64_to_sql(value: u64) -> Result<i64> {
    i64::try_from(value).map_err(|_| anyhow!("secure mesh KT integer exceeds SQLite range"))
}

fn sql_to_u64(value: i64, label: &str) -> Result<u64> {
    u64::try_from(value).map_err(|_| anyhow!("secure mesh KT persisted {label} is invalid"))
}

fn checkpoint_from_sth(sth: &SecureMeshSignedTreeHead) -> SecureMeshKtCachedCheckpoint {
    SecureMeshKtCachedCheckpoint {
        tree_size: sth.tree_size,
        root_hash: sth.root_hash.clone(),
        map_root_hash: sth.map_root_hash.clone(),
        issued_at_epoch_seconds: sth.issued_at_epoch_seconds,
    }
}

fn fold_rfc9162_inclusion(
    mut hash: [u8; HASH_LEN],
    leaf_index: u64,
    tree_size: u64,
    path: &[[u8; HASH_LEN]],
) -> Result<[u8; HASH_LEN]> {
    ensure!(tree_size > 0, "secure mesh KT inclusion tree is empty");
    ensure!(
        leaf_index < tree_size,
        "secure mesh KT inclusion index is invalid"
    );
    let mut fn_index = leaf_index;
    let mut sn = tree_size - 1;
    for sibling in path {
        ensure!(sn > 0, "secure mesh KT inclusion proof has extra hashes");
        if fn_index & 1 == 1 || fn_index == sn {
            hash = log_node_hash(sibling, &hash);
            while fn_index & 1 == 0 && fn_index != 0 {
                fn_index >>= 1;
                sn >>= 1;
            }
        } else {
            hash = log_node_hash(&hash, sibling);
        }
        fn_index >>= 1;
        sn >>= 1;
    }
    ensure!(sn == 0, "secure mesh KT inclusion proof is truncated");
    Ok(hash)
}

fn verify_rfc9162_consistency(
    first_size: u64,
    second_size: u64,
    first_root: [u8; HASH_LEN],
    second_root: [u8; HASH_LEN],
    path: &[[u8; HASH_LEN]],
) -> Result<()> {
    ensure!(
        first_size <= second_size,
        "secure mesh KT consistency sizes are invalid"
    );
    if first_size == 0 {
        ensure!(
            path.is_empty(),
            "secure mesh KT empty-tree consistency proof must be empty"
        );
        ensure!(
            first_root == empty_log_root(),
            "secure mesh KT empty-tree root is invalid"
        );
        return Ok(());
    }
    if first_size == second_size {
        ensure!(
            path.is_empty(),
            "secure mesh KT equal-size consistency proof must be empty"
        );
        ensure!(
            first_root == second_root,
            "secure mesh KT equal-size roots differ"
        );
        return Ok(());
    }

    let mut fn_index = first_size - 1;
    let mut sn = second_size - 1;
    while fn_index & 1 == 1 {
        fn_index >>= 1;
        sn >>= 1;
    }

    let (mut first_hash, mut second_hash, remaining) = if fn_index == 0 {
        (first_root, first_root, path)
    } else {
        let seed = *path
            .first()
            .ok_or_else(|| anyhow!("secure mesh KT consistency proof is truncated"))?;
        (seed, seed, &path[1..])
    };

    for node in remaining {
        ensure!(sn > 0, "secure mesh KT consistency proof has extra hashes");
        if fn_index & 1 == 1 || fn_index == sn {
            first_hash = log_node_hash(node, &first_hash);
            second_hash = log_node_hash(node, &second_hash);
            while fn_index & 1 == 0 && fn_index != 0 {
                fn_index >>= 1;
                sn >>= 1;
            }
        } else {
            second_hash = log_node_hash(&second_hash, node);
        }
        fn_index >>= 1;
        sn >>= 1;
    }
    ensure!(sn == 0, "secure mesh KT consistency proof is truncated");
    ensure!(
        first_hash == first_root,
        "secure mesh KT consistency first root mismatch"
    );
    ensure!(
        second_hash == second_root,
        "secure mesh KT consistency second root mismatch"
    );
    Ok(())
}

pub(crate) fn kt_log_leaf_hash(bytes: &[u8]) -> [u8; HASH_LEN] {
    let mut hasher = Sha256::new();
    hasher.update([0x00]);
    hasher.update(bytes);
    hasher.finalize().into()
}

fn map_root_log_leaf_hash(map_root_hash: &str) -> Result<[u8; HASH_LEN]> {
    let mut entry = Vec::with_capacity(COMBINED_MAP_ROOT_LOG_ENTRY_DOMAIN.len() + HASH_LEN);
    entry.extend_from_slice(COMBINED_MAP_ROOT_LOG_ENTRY_DOMAIN);
    entry.extend_from_slice(&parse_hash(map_root_hash)?);
    Ok(kt_log_leaf_hash(&entry))
}

fn log_node_hash(left: &[u8; HASH_LEN], right: &[u8; HASH_LEN]) -> [u8; HASH_LEN] {
    let mut hasher = Sha256::new();
    hasher.update([0x01]);
    hasher.update(left);
    hasher.update(right);
    hasher.finalize().into()
}

fn empty_log_root() -> [u8; HASH_LEN] {
    Sha256::digest([]).into()
}

#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
fn merkle_tree_hash(leaves: &[[u8; HASH_LEN]]) -> [u8; HASH_LEN] {
    match leaves.len() {
        0 => empty_log_root(),
        1 => leaves[0],
        count => {
            let split = largest_power_of_two_less_than(count);
            log_node_hash(
                &merkle_tree_hash(&leaves[..split]),
                &merkle_tree_hash(&leaves[split..]),
            )
        }
    }
}

#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
fn largest_power_of_two_less_than(value: usize) -> usize {
    debug_assert!(value > 1);
    1usize << (usize::BITS - 1 - (value - 1).leading_zeros())
}

#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
fn rfc9162_inclusion_path(
    leaves: &[[u8; HASH_LEN]],
    leaf_index: usize,
) -> Result<Vec<[u8; HASH_LEN]>> {
    ensure!(
        leaf_index < leaves.len(),
        "secure mesh KT inclusion index is invalid"
    );
    fn recurse(leaves: &[[u8; HASH_LEN]], index: usize, out: &mut Vec<[u8; HASH_LEN]>) {
        if leaves.len() <= 1 {
            return;
        }
        let split = largest_power_of_two_less_than(leaves.len());
        if index < split {
            recurse(&leaves[..split], index, out);
            out.push(merkle_tree_hash(&leaves[split..]));
        } else {
            recurse(&leaves[split..], index - split, out);
            out.push(merkle_tree_hash(&leaves[..split]));
        }
    }
    let mut path = Vec::new();
    recurse(leaves, leaf_index, &mut path);
    ensure!(
        path.len() <= MAX_INCLUSION_PROOF_HASHES,
        "secure mesh KT inclusion path exceeds bound"
    );
    Ok(path)
}

#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
fn rfc9162_consistency_path(
    leaves: &[[u8; HASH_LEN]],
    first_size: usize,
) -> Result<Vec<[u8; HASH_LEN]>> {
    ensure!(
        first_size <= leaves.len(),
        "secure mesh KT consistency size is invalid"
    );
    if first_size == 0 || first_size == leaves.len() {
        return Ok(Vec::new());
    }
    fn subproof(
        leaves: &[[u8; HASH_LEN]],
        first_size: usize,
        complete_subtree: bool,
        out: &mut Vec<[u8; HASH_LEN]>,
    ) {
        if first_size == leaves.len() {
            if !complete_subtree {
                out.push(merkle_tree_hash(leaves));
            }
            return;
        }
        let split = largest_power_of_two_less_than(leaves.len());
        if first_size <= split {
            subproof(&leaves[..split], first_size, complete_subtree, out);
            out.push(merkle_tree_hash(&leaves[split..]));
        } else {
            subproof(&leaves[split..], first_size - split, false, out);
            out.push(merkle_tree_hash(&leaves[..split]));
        }
    }
    let mut path = Vec::new();
    subproof(leaves, first_size, true, &mut path);
    ensure!(
        path.len() <= MAX_CONSISTENCY_PROOF_HASHES,
        "secure mesh KT consistency path exceeds bound"
    );
    Ok(path)
}

fn sparse_map_key(stable_label: &str) -> [u8; HASH_LEN] {
    domain_hash(MAP_KEY_DOMAIN, stable_label.as_bytes())
}

fn sparse_map_leaf_hash(key: &[u8; HASH_LEN], entry: &SecureMeshKtMapEntry) -> [u8; HASH_LEN] {
    let mut transcript = Vec::with_capacity(HASH_LEN * 2 + 9);
    transcript.extend_from_slice(key);
    // Entry hashes are validated before production verification reaches this helper.
    transcript.extend_from_slice(&parse_hash(&entry.leaf_hash).unwrap_or([0; HASH_LEN]));
    transcript.extend_from_slice(&entry.version.to_be_bytes());
    transcript.push(u8::from(entry.revoked));
    domain_hash(MAP_LEAF_DOMAIN, &transcript)
}

fn sparse_map_node_hash(left: &[u8; HASH_LEN], right: &[u8; HASH_LEN]) -> [u8; HASH_LEN] {
    let mut transcript = Vec::with_capacity(HASH_LEN * 2);
    transcript.extend_from_slice(left);
    transcript.extend_from_slice(right);
    domain_hash(MAP_NODE_DOMAIN, &transcript)
}

fn sparse_map_default_hashes() -> Vec<[u8; HASH_LEN]> {
    let mut defaults = vec![[0u8; HASH_LEN]; SPARSE_MAP_DEPTH + 1];
    defaults[SPARSE_MAP_DEPTH] = domain_hash(MAP_EMPTY_DOMAIN, b"");
    for depth in (0..SPARSE_MAP_DEPTH).rev() {
        defaults[depth] = sparse_map_node_hash(&defaults[depth + 1], &defaults[depth + 1]);
    }
    defaults
}

fn bit_at(key: &[u8; HASH_LEN], depth: usize) -> u8 {
    (key[depth / 8] >> (7 - (depth % 8))) & 1
}

fn domain_hash(domain: &[u8], bytes: &[u8]) -> [u8; HASH_LEN] {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    hasher.update(bytes);
    hasher.finalize().into()
}

fn sth_sign_payload(sth: &SecureMeshSignedTreeHead) -> Result<Vec<u8>> {
    validate_text("log_id", &sth.log_id)?;
    validate_text("key_id", &sth.key_id)?;
    validate_hex_hash("root_hash", &sth.root_hash)?;
    validate_hex_hash("map_root_hash", &sth.map_root_hash)?;
    let mut out = Vec::new();
    out.extend_from_slice(STH_SIGN_MAGIC);
    append_len_prefixed(&mut out, sth.protocol_version.as_bytes());
    append_len_prefixed(&mut out, sth.log_id.as_bytes());
    append_len_prefixed(&mut out, sth.key_id.as_bytes());
    out.extend_from_slice(&sth.tree_size.to_be_bytes());
    out.extend_from_slice(&parse_hash(&sth.root_hash)?);
    out.extend_from_slice(&parse_hash(&sth.map_root_hash)?);
    out.extend_from_slice(&sth.issued_at_epoch_seconds.to_be_bytes());
    Ok(out)
}

fn append_len_prefixed(out: &mut Vec<u8>, value: &[u8]) {
    out.extend_from_slice(&(value.len() as u64).to_be_bytes());
    out.extend_from_slice(value);
}

fn validate_leaf_body(body: &SecureMeshTransparencyLeafBody) -> Result<()> {
    validate_hex_hash(
        "directory_scope_commitment",
        &body.directory_scope_commitment,
    )?;
    validate_text("endpoint_id", &body.endpoint_id)?;
    validate_text("endpoint_kind", &body.endpoint_kind)?;
    validate_text("identity_public_key", &body.identity_public_key)?;
    validate_text("signing_public_key", &body.signing_public_key)?;
    validate_text("fingerprint", &body.fingerprint)?;
    validate_text("directory_state", &body.directory_state)?;
    validate_text("updated_at", &body.updated_at)?;
    ensure!(
        body.rotation_epoch <= KT_JSON_SAFE_INTEGER_MAX,
        "secure mesh transparency rotation epoch exceeds the cross-language safe range"
    );
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
        value.len() == HASH_LEN * 2 && value.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "secure mesh transparency {label} is not a sha256 hex digest"
    );
    Ok(())
}

fn parse_hash_path(values: &[String], max: usize) -> Result<Vec<[u8; HASH_LEN]>> {
    ensure!(
        values.len() <= max,
        "secure mesh KT proof exceeds its hash bound"
    );
    values.iter().map(|value| parse_hash(value)).collect()
}

fn parse_hash(value: &str) -> Result<[u8; HASH_LEN]> {
    validate_hex_hash("hash", value)?;
    let mut out = [0u8; HASH_LEN];
    for (index, chunk) in value.as_bytes().chunks(2).enumerate() {
        let text =
            std::str::from_utf8(chunk).map_err(|_| anyhow!("secure mesh KT hash is not utf8"))?;
        out[index] =
            u8::from_str_radix(text, 16).map_err(|_| anyhow!("secure mesh KT hash is not hex"))?;
    }
    Ok(out)
}

fn parse_signature(value: &str) -> Result<Signature> {
    ensure!(
        value.len() == 128 && value.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "secure mesh KT signature is not a 64-byte hex value"
    );
    let mut bytes = [0u8; 64];
    for (index, chunk) in value.as_bytes().chunks(2).enumerate() {
        let text = std::str::from_utf8(chunk)
            .map_err(|_| anyhow!("secure mesh KT signature is not utf8"))?;
        bytes[index] = u8::from_str_radix(text, 16)
            .map_err(|_| anyhow!("secure mesh KT signature is not hex"))?;
    }
    Ok(Signature::from_bytes(&bytes))
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
                out.push_str(&serde_json::to_string(key)?);
                out.push(':');
                out.push_str(&canonical_json(&map[*key])?);
            }
            out.push('}');
            Ok(out)
        }
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn sth_to_json(sth: &SecureMeshSignedTreeHead) -> Value {
    serde_json::json!({
        "protocolVersion": sth.protocol_version,
        "logId": sth.log_id,
        "keyId": sth.key_id,
        "treeSize": sth.tree_size,
        "rootHash": sth.root_hash,
        "mapRootHash": sth.map_root_hash,
        "issuedAtEpochSeconds": sth.issued_at_epoch_seconds,
        "signature": sth.signature,
    })
}

fn consistency_to_json(proof: &SecureMeshKtConsistencyProof) -> Value {
    serde_json::json!({
        "firstTreeSize": proof.first_tree_size,
        "secondTreeSize": proof.second_tree_size,
        "firstRootHash": proof.first_root_hash,
        "path": proof.path,
        "secondSignedTreeHead": sth_to_json(&proof.second_signed_tree_head),
    })
}

fn required_json_text(value: &Value, field: &str) -> Result<String> {
    let text = value
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure mesh KT JSON field is required: {field}"))?;
    validate_text(field, text)?;
    Ok(text.to_string())
}

fn required_json_u64(value: &Value, field: &str) -> Result<u64> {
    let parsed = value
        .get(field)
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("secure mesh KT JSON integer is required: {field}"))?;
    ensure!(
        parsed <= KT_JSON_SAFE_INTEGER_MAX,
        "secure mesh KT JSON integer exceeds the cross-language safe range: {field}"
    );
    Ok(parsed)
}

fn parse_sth_json(value: &Value) -> Result<SecureMeshSignedTreeHead> {
    Ok(SecureMeshSignedTreeHead {
        protocol_version: required_json_text(value, "protocolVersion")?,
        log_id: required_json_text(value, "logId")?,
        key_id: required_json_text(value, "keyId")?,
        tree_size: required_json_u64(value, "treeSize")?,
        root_hash: required_json_text(value, "rootHash")?,
        map_root_hash: required_json_text(value, "mapRootHash")?,
        issued_at_epoch_seconds: required_json_u64(value, "issuedAtEpochSeconds")?,
        signature: required_json_text(value, "signature")?,
    })
}

fn parse_consistency_json(value: &Value) -> Result<SecureMeshKtConsistencyProof> {
    let path = value
        .get("path")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("secure mesh KT consistency path is required"))?;
    ensure!(
        path.len() <= MAX_CONSISTENCY_PROOF_HASHES,
        "secure mesh KT consistency path is too large"
    );
    let path = path
        .iter()
        .map(|item| {
            item.as_str()
                .map(str::to_string)
                .ok_or_else(|| anyhow!("secure mesh KT consistency path hash is invalid"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(SecureMeshKtConsistencyProof {
        first_tree_size: required_json_u64(value, "firstTreeSize")?,
        second_tree_size: required_json_u64(value, "secondTreeSize")?,
        first_root_hash: required_json_text(value, "firstRootHash")?,
        path,
        second_signed_tree_head: parse_sth_json(
            value
                .get("secondSignedTreeHead")
                .ok_or_else(|| anyhow!("secure mesh KT consistency STH is required"))?,
        )?,
    })
}

/// Separately operated test/acceptance authority. This type and its private key are absent from
/// ordinary builds and rejected in release profiles, while production code receives only
/// `PinnedKtLogKey` plus untrusted proof objects.
#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
pub struct SecureMeshKtLog {
    log_signing_key: ed25519_dalek::SigningKey,
    log_id: String,
    key_id: String,
    leaves: Vec<[u8; HASH_LEN]>,
    latest: std::collections::BTreeMap<String, SecureMeshKtMapEntry>,
}

#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
impl SecureMeshKtLog {
    pub fn new(log_signing_key: ed25519_dalek::SigningKey) -> Self {
        Self::with_identity(log_signing_key, "test-log", "test-key")
    }

    pub fn with_identity(
        log_signing_key: ed25519_dalek::SigningKey,
        log_id: impl Into<String>,
        key_id: impl Into<String>,
    ) -> Self {
        Self {
            log_signing_key,
            log_id: log_id.into(),
            key_id: key_id.into(),
            leaves: Vec::new(),
            latest: std::collections::BTreeMap::new(),
        }
    }

    pub fn pin(&self) -> PinnedKtLogKey {
        PinnedKtLogKey::from_acceptance_mock_ed25519_bytes(
            self.log_id.clone(),
            self.key_id.clone(),
            *self.log_signing_key.verifying_key().as_bytes(),
        )
        .expect("test KT pin")
    }

    pub fn log_verifying_key(&self) -> VerifyingKey {
        self.log_signing_key.verifying_key()
    }

    pub fn tree_size(&self) -> u64 {
        self.leaves.len() as u64
    }

    pub fn append_leaf(&mut self, body: &SecureMeshTransparencyLeafBody) -> Result<u64> {
        self.append_hashed_directory_leaf(
            &body.directory_key(),
            body.rotation_epoch,
            body.is_revoked(),
            body.leaf_hash()?,
        )
    }

    pub fn append_hashed_directory_leaf(
        &mut self,
        stable_label: &str,
        version: u64,
        revoked: bool,
        leaf_hash: [u8; HASH_LEN],
    ) -> Result<u64> {
        ensure!(
            self.leaves.len() < MAX_TRANSPARENCY_LEAVES,
            "secure mesh KT test log has too many leaves"
        );
        validate_hex_hash("stable_label", stable_label)?;
        if let Some(previous) = self.latest.get(stable_label) {
            ensure!(
                version > previous.version,
                "secure mesh KT directory version must increase"
            );
            ensure!(
                !(previous.revoked && !revoked),
                "secure mesh KT test authority refuses revoked resurrection"
            );
        }
        self.latest.insert(
            stable_label.to_string(),
            SecureMeshKtMapEntry {
                leaf_hash: hex_encode(&leaf_hash),
                version,
                revoked,
            },
        );
        let leaf_index = self.leaves.len() as u64;
        self.leaves
            .push(map_root_log_leaf_hash(&hex_encode(&self.map_root_hash()))?);
        Ok(leaf_index)
    }

    pub fn force_append_hashed_directory_leaf_for_adversarial_test(
        &mut self,
        stable_label: &str,
        version: u64,
        revoked: bool,
        leaf_hash: [u8; HASH_LEN],
    ) -> Result<u64> {
        ensure!(
            self.leaves.len() < MAX_TRANSPARENCY_LEAVES,
            "secure mesh KT test log has too many leaves"
        );
        validate_hex_hash("stable_label", stable_label)?;
        self.latest.insert(
            stable_label.to_string(),
            SecureMeshKtMapEntry {
                leaf_hash: hex_encode(&leaf_hash),
                version,
                revoked,
            },
        );
        let leaf_index = self.leaves.len() as u64;
        self.leaves
            .push(map_root_log_leaf_hash(&hex_encode(&self.map_root_hash()))?);
        Ok(leaf_index)
    }

    pub fn force_remove_map_label_for_adversarial_test(
        &mut self,
        stable_label: &str,
    ) -> Result<u64> {
        self.latest.remove(stable_label);
        let leaf_index = self.leaves.len() as u64;
        self.leaves
            .push(map_root_log_leaf_hash(&hex_encode(&self.map_root_hash()))?);
        Ok(leaf_index)
    }

    pub fn append_empty_map_checkpoint_for_test(&mut self) -> Result<u64> {
        ensure!(
            self.latest.is_empty(),
            "secure mesh KT test map is not empty"
        );
        let leaf_index = self.leaves.len() as u64;
        self.leaves
            .push(map_root_log_leaf_hash(&hex_encode(&self.map_root_hash()))?);
        Ok(leaf_index)
    }

    pub fn append_current_map_checkpoint_for_test(&mut self) -> Result<u64> {
        ensure!(
            self.leaves.len() < MAX_TRANSPARENCY_LEAVES,
            "secure mesh KT test log has too many leaves"
        );
        let leaf_index = self.leaves.len() as u64;
        self.leaves
            .push(map_root_log_leaf_hash(&hex_encode(&self.map_root_hash()))?);
        Ok(leaf_index)
    }

    pub fn mark_revoked_placeholder(
        &mut self,
        body: &SecureMeshTransparencyLeafBody,
    ) -> Result<(u64, SecureMeshTransparencyLeafBody)> {
        let mut revoked = body.clone();
        revoked.rotation_epoch = body.rotation_epoch.saturating_add(1);
        revoked.directory_state = "revoked".to_string();
        let index = self.append_leaf(&revoked)?;
        Ok((index, revoked))
    }

    pub fn root_hash(&self) -> [u8; HASH_LEN] {
        merkle_tree_hash(&self.leaves)
    }

    pub fn map_root_hash(&self) -> [u8; HASH_LEN] {
        self.sparse_levels()[0]
            .get(&[0u8; HASH_LEN])
            .copied()
            .unwrap_or_else(|| sparse_map_default_hashes()[0])
    }

    pub fn sign_tree_head(&self, issued_at_epoch_seconds: u64) -> Result<SecureMeshSignedTreeHead> {
        use ed25519_dalek::Signer;

        let mut sth = SecureMeshSignedTreeHead {
            protocol_version: SECURE_MESH_KT_PROTOCOL_VERSION.to_string(),
            log_id: self.log_id.clone(),
            key_id: self.key_id.clone(),
            tree_size: self.tree_size(),
            root_hash: hex_encode(&self.root_hash()),
            map_root_hash: hex_encode(&self.map_root_hash()),
            issued_at_epoch_seconds,
            signature: String::new(),
        };
        sth.signature = hex_encode(
            &self
                .log_signing_key
                .sign(&sth_sign_payload(&sth)?)
                .to_bytes(),
        );
        Ok(sth)
    }

    pub fn inclusion_proof(&self, leaf_index: u64) -> Result<SecureMeshKtInclusionProof> {
        self.inclusion_proof_at(leaf_index, 0)
    }

    pub fn inclusion_proof_at(
        &self,
        leaf_index: u64,
        issued_at_epoch_seconds: u64,
    ) -> Result<SecureMeshKtInclusionProof> {
        let index = usize::try_from(leaf_index)
            .map_err(|_| anyhow!("secure mesh KT test leaf index is invalid"))?;
        ensure!(
            index < self.leaves.len(),
            "secure mesh KT leaf index is out of range"
        );
        Ok(SecureMeshKtInclusionProof {
            leaf_index,
            tree_size: self.tree_size(),
            leaf_hash: hex_encode(&self.leaves[index]),
            siblings: rfc9162_inclusion_path(&self.leaves, index)?
                .iter()
                .map(|hash| hex_encode(hash))
                .collect(),
            signed_tree_head: self.sign_tree_head(issued_at_epoch_seconds)?,
        })
    }

    pub fn consistency_proof(&self, first_tree_size: u64) -> Result<SecureMeshKtConsistencyProof> {
        self.consistency_proof_at(first_tree_size, 0)
    }

    pub fn consistency_proof_at(
        &self,
        first_tree_size: u64,
        issued_at_epoch_seconds: u64,
    ) -> Result<SecureMeshKtConsistencyProof> {
        let first = usize::try_from(first_tree_size)
            .map_err(|_| anyhow!("secure mesh KT consistency size is invalid"))?;
        ensure!(
            first <= self.leaves.len(),
            "secure mesh KT consistency size is invalid"
        );
        Ok(SecureMeshKtConsistencyProof {
            first_tree_size,
            second_tree_size: self.tree_size(),
            first_root_hash: hex_encode(&merkle_tree_hash(&self.leaves[..first])),
            path: rfc9162_consistency_path(&self.leaves, first)?
                .iter()
                .map(|hash| hex_encode(hash))
                .collect(),
            second_signed_tree_head: self.sign_tree_head(issued_at_epoch_seconds)?,
        })
    }

    pub fn map_proof_at(
        &self,
        stable_label: &str,
        issued_at_epoch_seconds: u64,
    ) -> Result<SecureMeshKtMapProof> {
        validate_hex_hash("stable_label", stable_label)?;
        let key = sparse_map_key(stable_label);
        let levels = self.sparse_levels();
        let defaults = sparse_map_default_hashes();
        let mut siblings = Vec::with_capacity(SPARSE_MAP_DEPTH);
        for depth in (0..SPARSE_MAP_DEPTH).rev() {
            let mut sibling_prefix = normalized_prefix(&key, depth + 1);
            flip_bit(&mut sibling_prefix, depth);
            siblings.push(hex_encode(
                levels[depth + 1]
                    .get(&sibling_prefix)
                    .unwrap_or(&defaults[depth + 1]),
            ));
        }
        Ok(SecureMeshKtMapProof {
            stable_label: stable_label.to_string(),
            entry: self.latest.get(stable_label).cloned(),
            siblings,
            signed_tree_head: self.sign_tree_head(issued_at_epoch_seconds)?,
        })
    }

    pub fn non_inclusion_proof(&self, stable_label: &str) -> Result<SecureMeshKtNonInclusionProof> {
        let proof = self.map_proof_at(stable_label, 0)?;
        ensure!(
            proof.entry.is_none(),
            "secure mesh KT directory label is present"
        );
        Ok(proof)
    }

    fn sparse_levels(&self) -> Vec<std::collections::BTreeMap<[u8; HASH_LEN], [u8; HASH_LEN]>> {
        let defaults = sparse_map_default_hashes();
        let mut levels = (0..=SPARSE_MAP_DEPTH)
            .map(|_| std::collections::BTreeMap::new())
            .collect::<Vec<_>>();
        for (stable_label, entry) in &self.latest {
            let key = sparse_map_key(stable_label);
            levels[SPARSE_MAP_DEPTH].insert(key, sparse_map_leaf_hash(&key, entry));
        }
        for depth in (0..SPARSE_MAP_DEPTH).rev() {
            let mut parents = std::collections::BTreeMap::<
                [u8; HASH_LEN],
                (Option<[u8; HASH_LEN]>, Option<[u8; HASH_LEN]>),
            >::new();
            for (child_prefix, child_hash) in &levels[depth + 1] {
                let parent_prefix = normalized_prefix(child_prefix, depth);
                let children = parents.entry(parent_prefix).or_default();
                if bit_at(child_prefix, depth) == 0 {
                    children.0 = Some(*child_hash);
                } else {
                    children.1 = Some(*child_hash);
                }
            }
            for (parent_prefix, (left, right)) in parents {
                let hash = sparse_map_node_hash(
                    &left.unwrap_or(defaults[depth + 1]),
                    &right.unwrap_or(defaults[depth + 1]),
                );
                if hash != defaults[depth] {
                    levels[depth].insert(parent_prefix, hash);
                }
            }
        }
        levels
    }
}

#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
fn normalized_prefix(key: &[u8; HASH_LEN], depth: usize) -> [u8; HASH_LEN] {
    let mut out = *key;
    if depth >= SPARSE_MAP_DEPTH {
        return out;
    }
    let full_bytes = depth / 8;
    let remaining_bits = depth % 8;
    if remaining_bits == 0 {
        out[full_bytes..].fill(0);
    } else {
        out[full_bytes] &= 0xff << (8 - remaining_bits);
        out[full_bytes + 1..].fill(0);
    }
    out
}

#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
fn flip_bit(key: &mut [u8; HASH_LEN], depth: usize) {
    key[depth / 8] ^= 1 << (7 - (depth % 8));
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;

    #[test]
    fn pinned_sth_rejects_wrong_key_stale_and_future_views() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let body = leaf("device-a", 1, "active");
        let index = log.append_leaf(&body).unwrap();
        let proof = log.inclusion_proof_at(index, 100).unwrap();
        let policy = KtFreshnessPolicy::strict(10, 2).unwrap();
        verify_kt_inclusion(&proof, &log.pin(), policy, 105).unwrap();

        let wrong_log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        assert!(verify_kt_inclusion(&proof, &wrong_log.pin(), policy, 105).is_err());
        assert!(
            verify_kt_inclusion(&proof, &log.pin(), policy, 111)
                .unwrap_err()
                .to_string()
                .contains("stale")
        );

        let future = log.inclusion_proof_at(index, 110).unwrap();
        assert!(
            verify_kt_inclusion(&future, &log.pin(), policy, 100)
                .unwrap_err()
                .to_string()
                .contains("future")
        );
    }

    #[test]
    fn freshness_policy_can_only_tighten_protocol_hard_limits() {
        assert!(KtFreshnessPolicy::strict(0, 0).is_err());
        assert!(KtFreshnessPolicy::strict(KT_PROTOCOL_MAX_STH_AGE_SECONDS + 1, 0).is_err());
        assert!(KtFreshnessPolicy::strict(60, KT_PROTOCOL_MAX_FUTURE_SKEW_SECONDS + 1).is_err());
        assert!(KtFreshnessPolicy::strict(u64::MAX, u64::MAX).is_err());
        KtFreshnessPolicy::strict(
            KT_PROTOCOL_MAX_STH_AGE_SECONDS,
            KT_PROTOCOL_MAX_FUTURE_SKEW_SECONDS,
        )
        .unwrap();
    }

    #[test]
    fn cross_language_integer_contract_rejects_values_above_json_safe_range() {
        let log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let mut sth = log.sign_tree_head(100).unwrap();
        sth.tree_size = KT_JSON_SAFE_INTEGER_MAX + 1;
        let error = sth
            .verify(&log.pin(), KtFreshnessPolicy::strict(60, 2).unwrap(), 100)
            .unwrap_err();
        assert!(error.to_string().contains("cross-language safe range"));
    }

    #[test]
    fn rfc9162_inclusion_and_consistency_paths_are_logarithmic_and_exact() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        for index in 0..31 {
            log.append_leaf(&leaf(&format!("device-{index}"), 1, "active"))
                .unwrap();
        }
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(60, 2).unwrap();
        for index in 0..31 {
            let proof = log.inclusion_proof_at(index, 100).unwrap();
            assert!(proof.siblings.len() <= 5);
            verify_kt_inclusion(&proof, &pin, policy, 100).unwrap();
        }

        for first_size in [1u64, 2, 3, 7, 8, 15, 16, 30] {
            let proof = log.consistency_proof_at(first_size, 100).unwrap();
            assert!(proof.path.len() <= 6);
            let cached = SecureMeshKtCachedCheckpoint {
                tree_size: first_size,
                root_hash: proof.first_root_hash.clone(),
                map_root_hash: hex_encode(&[0u8; 32]),
                issued_at_epoch_seconds: 99,
            };
            verify_kt_consistency(&proof, &pin, policy, 100, &cached).unwrap();
        }
    }

    #[test]
    fn sparse_map_authenticates_inclusion_absence_and_rejects_label_substitution() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let body = leaf("device-a", 3, "active");
        log.append_leaf(&body).unwrap();
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(60, 2).unwrap();
        let present = log.map_proof_at(&body.directory_key(), 100).unwrap();
        verify_kt_map_inclusion(
            &present,
            &body.directory_key(),
            &body.leaf_hash_hex().unwrap(),
            3,
            false,
            &pin,
            policy,
            100,
        )
        .unwrap();

        let mut other_workspace = body.clone();
        other_workspace.directory_scope_commitment =
            directory_scope_commitment("tenant-a", "account-a", "workspace-b");
        assert_ne!(body.directory_key(), other_workspace.directory_key());
        let workspace_absence = log
            .map_proof_at(&other_workspace.directory_key(), 100)
            .unwrap();
        verify_kt_non_inclusion(
            &workspace_absence,
            &other_workspace.directory_key(),
            &pin,
            policy,
            100,
        )
        .unwrap();

        let scope = directory_scope_commitment("tenant-a", "account-a", "workspace-a");
        let missing = stable_directory_label(&scope, "missing");
        let absence = log.map_proof_at(&missing, 100).unwrap();
        assert!(absence.entry.is_none());
        verify_kt_non_inclusion(&absence, &missing, &pin, policy, 100).unwrap();

        let substituted = stable_directory_label(&scope, "other-missing");
        let mut forged = absence.clone();
        forged.stable_label = substituted.clone();
        let error = verify_kt_non_inclusion(&forged, &missing, &pin, policy, 100).unwrap_err();
        assert!(error.to_string().contains("label substitution"));
    }

    #[test]
    fn directory_leaf_serialization_exposes_only_an_opaque_scope_commitment() {
        let body = leaf("device-a", 1, "active");
        let serialized = serde_json::to_string(&body).unwrap();

        assert!(serialized.contains("directoryScopeCommitment"));
        for forbidden in [
            "tenantId",
            "accountId",
            "workspaceId",
            "tenant-a",
            "account-a",
            "workspace-a",
        ] {
            assert!(!serialized.contains(forbidden));
        }
    }

    #[test]
    fn sqlite_checkpoint_requires_consistency_and_persists_rollback_across_restart() {
        let path = state_path("rollback");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        log.append_leaf(&leaf("device-a", 1, "active")).unwrap();
        let first_sth = log.sign_tree_head(100).unwrap();
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(120, 2).unwrap();
        {
            let mut state = SecureMeshKtClientState::open(&path, pin.clone(), policy).unwrap();
            state.observe_tree_head(&first_sth, None, 100).unwrap();
            log.append_leaf(&leaf("device-b", 1, "active")).unwrap();
            let second_sth = log.sign_tree_head(101).unwrap();
            let missing = state.observe_tree_head(&second_sth, None, 101).unwrap_err();
            assert!(
                missing
                    .to_string()
                    .contains("consistency proof is required")
            );
            assert_eq!(state.checkpoint_count().unwrap(), 1);
            let consistency = log.consistency_proof_at(1, 101).unwrap();
            state
                .observe_tree_head(&second_sth, Some(&consistency), 101)
                .unwrap();
        }
        {
            let mut restored = SecureMeshKtClientState::open(&path, pin.clone(), policy).unwrap();
            let rollback = restored
                .observe_tree_head(&first_sth, None, 102)
                .unwrap_err();
            assert!(rollback.to_string().contains("tree rollback"));
        }
        let restored = SecureMeshKtClientState::open(&path, pin, policy).unwrap();
        assert!(restored.equivocation_detected().unwrap());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn durable_time_watermark_prevents_clock_rollback_and_expiry_revival() {
        let path = state_path("durable-time-watermark");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        log.append_leaf(&leaf("device-time", 1, "active")).unwrap();
        let sth = log.sign_tree_head(100).unwrap();
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(60, 2).unwrap();
        let mut state = SecureMeshKtClientState::open(&path, pin.clone(), policy).unwrap();
        state.observe_tree_head(&sth, None, 150).unwrap();
        state.observe_tree_head(&sth, None, 90).unwrap();
        let watermark: i64 = state
            .connection
            .query_row(
                "SELECT max_observed_epoch_seconds FROM secure_mesh_kt_time_guard WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(watermark, 150);

        let expired = state.observe_tree_head(&sth, None, 161).unwrap_err();
        assert!(expired.to_string().contains("authenticated_sth_expired"));
        drop(state);

        let mut rolled_back = SecureMeshKtClientState::open(&path, pin, policy).unwrap();
        let blocked = rolled_back.observe_tree_head(&sth, None, 100).unwrap_err();
        assert!(blocked.to_string().contains("previously persisted"));
        assert!(rolled_back.equivocation_detected().unwrap());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn unauthenticated_temporal_input_cannot_persist_security_block() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        log.append_leaf(&leaf("device-invalid-time", 1, "active"))
            .unwrap();
        let mut forged = log.sign_tree_head(100).unwrap();
        forged.signature = "00".repeat(64);
        let mut state = SecureMeshKtClientState::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();

        let error = state
            .observe_tree_head(&forged, None, 10_000)
            .unwrap_err()
            .to_string();
        assert!(error.contains("signature is invalid"));
        assert!(!state.equivocation_detected().unwrap());
    }

    #[test]
    fn schema_v4_migrates_forward_with_a_durable_time_guard() {
        let path = state_path("schema-v4-time-guard-migration");
        let log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(60, 2).unwrap();
        drop(SecureMeshKtClientState::open(&path, pin.clone(), policy).unwrap());
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch("DROP TABLE secure_mesh_kt_time_guard; PRAGMA user_version = 4;")
            .unwrap();
        drop(connection);

        let migrated = SecureMeshKtClientState::open(&path, pin, policy).unwrap();
        let schema_version: i64 = migrated
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        let watermark: i64 = migrated
            .connection
            .query_row(
                "SELECT max_observed_epoch_seconds FROM secure_mesh_kt_time_guard WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(schema_version, KT_SCHEMA_VERSION);
        assert_eq!(watermark, 0);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn schema_v6_migrates_gossip_observations_to_full_signed_head_binding() {
        let path = state_path("schema-v6-gossip-binding-migration");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                r#"
                CREATE TABLE secure_mesh_kt_gossip_observations (
                    log_id TEXT NOT NULL,
                    tree_size INTEGER NOT NULL CHECK (tree_size >= 0),
                    root_hash TEXT NOT NULL,
                    map_root_hash TEXT NOT NULL,
                    issued_at_epoch_seconds INTEGER NOT NULL CHECK (issued_at_epoch_seconds >= 0),
                    observed_at_epoch_seconds INTEGER NOT NULL CHECK (observed_at_epoch_seconds >= 0),
                    PRIMARY KEY (log_id, tree_size, root_hash, map_root_hash)
                );
                INSERT INTO secure_mesh_kt_gossip_observations VALUES(
                    'migration-log', 1, 'root', 'map-root', 100, 101
                );
                PRAGMA user_version = 6;
                "#,
            )
            .unwrap();
        drop(connection);

        let log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let state = SecureMeshKtClientState::open(
            &path,
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();
        let schema_version: i64 = state
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        let issued_at_primary_key_position: i64 = state
            .connection
            .query_row(
                "SELECT pk FROM pragma_table_info('secure_mesh_kt_gossip_observations') WHERE name = 'issued_at_epoch_seconds'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let preserved_rows: i64 = state
            .connection
            .query_row(
                "SELECT COUNT(*) FROM secure_mesh_kt_gossip_observations WHERE log_id = 'migration-log'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(schema_version, KT_SCHEMA_VERSION);
        assert_eq!(issued_at_primary_key_position, 5);
        assert_eq!(preserved_rows, 1);
        state
            .connection
            .execute(
                "INSERT INTO secure_mesh_kt_gossip_observations VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                params!["migration-log", 1, "root", "map-root", 102, 103],
            )
            .unwrap();
        let distinct_signed_heads: i64 = state
            .connection
            .query_row(
                "SELECT COUNT(*) FROM secure_mesh_kt_gossip_observations WHERE log_id = 'migration-log'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(distinct_signed_heads, 2);
        drop(state);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn directory_label_and_authorization_quotas_are_bounded_with_stale_reclamation() {
        let log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(60, 2).unwrap();
        let mut state = SecureMeshKtClientState::open_in_memory(pin.clone(), policy).unwrap();
        let transaction = state
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .unwrap();
        transaction
            .execute(
                "WITH digits(value) AS (
                    VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)
                 ), counter(value) AS (
                    SELECT ones.value + 10 * tens.value + 100 * hundreds.value + 1000 * thousands.value
                    FROM digits AS ones, digits AS tens, digits AS hundreds, digits AS thousands
                 )
                 INSERT INTO secure_mesh_kt_directory_latest(
                    log_id, stable_label, version, leaf_hash, revoked,
                    identity_fingerprint, identity_rotation_epoch, identity_key_digest,
                    pairwise_prekey_version, signed_prekey_digest, one_time_prekey_digest,
                    mls_key_package_version, mls_key_package_digest, tree_size
                 )
                 SELECT ?1, printf('%064x', value), 1, printf('%064x', value), 0,
                    'fingerprint', 1, printf('%064x', value), 1,
                    printf('%064x', value), printf('%064x', value), 1,
                    printf('%064x', value), 1
                 FROM counter WHERE value < ?2",
                params![pin.log_id(), u64_to_sql(MAX_PERSISTED_DIRECTORY_LABELS).unwrap()],
            )
            .unwrap();
        let label_error = enforce_directory_label_quota(&transaction, &pin, &"f".repeat(64))
            .unwrap_err()
            .to_string();
        assert!(label_error.contains("label quota"));
        enforce_directory_label_quota(&transaction, &pin, &format!("{:064x}", 1)).unwrap();

        transaction
            .execute(
                "WITH digits(value) AS (
                    VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)
                 ), counter(value) AS (
                    SELECT ones.value + 10 * tens.value + 100 * hundreds.value + 1000 * thousands.value
                    FROM digits AS ones, digits AS tens, digits AS hundreds, digits AS thousands
                 )
                 INSERT INTO secure_mesh_kt_directory_authorizations(
                    log_id, stable_label, purpose, directory_version, leaf_hash, revoked,
                    tree_size, root_hash, map_root_hash, issued_at_epoch_seconds,
                    observed_at_epoch_seconds, inclusion_json, map_proof_json
                 )
                 SELECT ?1, printf('%064x', value), 'purpose-' || value, 1,
                    printf('%064x', value), 0, 1, printf('%064x', value),
                    printf('%064x', value), 1, 1, '{}', '{}'
                 FROM counter WHERE value < ?2",
                params![
                    pin.log_id(),
                    u64_to_sql(MAX_PERSISTED_DIRECTORY_AUTHORIZATIONS).unwrap()
                ],
            )
            .unwrap();
        let authorization_error = enforce_directory_authorization_quota(
            &transaction,
            &pin,
            &"e".repeat(64),
            "new-purpose",
        )
        .unwrap_err()
        .to_string();
        assert!(authorization_error.contains("authorization quota"));
        reclaim_stale_directory_authorizations(&transaction, &pin, 2).unwrap();
        enforce_directory_authorization_quota(&transaction, &pin, &"e".repeat(64), "new-purpose")
            .unwrap();
        let remaining: i64 = transaction
            .query_row(
                "SELECT COUNT(*) FROM secure_mesh_kt_directory_authorizations WHERE log_id = ?1",
                params![pin.log_id()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(remaining, 0);
        transaction.commit().unwrap();
    }

    #[test]
    fn gossip_same_size_split_view_is_persisted_and_round_trips_without_leaf_lists() {
        let path = state_path("gossip-split");
        let shared = SigningKey::generate(&mut OsRng);
        let bytes = shared.to_bytes();
        let mut first = SecureMeshKtLog::with_identity(
            SigningKey::from_bytes(&bytes),
            "gossip-log",
            "gossip-key",
        );
        let mut split = SecureMeshKtLog::with_identity(
            SigningKey::from_bytes(&bytes),
            "gossip-log",
            "gossip-key",
        );
        first.append_leaf(&leaf("device-a", 1, "active")).unwrap();
        split.append_leaf(&leaf("device-b", 1, "active")).unwrap();
        let pin = first.pin();
        let policy = KtFreshnessPolicy::strict(60, 2).unwrap();
        let first_gossip =
            SecureMeshKtGossipPayload::from_sth(first.sign_tree_head(100).unwrap(), None);
        let encoded = first_gossip.to_json_bytes().unwrap();
        assert!(!String::from_utf8_lossy(&encoded).contains("leafHashes"));
        let decoded = SecureMeshKtGossipPayload::from_json_bytes(&encoded).unwrap();

        let mut state = SecureMeshKtClientState::open(&path, pin.clone(), policy).unwrap();
        state.observe_peer_gossip_sth(&decoded, 100).unwrap();
        let split_gossip =
            SecureMeshKtGossipPayload::from_sth(split.sign_tree_head(100).unwrap(), None);
        let error = state
            .observe_peer_gossip_sth(&split_gossip, 100)
            .unwrap_err();
        assert!(error.to_string().contains("same-size split view"));
        drop(state);
        let restored = SecureMeshKtClientState::open(&path, pin, policy).unwrap();
        assert!(restored.equivocation_detected().unwrap());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn gossip_observations_bind_distinct_issue_times_for_the_same_tree_view() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        log.append_leaf(&leaf("device-a", 1, "active")).unwrap();
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(60, 2).unwrap();
        let first_sth = log.sign_tree_head(100).unwrap();
        let second_sth = log.sign_tree_head(101).unwrap();
        let first_gossip = SecureMeshKtGossipPayload::from_sth(first_sth.clone(), None);
        let second_gossip = SecureMeshKtGossipPayload::from_sth(second_sth.clone(), None);
        let mut state = SecureMeshKtClientState::open_in_memory(pin.clone(), policy).unwrap();

        state.observe_peer_gossip_sth(&first_gossip, 100).unwrap();
        state.observe_peer_gossip_sth(&second_gossip, 101).unwrap();

        let observation_count: i64 = state
            .connection
            .query_row(
                "SELECT COUNT(*) FROM secure_mesh_kt_gossip_observations WHERE log_id = ?1",
                params![pin.log_id()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(observation_count, 2);
        let transaction = state
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .unwrap();
        require_fresh_gossip_observation_transaction(&transaction, &pin, &first_sth, policy, 101)
            .unwrap();
        require_fresh_gossip_observation_transaction(&transaction, &pin, &second_sth, policy, 101)
            .unwrap();
        transaction.commit().unwrap();
    }

    #[test]
    fn legacy_unversioned_state_fails_closed_instead_of_losing_rollback_history() {
        let path = state_path("legacy-schema");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE secure_mesh_kt_checkpoints(log_id TEXT, tree_size INTEGER);",
            )
            .unwrap();
        drop(connection);
        let log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let error = SecureMeshKtClientState::open(
            &path,
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .err()
        .expect("legacy KT schema must fail closed");
        assert!(error.to_string().contains("explicit security reset"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn checkpoint_retention_is_bounded_without_weakening_latest_rollback_guard() {
        let path = state_path("bounded-checkpoints");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        log.append_leaf(&leaf("device-0", 1, "active")).unwrap();
        let first_sth = log.sign_tree_head(100).unwrap();
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(600, 2).unwrap();
        let mut state = SecureMeshKtClientState::open(&path, pin.clone(), policy).unwrap();
        state.observe_tree_head(&first_sth, None, 100).unwrap();
        for index in 1..80u64 {
            let previous_size = log.tree_size();
            log.append_leaf(&leaf(&format!("device-{index}"), 1, "active"))
                .unwrap();
            let issued_at = 100 + index;
            let sth = log.sign_tree_head(issued_at).unwrap();
            let consistency = log.consistency_proof_at(previous_size, issued_at).unwrap();
            state
                .observe_tree_head(&sth, Some(&consistency), issued_at)
                .unwrap();
        }
        assert_eq!(state.checkpoint_count().unwrap(), MAX_PERSISTED_CHECKPOINTS);
        let rollback = state.observe_tree_head(&first_sth, None, 200).unwrap_err();
        assert!(rollback.to_string().contains("tree rollback"));
        drop(state);
        let restored = SecureMeshKtClientState::open(&path, pin, policy).unwrap();
        assert!(restored.equivocation_detected().unwrap());
        let _ = std::fs::remove_file(path);
    }

    fn leaf(
        endpoint_id: &str,
        rotation_epoch: u64,
        directory_state: &str,
    ) -> SecureMeshTransparencyLeafBody {
        SecureMeshTransparencyLeafBody {
            directory_scope_commitment: directory_scope_commitment(
                "tenant-a",
                "account-a",
                "workspace-a",
            ),
            endpoint_id: endpoint_id.to_string(),
            endpoint_kind: "test".to_string(),
            identity_public_key: format!("{endpoint_id}-identity"),
            signing_public_key: format!("{endpoint_id}-signing"),
            fingerprint: format!("{endpoint_id}-fingerprint"),
            rotation_epoch,
            directory_state: directory_state.to_string(),
            updated_at: "2026-07-12T00:00:00Z".to_string(),
        }
    }

    fn state_path(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "lico-kt-{label}-{}-{}.sqlite3",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }
}
