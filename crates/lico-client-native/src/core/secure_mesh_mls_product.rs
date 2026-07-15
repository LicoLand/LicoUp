use anyhow::{Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::SigningKey;
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::types::SignatureScheme;
use rusqlite::OptionalExtension;
use rusqlite::{Connection, Transaction, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use time::OffsetDateTime;

use crate::core::secure_mesh::SECURE_MESH_PROTOCOL_BUILD_REVISION;
use crate::core::secure_mesh_capability::{
    CapabilityEvaluation, CapabilityScope, SecurityCapability, capability_catalog,
};
use crate::core::secure_mesh_capability_proof::{
    CAPABILITY_PROOF_MAX_CLOCK_SKEW_SECONDS, CAPABILITY_PROOF_MAX_LIFETIME_SECONDS,
    CapabilityProofRequest, CapabilityProofVerificationContext, SignedCapabilityProof,
    sign_capability_proof, signed_capability_proof_challenge, signed_capability_proof_digest,
};
use crate::core::secure_mesh_crypto::{
    OpenedSecureMeshPayload, SecureMeshContentContext, SecureMeshPayloadKind, SecureMeshPlaintext,
};
use crate::core::secure_mesh_directory::{AuthorizedDirectoryLeaf, DirectoryAuthorizationPurpose};

use crate::core::secure_mesh_mls::{
    MLS_CAPABILITY_EXTENSION_SCHEMA_VERSION, SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION,
    SECURE_MESH_MLS_CIPHER_SUITE, SecureMeshMlsCapabilityExtension, SecureMeshMlsCommit,
    SecureMeshMlsGroup, SecureMeshMlsGroupMetadata, SecureMeshMlsKeyPackage,
    SecureMeshMlsMemberCapabilityProof, SecureMeshMlsParticipant, SecureMeshMlsRosterTransition,
    SecureMeshMlsWelcome, secure_mesh_mls_capability_extension_digest,
};
use crate::core::secure_mesh_session_negotiation::{
    CapabilityProofPeer, CapabilityProofReplayGuard, SecureMeshSessionKind,
    accept_mls_capability_binding, create_mls_capability_binding,
};
use crate::core::secure_mesh_trust::{DeviceTrustPublicIdentity, DeviceTrustState};

/// The product path is wired through typed native actions and selected custody. Release evidence
/// remains pending until the requested physical multi-client matrix is accepted.
pub const SECURE_MESH_MLS_PRODUCT_POLICY_STATUS: &str = "cryptographic_native_path_wired_local_persisted_trust_and_authorized_directory_leaf_kt_authority_physical_matrix_pending";

const MLS_CREDENTIAL_MAGIC: &[u8] = b"LCOSM-MLS-CRED-v1";
const MAX_ROSTER: usize = 256;
const MAX_EPOCH_LAG: u64 = 2;
pub const SECURE_MESH_MLS_CAPABILITY_POLICY_REVISION: u64 = 2;

const MAX_PERSISTED_MLS_CAPABILITY_PROOFS: usize = 4096;
const MAX_PERSISTED_MLS_KEY_PACKAGES_PER_SCOPE: usize = 4096;
const MAX_INCOMPLETE_MLS_OPERATIONS_PER_SCOPE: usize = 16;
const MAX_DELIVERED_MLS_OPERATIONS_PER_SCOPE: usize = 256;
const STALE_EMPTY_PREPARED_OPERATION_SECONDS: i64 = 86_400;
const MLS_SECURITY_LEDGER_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS secure_mesh_mls_keypackage_uses (
    consumer_endpoint_id TEXT NOT NULL,
    key_package_id TEXT NOT NULL,
    key_package_public_key_hash TEXT NOT NULL,
    group_id_hash TEXT NOT NULL,
    used_at TEXT NOT NULL,
    PRIMARY KEY (consumer_endpoint_id, key_package_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS secure_mesh_mls_keypackage_pubkey_hash_uq
    ON secure_mesh_mls_keypackage_uses (consumer_endpoint_id, key_package_public_key_hash);
CREATE TABLE IF NOT EXISTS secure_mesh_mls_capability_proof_uses (
    local_endpoint_scope_hash TEXT NOT NULL,
    proof_digest TEXT NOT NULL,
    expires_at_unix_seconds INTEGER NOT NULL,
    consumed_at_unix_seconds INTEGER NOT NULL,
    PRIMARY KEY (local_endpoint_scope_hash, proof_digest)
);
CREATE INDEX IF NOT EXISTS secure_mesh_mls_capability_proof_expiry_idx
    ON secure_mesh_mls_capability_proof_uses(expires_at_unix_seconds);
CREATE TABLE IF NOT EXISTS secure_mesh_mls_time_guard (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    max_observed_unix_seconds INTEGER NOT NULL CHECK (max_observed_unix_seconds >= 0)
);
INSERT OR IGNORE INTO secure_mesh_mls_time_guard(singleton, max_observed_unix_seconds)
    VALUES(1, 0);
CREATE TABLE IF NOT EXISTS secure_mesh_mls_operations (
    operation_id TEXT PRIMARY KEY,
    local_endpoint_scope_hash TEXT NOT NULL,
    action TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    state TEXT NOT NULL,
    response_json TEXT,
    group_id_base64url TEXT,
    base_metadata_json TEXT,
    expected_metadata_json TEXT,
    prepared_security_json TEXT,
    created_at_unix_seconds INTEGER NOT NULL,
    updated_at_unix_seconds INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS secure_mesh_mls_operation_reservations (
    local_endpoint_scope_hash TEXT NOT NULL,
    reservation_key TEXT NOT NULL,
    operation_id TEXT NOT NULL,
    PRIMARY KEY (local_endpoint_scope_hash, reservation_key),
    FOREIGN KEY (operation_id) REFERENCES secure_mesh_mls_operations(operation_id)
        ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS secure_mesh_mls_operation_state_idx
    ON secure_mesh_mls_operations(state, updated_at_unix_seconds);
"#;

pub fn secure_mesh_mls_build_protocol_digest() -> Result<String> {
    secure_mesh_mls_build_protocol_digest_for_revision(SECURE_MESH_PROTOCOL_BUILD_REVISION)
}

fn secure_mesh_mls_build_protocol_digest_for_revision(profile_revision: u64) -> Result<String> {
    let mut transcript = Vec::new();
    transcript.extend_from_slice(b"LICO-SM-MLS-BUILD-PROTOCOL-v1");
    append_len_prefixed(
        &mut transcript,
        SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION.as_bytes(),
    )?;
    append_len_prefixed(&mut transcript, SECURE_MESH_MLS_CIPHER_SUITE.as_bytes())?;
    transcript.extend_from_slice(&profile_revision.to_be_bytes());
    transcript.extend_from_slice(&SECURE_MESH_MLS_CAPABILITY_POLICY_REVISION.to_be_bytes());
    append_len_prefixed(&mut transcript, capability_catalog()?.digest().as_bytes())?;
    let digest: [u8; 32] = Sha256::digest(transcript).into();
    Ok(crate::core::secure_mesh_capability_proof::encode_sha256_digest(&digest))
}

fn mls_key_package_capability_challenge(key_package: &SecureMeshMlsKeyPackage) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(b"LICO-SM-MLS-KEYPACKAGE-CAPABILITY-CHALLENGE-v1");
    hasher.update(key_package.as_public_bytes());
    hasher.finalize().into()
}

fn mls_capability_proof_request(
    challenge: [u8; 32],
    now: OffsetDateTime,
) -> Result<CapabilityProofRequest> {
    let issued_at_unix_seconds = now.unix_timestamp();
    let expires_at_unix_seconds = issued_at_unix_seconds
        .checked_add(CAPABILITY_PROOF_MAX_LIFETIME_SECONDS)
        .ok_or_else(|| anyhow!("secure mesh MLS capability proof time is invalid"))?;
    Ok(CapabilityProofRequest {
        build_protocol_digest: secure_mesh_mls_build_protocol_digest()?,
        policy_revision: SECURE_MESH_MLS_CAPABILITY_POLICY_REVISION,
        challenge,
        issued_at_unix_seconds,
        expires_at_unix_seconds,
    })
}

fn mls_capability_verification_context(
    challenge: [u8; 32],
    now: OffsetDateTime,
) -> Result<CapabilityProofVerificationContext> {
    Ok(CapabilityProofVerificationContext {
        expected_build_protocol_digest: secure_mesh_mls_build_protocol_digest()?,
        expected_policy_revision: SECURE_MESH_MLS_CAPABILITY_POLICY_REVISION,
        expected_challenge: challenge,
        now_unix_seconds: now.unix_timestamp(),
    })
}

pub fn sign_mls_keypackage_capability_proof(
    identity: &DeviceTrustPublicIdentity,
    signing_key: &SigningKey,
    evaluation: &CapabilityEvaluation,
    key_package: &SecureMeshMlsKeyPackage,
    now: OffsetDateTime,
) -> Result<SignedCapabilityProof> {
    sign_capability_proof(
        identity,
        signing_key,
        evaluation,
        &mls_capability_proof_request(mls_key_package_capability_challenge(key_package), now)?,
    )
}

fn verify_active_mls_capability_extension(
    extension: &SecureMeshMlsCapabilityExtension,
    committer_identity: &DeviceTrustPublicIdentity,
    added_member_identity: &DeviceTrustPublicIdentity,
    now: OffsetDateTime,
) -> Result<BTreeSet<SecurityCapability>> {
    let SecureMeshMlsCapabilityExtension::Active {
        committer_endpoint_id,
        roster_transition,
        member_capability_proofs,
        group_negotiated_protocol_capabilities,
        ..
    } = extension
    else {
        return Err(anyhow!(
            "secure mesh MLS member capability negotiation is incomplete"
        ));
    };
    let SecureMeshMlsRosterTransition::MemberAdded {
        member_endpoint_id: added_member_endpoint_id,
        pair_binding,
    } = roster_transition
    else {
        return Err(anyhow!(
            "secure mesh MLS capability extension is not a member-add transition"
        ));
    };
    ensure!(
        committer_endpoint_id == &committer_identity.endpoint_id
            && added_member_endpoint_id == &added_member_identity.endpoint_id,
        "secure mesh MLS capability extension pair identity is invalid"
    );
    let committer_record = member_capability_proofs
        .get(committer_endpoint_id)
        .ok_or_else(|| anyhow!("secure mesh MLS committer capability proof is missing"))?;
    let added_member_record = member_capability_proofs
        .get(added_member_endpoint_id)
        .ok_or_else(|| anyhow!("secure mesh MLS added member capability proof is missing"))?;
    ensure!(
        pair_binding.session_kind == SecureMeshSessionKind::Mls,
        "secure mesh MLS capability binding has the wrong session kind"
    );
    let challenge = signed_capability_proof_challenge(&added_member_record.proof)?;
    let context = mls_capability_verification_context(challenge, now)?;
    let mut verification_guard = CapabilityProofReplayGuard::default();
    let negotiation = accept_mls_capability_binding(
        CapabilityProofPeer {
            identity: committer_identity,
            proof: &committer_record.proof,
            verification_context: &context,
        },
        CapabilityProofPeer {
            identity: added_member_identity,
            proof: &added_member_record.proof,
            verification_context: &context,
        },
        &pair_binding.base_transcript_digest,
        pair_binding,
        &mut verification_guard,
    )?;
    ensure!(
        group_negotiated_protocol_capabilities
            .is_subset(&negotiation.binding().negotiated_protocol_capabilities),
        "secure mesh MLS group capability extension overclaims the added pair"
    );
    Ok(negotiation
        .binding()
        .negotiated_protocol_capabilities
        .clone())
}

fn active_pair_capability_proofs(
    extension: &SecureMeshMlsCapabilityExtension,
) -> Result<(&SignedCapabilityProof, &SignedCapabilityProof)> {
    let SecureMeshMlsCapabilityExtension::Active {
        committer_endpoint_id,
        roster_transition,
        member_capability_proofs,
        ..
    } = extension
    else {
        return Err(anyhow!(
            "secure mesh MLS member capability negotiation is incomplete"
        ));
    };
    let SecureMeshMlsRosterTransition::MemberAdded {
        member_endpoint_id: added_member_endpoint_id,
        ..
    } = roster_transition
    else {
        return Err(anyhow!(
            "secure mesh MLS capability extension is not a member-add transition"
        ));
    };
    let committer = member_capability_proofs
        .get(committer_endpoint_id)
        .ok_or_else(|| anyhow!("secure mesh MLS committer capability proof is missing"))?;
    let added_member = member_capability_proofs
        .get(added_member_endpoint_id)
        .ok_or_else(|| anyhow!("secure mesh MLS added member capability proof is missing"))?;
    Ok((&committer.proof, &added_member.proof))
}

fn capability_intersection_from_member_proofs(
    member_capability_proofs: &BTreeMap<String, SecureMeshMlsMemberCapabilityProof>,
) -> Result<BTreeSet<SecurityCapability>> {
    ensure!(
        !member_capability_proofs.is_empty() && member_capability_proofs.len() <= MAX_ROSTER,
        "secure mesh MLS member capability proof map size is invalid"
    );
    let catalog = capability_catalog()?;
    let mut proof_records = member_capability_proofs.iter();
    let (first_endpoint_id, first_record) = proof_records
        .next()
        .ok_or_else(|| anyhow!("secure mesh MLS member capability proof map is empty"))?;
    ensure!(
        first_endpoint_id == &first_record.endpoint_id,
        "secure mesh MLS member capability proof record is invalid"
    );
    validate_capability_proof_acceptance_time(first_record)?;
    let mut intersection = first_record
        .proof
        .claims
        .enabled
        .iter()
        .copied()
        .filter(|capability| {
            catalog
                .definition(*capability)
                .is_some_and(|definition| definition.scope == CapabilityScope::ProtocolSession)
        })
        .collect::<BTreeSet<_>>();
    for (endpoint_id, record) in proof_records {
        ensure!(
            endpoint_id == &record.endpoint_id,
            "secure mesh MLS member capability proof record is invalid"
        );
        validate_capability_proof_acceptance_time(record)?;
        intersection.retain(|capability| record.proof.claims.enabled.contains(capability));
    }
    let missing_mandatory = catalog
        .definitions()
        .filter(|definition| definition.mandatory)
        .any(|definition| !intersection.contains(&definition.capability));
    ensure!(
        !missing_mandatory,
        "secure mesh MLS group mandatory capability intersection failed"
    );
    Ok(intersection)
}

fn verify_complete_member_capability_proof_map(
    extension: &SecureMeshMlsCapabilityExtension,
    expected_roster_endpoint_ids: &BTreeSet<String>,
    trusted_roster: &BTreeMap<String, DeviceTrustPublicIdentity>,
) -> Result<()> {
    let SecureMeshMlsCapabilityExtension::Active {
        member_capability_proofs,
        group_negotiated_protocol_capabilities,
        ..
    } = extension
    else {
        return Err(anyhow!(
            "secure mesh MLS member capability negotiation is incomplete"
        ));
    };
    ensure!(
        member_capability_proofs
            .keys()
            .cloned()
            .collect::<BTreeSet<_>>()
            == *expected_roster_endpoint_ids
            && trusted_roster.keys().cloned().collect::<BTreeSet<_>>()
                == *expected_roster_endpoint_ids,
        "secure mesh MLS member capability proof map does not match roster"
    );
    for (endpoint_id, record) in member_capability_proofs {
        let identity = trusted_roster
            .get(endpoint_id)
            .ok_or_else(|| anyhow!("secure mesh MLS member capability identity is not trusted"))?;
        ensure!(
            record.endpoint_id == *endpoint_id,
            "secure mesh MLS member capability proof record is invalid"
        );
        validate_capability_proof_acceptance_time(record)?;
        let context = CapabilityProofVerificationContext {
            expected_build_protocol_digest: secure_mesh_mls_build_protocol_digest()?,
            expected_policy_revision: SECURE_MESH_MLS_CAPABILITY_POLICY_REVISION,
            expected_challenge: signed_capability_proof_challenge(&record.proof)?,
            now_unix_seconds: record.accepted_at_unix_seconds,
        };
        crate::core::secure_mesh_capability_proof::verify_capability_proof(
            identity,
            &record.proof,
            &context,
        )?;
    }
    ensure!(
        group_negotiated_protocol_capabilities
            == &capability_intersection_from_member_proofs(member_capability_proofs)?,
        "secure mesh MLS cumulative capability intersection is invalid"
    );
    Ok(())
}

fn validate_capability_proof_acceptance_time(
    record: &SecureMeshMlsMemberCapabilityProof,
) -> Result<()> {
    let latest_acceptable_issue = record
        .accepted_at_unix_seconds
        .checked_add(CAPABILITY_PROOF_MAX_CLOCK_SKEW_SECONDS)
        .ok_or_else(|| anyhow!("secure mesh MLS capability proof acceptance time is invalid"))?;
    ensure!(
        record.proof.claims.issued_at_unix_seconds <= latest_acceptable_issue
            && record.accepted_at_unix_seconds <= record.proof.claims.expires_at_unix_seconds,
        "secure mesh MLS capability proof acceptance time is outside freshness policy"
    );
    Ok(())
}

pub fn mls_credential_identity_bytes(identity: &DeviceTrustPublicIdentity) -> Result<Vec<u8>> {
    identity_validate(identity)?;
    let mut out = Vec::new();
    out.extend_from_slice(MLS_CREDENTIAL_MAGIC);
    append_len_prefixed(&mut out, identity.endpoint_id.as_bytes())?;
    out.extend_from_slice(&identity.rotation_epoch.to_be_bytes());
    append_len_prefixed(&mut out, &identity.identity_public_key)?;
    Ok(out)
}

pub fn device_identity_from_mls_credential(
    credential: &[u8],
    signing_public_key: &[u8],
) -> Result<DeviceTrustPublicIdentity> {
    ensure!(
        credential.starts_with(MLS_CREDENTIAL_MAGIC),
        "secure mesh MLS credential magic mismatch"
    );
    let mut offset = MLS_CREDENTIAL_MAGIC.len();
    let endpoint = read_len_prefixed(credential, &mut offset)?;
    ensure!(
        credential.len() >= offset + 8,
        "secure mesh MLS credential is truncated"
    );
    let rotation_epoch = u64::from_be_bytes(
        credential[offset..offset + 8]
            .try_into()
            .map_err(|_| anyhow!("secure mesh MLS credential rotation epoch is invalid"))?,
    );
    offset += 8;
    let identity_public_key = read_len_prefixed(credential, &mut offset)?;
    let identity_public_key: [u8; 32] = identity_public_key
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("secure mesh MLS credential identity public key is invalid"))?;
    let signing_public_key: [u8; 32] = signing_public_key
        .try_into()
        .map_err(|_| anyhow!("secure mesh MLS member signing public key is invalid"))?;
    DeviceTrustPublicIdentity::new(
        String::from_utf8(endpoint)
            .map_err(|_| anyhow!("secure mesh MLS credential endpoint is not utf8"))?,
        identity_public_key,
        signing_public_key,
        rotation_epoch,
    )
}

pub fn directory_roster_from_group(
    group: &SecureMeshMlsGroup,
) -> Result<BTreeMap<String, DeviceTrustPublicIdentity>> {
    let mut roster = BTreeMap::new();
    for (credential, signing_public_key) in group.member_credential_signing_pairs()? {
        let identity = device_identity_from_mls_credential(&credential, &signing_public_key)?;
        ensure!(
            roster
                .insert(identity.endpoint_id.clone(), identity)
                .is_none(),
            "secure mesh MLS group roster contains a duplicate endpoint"
        );
    }
    Ok(roster)
}

pub fn participant_from_device_identity(
    identity: &DeviceTrustPublicIdentity,
    device_signing_key: &SigningKey,
) -> Result<SecureMeshMlsParticipant> {
    identity_validate(identity)?;
    ensure!(
        device_signing_key.verifying_key().to_bytes() == identity.signing_public_key,
        "secure mesh MLS device signing key does not match trust identity"
    );
    let credential_identity = mls_credential_identity_bytes(identity)?;
    let signer = SignatureKeyPair::from_raw(
        SignatureScheme::ED25519,
        device_signing_key.to_bytes().to_vec(),
        identity.signing_public_key.to_vec(),
    );
    SecureMeshMlsParticipant::from_credential_parts(credential_identity, signer)
}

pub fn require_verified_member_trust(trust_state: &DeviceTrustState) -> Result<()> {
    ensure!(
        matches!(
            trust_state,
            DeviceTrustState::Verified | DeviceTrustState::CrossSigned
        ),
        "secure mesh MLS member trust is not verified"
    );
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshMlsExpectedInvitation {
    pub group_id: Vec<u8>,
    pub inviter_endpoint_id: String,
    pub expected_roster_endpoint_ids: BTreeSet<String>,
}

impl SecureMeshMlsExpectedInvitation {
    pub fn new(
        group_id: impl AsRef<[u8]>,
        inviter_endpoint_id: impl Into<String>,
        expected_roster_endpoint_ids: impl IntoIterator<Item = impl Into<String>>,
    ) -> Result<Self> {
        let inviter_endpoint_id = inviter_endpoint_id.into();
        ensure!(
            !inviter_endpoint_id.trim().is_empty(),
            "secure mesh MLS inviter endpoint id is required"
        );
        let expected_roster_endpoint_ids = expected_roster_endpoint_ids
            .into_iter()
            .map(Into::into)
            .collect::<BTreeSet<_>>();
        ensure!(
            !expected_roster_endpoint_ids.is_empty(),
            "secure mesh MLS expected roster is required"
        );
        ensure!(
            expected_roster_endpoint_ids.len() <= MAX_ROSTER,
            "secure mesh MLS expected roster is too large"
        );
        ensure!(
            expected_roster_endpoint_ids.contains(&inviter_endpoint_id),
            "secure mesh MLS inviter must be in the expected roster"
        );
        Ok(Self {
            group_id: group_id.as_ref().to_vec(),
            inviter_endpoint_id,
            expected_roster_endpoint_ids,
        })
    }
}

pub fn authorize_welcome_acceptance(
    invitation: &SecureMeshMlsExpectedInvitation,
    inviter_trust_state: &DeviceTrustState,
    welcome_group_id: &[u8],
) -> Result<()> {
    require_verified_member_trust(inviter_trust_state)?;
    ensure!(
        invitation.group_id == welcome_group_id,
        "secure mesh MLS welcome group id mismatch"
    );
    Ok(())
}

pub fn authorize_commit_sender(
    sender_endpoint_id: &str,
    sender_trust_state: &DeviceTrustState,
    roster_endpoint_ids: &BTreeSet<String>,
) -> Result<()> {
    require_verified_member_trust(sender_trust_state)?;
    ensure!(
        roster_endpoint_ids.contains(sender_endpoint_id),
        "secure mesh MLS commit sender is not in the verified roster"
    );
    Ok(())
}

pub fn cross_check_roster(
    expected_roster_endpoint_ids: &BTreeSet<String>,
    observed_credential_identities: &[Vec<u8>],
    trusted_identities: &BTreeMap<String, DeviceTrustPublicIdentity>,
) -> Result<()> {
    ensure!(
        expected_roster_endpoint_ids.len() == observed_credential_identities.len(),
        "secure mesh MLS roster size divergence"
    );
    let mut observed_endpoints = BTreeSet::new();
    for credential in observed_credential_identities {
        let endpoint_id = endpoint_id_from_credential_identity(credential)?;
        let trusted = trusted_identities.get(&endpoint_id).ok_or_else(|| {
            anyhow!("secure mesh MLS roster member lacks a trusted identity binding")
        })?;
        let expected = mls_credential_identity_bytes(trusted)?;
        ensure!(
            &expected == credential,
            "secure mesh MLS roster credential does not match trusted identity"
        );
        observed_endpoints.insert(endpoint_id);
    }
    ensure!(
        &observed_endpoints == expected_roster_endpoint_ids,
        "secure mesh MLS roster endpoint set divergence"
    );
    Ok(())
}

pub fn authorize_sender_endpoint_binding(
    context_sender_endpoint_id: &str,
    trusted_sender_endpoint_id: &str,
) -> Result<()> {
    ensure!(
        context_sender_endpoint_id == trusted_sender_endpoint_id,
        "secure mesh MLS forged sender endpoint rejected"
    );
    Ok(())
}

pub fn authorize_epoch_lag(current_epoch: u64, message_epoch: u64) -> Result<()> {
    ensure!(
        message_epoch <= current_epoch,
        "secure mesh MLS message epoch is from the future"
    );
    let lag = current_epoch.saturating_sub(message_epoch);
    ensure!(
        lag <= MAX_EPOCH_LAG,
        "secure mesh MLS epoch lag exceeds acceptance window; rejoin required"
    );
    Ok(())
}

pub fn authorize_member_add_with_directory(
    authorization: &AuthorizedDirectoryLeaf,
    member_identity: &DeviceTrustPublicIdentity,
    member_key_package: &SecureMeshMlsKeyPackage,
    member_directory_version: u64,
    member_key_package_version: u64,
) -> Result<()> {
    authorization.require_purpose(DirectoryAuthorizationPurpose::MlsMemberAdd)?;
    authorization.require_device_identity(member_identity)?;
    ensure!(
        authorization.claim().version() == member_directory_version,
        "secure mesh MLS directory publication version mismatch"
    );
    authorization.require_mls_key_package_digest(
        &hex_sha256(member_key_package.as_public_bytes()),
        member_key_package_version,
    )?;
    Ok(())
}

/// Durable, privacy-minimized ledger for every MLS one-time security input.
///
/// Member-add key-package consumption and both capability-proof consumptions are committed in
/// one SQLite transaction. Persisted identity and input values are hashes, never raw identifiers
/// or proofs.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct PreparedMlsCapabilityProofUse {
    proof_digest: String,
    expires_at_unix_seconds: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct PreparedMlsKeyPackageUse {
    key_package_id_hash: String,
    key_package_public_key_hash: String,
    group_id_hash: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct PreparedMlsSecurityInputs {
    local_endpoint_scope_hash: String,
    key_package: Option<PreparedMlsKeyPackageUse>,
    capability_proofs: [PreparedMlsCapabilityProofUse; 2],
    consumed_at_unix_seconds: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SecureMeshMlsOperationState {
    Prepared,
    CryptoPrepared,
    CryptoCommitted,
    MetadataReconciled,
    Delivered,
}

impl SecureMeshMlsOperationState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Prepared => "prepared",
            Self::CryptoPrepared => "crypto_prepared",
            Self::CryptoCommitted => "crypto_committed",
            Self::MetadataReconciled => "metadata_reconciled",
            Self::Delivered => "delivered",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value {
            "prepared" => Ok(Self::Prepared),
            "crypto_prepared" => Ok(Self::CryptoPrepared),
            "crypto_committed" => Ok(Self::CryptoCommitted),
            "metadata_reconciled" => Ok(Self::MetadataReconciled),
            "delivered" => Ok(Self::Delivered),
            _ => Err(anyhow!(
                "secure mesh MLS operation journal state is invalid"
            )),
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct SecureMeshMlsOperationRecord {
    pub operation_id: String,
    pub action: String,
    pub state: SecureMeshMlsOperationState,
    pub response: Option<Value>,
    pub group_id: Option<Vec<u8>>,
    pub base_metadata: Option<SecureMeshMlsGroupMetadata>,
    pub expected_metadata: Option<SecureMeshMlsGroupMetadata>,
}

pub struct SecureMeshMlsSecurityLedger {
    connection: Connection,
}

impl SecureMeshMlsSecurityLedger {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open(path)
            .map_err(|error| anyhow!("secure mesh MLS security ledger open failed: {error}"))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        let foreign_keys: i64 =
            connection.pragma_query_value(None, "foreign_keys", |row| row.get(0))?;
        ensure!(
            foreign_keys == 1,
            "secure mesh MLS security ledger foreign keys are disabled"
        );
        connection
            .execute_batch(MLS_SECURITY_LEDGER_SCHEMA)
            .map_err(|error| anyhow!("secure mesh MLS security ledger schema failed: {error}"))?;
        let mut statement = connection.prepare("PRAGMA table_info(secure_mesh_mls_operations)")?;
        let columns = statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(statement);
        if !columns
            .iter()
            .any(|column| column == "local_endpoint_scope_hash")
            || !columns.iter().any(|column| column == "base_metadata_json")
            || !columns.iter().any(|column| column == "group_id_base64url")
        {
            connection.execute_batch(
                r#"
                DROP TABLE IF EXISTS secure_mesh_mls_operation_reservations;
                DROP TABLE IF EXISTS secure_mesh_mls_operations;
                "#,
            )?;
            connection.execute_batch(MLS_SECURITY_LEDGER_SCHEMA)?;
        }
        Ok(Self { connection })
    }

    pub fn reset_for_kt_authority_change(&mut self) -> Result<()> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|_| anyhow!("secure mesh MLS KT-authority ledger reset failed"))?;
        transaction.execute("DELETE FROM secure_mesh_mls_operation_reservations", [])?;
        transaction.execute("DELETE FROM secure_mesh_mls_operations", [])?;
        transaction.execute("DELETE FROM secure_mesh_mls_capability_proof_uses", [])?;
        transaction.execute("DELETE FROM secure_mesh_mls_keypackage_uses", [])?;
        transaction.execute(
            "UPDATE secure_mesh_mls_time_guard SET max_observed_unix_seconds = 0 WHERE singleton = 1",
            [],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn begin_operation(
        &mut self,
        operation_id: &str,
        action: &str,
        request_digest: &str,
        local_identity: &DeviceTrustPublicIdentity,
        now_unix_seconds: i64,
    ) -> Result<SecureMeshMlsOperationRecord> {
        validate_operation_identity(operation_id, action, request_digest)?;
        let local_scope_hash = mls_security_scope_hash(local_identity)?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| anyhow!("secure mesh MLS operation begin failed: {error}"))?;
        let existing = read_operation_transaction(&tx, operation_id)?;
        if let Some((record, existing_action, existing_request_digest)) = existing {
            let existing_scope: String = tx.query_row(
                "SELECT local_endpoint_scope_hash FROM secure_mesh_mls_operations WHERE operation_id = ?1",
                params![operation_id],
                |row| row.get(0),
            )?;
            ensure!(
                existing_action == action
                    && existing_request_digest == request_digest
                    && existing_scope == local_scope_hash,
                "secure mesh MLS operation id conflicts with another request"
            );
            tx.commit().map_err(|error| {
                anyhow!("secure mesh MLS operation begin commit failed: {error}")
            })?;
            return Ok(record);
        }
        let stale_before = now_unix_seconds
            .checked_sub(STALE_EMPTY_PREPARED_OPERATION_SECONDS)
            .ok_or_else(|| anyhow!("secure mesh MLS operation cleanup time is invalid"))?;
        tx.execute(
            r#"
            DELETE FROM secure_mesh_mls_operations
            WHERE state = 'prepared'
              AND response_json IS NULL
              AND prepared_security_json IS NULL
              AND updated_at_unix_seconds < ?1
              AND NOT EXISTS (
                  SELECT 1 FROM secure_mesh_mls_operation_reservations reservations
                  WHERE reservations.operation_id = secure_mesh_mls_operations.operation_id
              )
            "#,
            params![stale_before],
        )?;
        tx.execute(
            r#"
            DELETE FROM secure_mesh_mls_operations
            WHERE operation_id IN (
                SELECT operation_id FROM secure_mesh_mls_operations
                WHERE local_endpoint_scope_hash = ?1 AND state = 'delivered'
                ORDER BY updated_at_unix_seconds DESC, operation_id DESC
                LIMIT -1 OFFSET ?2
            )
            "#,
            params![
                local_scope_hash,
                i64::try_from(MAX_DELIVERED_MLS_OPERATIONS_PER_SCOPE).unwrap_or(i64::MAX)
            ],
        )?;
        let incomplete_count: i64 = tx.query_row(
            r#"
            SELECT COUNT(*) FROM secure_mesh_mls_operations
            WHERE local_endpoint_scope_hash = ?1 AND state != 'delivered'
            "#,
            params![local_scope_hash],
            |row| row.get(0),
        )?;
        ensure!(
            usize::try_from(incomplete_count).unwrap_or(usize::MAX)
                < MAX_INCOMPLETE_MLS_OPERATIONS_PER_SCOPE,
            "secure mesh MLS incomplete operation journal is at capacity"
        );
        tx.execute(
            r#"
            INSERT INTO secure_mesh_mls_operations (
                operation_id,
                local_endpoint_scope_hash,
                action,
                request_digest,
                state,
                response_json,
                group_id_base64url,
                base_metadata_json,
                expected_metadata_json,
                prepared_security_json,
                created_at_unix_seconds,
                updated_at_unix_seconds
            ) VALUES (?1, ?2, ?3, ?4, 'prepared', NULL, NULL, NULL, NULL, NULL, ?5, ?5)
            "#,
            params![
                operation_id,
                local_scope_hash,
                action,
                request_digest,
                now_unix_seconds
            ],
        )?;
        tx.commit()
            .map_err(|error| anyhow!("secure mesh MLS operation begin commit failed: {error}"))?;
        self.operation(operation_id)?.ok_or_else(|| {
            anyhow!("secure mesh MLS operation disappeared after journal preparation")
        })
    }

    pub(crate) fn stage_operation(
        &mut self,
        operation_id: &str,
        response: &Value,
        group_id: &[u8],
        base_metadata: Option<&SecureMeshMlsGroupMetadata>,
        expected_metadata: &SecureMeshMlsGroupMetadata,
        prepared_security: &PreparedMlsSecurityInputs,
        now_unix_seconds: i64,
    ) -> Result<SecureMeshMlsOperationRecord> {
        validate_prepared_security_inputs(prepared_security, now_unix_seconds)?;
        ensure!(
            !group_id.is_empty(),
            "secure mesh MLS operation group id is required"
        );
        let group_id_base64url = general_purpose::URL_SAFE_NO_PAD.encode(group_id);
        ensure!(
            expected_metadata.group_id_hash == format!("sha256:{}", hex_sha256(group_id)),
            "secure mesh MLS operation group id does not match expected metadata"
        );
        let response_json = serde_json::to_string(response)
            .map_err(|_| anyhow!("secure mesh MLS operation response encoding failed"))?;
        let metadata_json = serde_json::to_string(expected_metadata)
            .map_err(|_| anyhow!("secure mesh MLS operation metadata encoding failed"))?;
        let base_metadata_json = base_metadata
            .map(serde_json::to_string)
            .transpose()
            .map_err(|_| anyhow!("secure mesh MLS operation base metadata encoding failed"))?;
        if let Some(base) = base_metadata {
            ensure!(
                base.group_id_hash == expected_metadata.group_id_hash
                    && base.participant_endpoint_id == expected_metadata.participant_endpoint_id
                    && expected_metadata.epoch > base.epoch,
                "secure mesh MLS operation base metadata does not strictly precede expected state"
            );
        }
        let security_json = serde_json::to_string(prepared_security)
            .map_err(|_| anyhow!("secure mesh MLS operation security encoding failed"))?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| anyhow!("secure mesh MLS operation stage failed: {error}"))?;
        let (record, _, _) = read_operation_transaction(&tx, operation_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS operation journal entry is missing"))?;
        let operation_scope: String = tx.query_row(
            "SELECT local_endpoint_scope_hash FROM secure_mesh_mls_operations WHERE operation_id = ?1",
            params![operation_id],
            |row| row.get(0),
        )?;
        ensure!(
            operation_scope == prepared_security.local_endpoint_scope_hash,
            "secure mesh MLS operation security scope differs from journal authority"
        );
        ensure!(
            matches!(
                record.state,
                SecureMeshMlsOperationState::Prepared | SecureMeshMlsOperationState::CryptoPrepared
            ),
            "secure mesh MLS committed operation cannot be restaged"
        );
        reserve_prepared_security_transaction(&tx, operation_id, prepared_security)?;
        reserve_operation_key_transaction(
            &tx,
            operation_id,
            &prepared_security.local_endpoint_scope_hash,
            "participant-writer",
        )?;
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_mls_operations
            SET state = 'crypto_prepared',
                response_json = ?1,
                group_id_base64url = ?2,
                base_metadata_json = ?3,
                expected_metadata_json = ?4,
                prepared_security_json = ?5,
                updated_at_unix_seconds = ?6
            WHERE operation_id = ?7
              AND state IN ('prepared', 'crypto_prepared')
            "#,
            params![
                response_json,
                group_id_base64url,
                base_metadata_json,
                metadata_json,
                security_json,
                now_unix_seconds,
                operation_id
            ],
        )?;
        ensure!(
            changed == 1,
            "secure mesh MLS operation stage lost journal ownership"
        );
        tx.commit()
            .map_err(|error| anyhow!("secure mesh MLS operation stage commit failed: {error}"))?;
        self.operation(operation_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS staged operation disappeared"))
    }

    pub(crate) fn reset_crypto_prepared_operation_for_retry(
        &mut self,
        operation_id: &str,
        now_unix_seconds: i64,
    ) -> Result<SecureMeshMlsOperationRecord> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (record, _, _) = read_operation_transaction(&tx, operation_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS operation journal entry is missing"))?;
        if record.state == SecureMeshMlsOperationState::Prepared {
            tx.commit()?;
            return Ok(record);
        }
        ensure!(
            record.state == SecureMeshMlsOperationState::CryptoPrepared,
            "secure mesh MLS committed operation cannot reset for retry"
        );
        tx.execute(
            "DELETE FROM secure_mesh_mls_operation_reservations WHERE operation_id = ?1",
            params![operation_id],
        )?;
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_mls_operations
            SET state = 'prepared',
                response_json = NULL,
                group_id_base64url = NULL,
                base_metadata_json = NULL,
                expected_metadata_json = NULL,
                prepared_security_json = NULL,
                updated_at_unix_seconds = ?1
            WHERE operation_id = ?2 AND state = 'crypto_prepared'
            "#,
            params![now_unix_seconds, operation_id],
        )?;
        ensure!(
            changed == 1,
            "secure mesh MLS operation retry reset lost ownership"
        );
        tx.commit()?;
        self.operation(operation_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS reset operation disappeared"))
    }

    pub(crate) fn abort_empty_prepared_operation(&mut self, operation_id: &str) -> Result<bool> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| anyhow!("secure mesh MLS empty operation abort failed: {error}"))?;
        let removed = tx.execute(
            r#"
            DELETE FROM secure_mesh_mls_operations
            WHERE operation_id = ?1
              AND state = 'prepared'
              AND response_json IS NULL
              AND group_id_base64url IS NULL
              AND base_metadata_json IS NULL
              AND expected_metadata_json IS NULL
              AND prepared_security_json IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM secure_mesh_mls_operation_reservations reservations
                  WHERE reservations.operation_id = secure_mesh_mls_operations.operation_id
              )
            "#,
            params![operation_id],
        )?;
        ensure!(
            removed <= 1,
            "secure mesh MLS empty operation abort affected multiple records"
        );
        tx.commit().map_err(|error| {
            anyhow!("secure mesh MLS empty operation abort commit failed: {error}")
        })?;
        Ok(removed == 1)
    }

    pub(crate) fn commit_operation_crypto(
        &mut self,
        operation_id: &str,
        observed_metadata: &SecureMeshMlsGroupMetadata,
        now_unix_seconds: i64,
    ) -> Result<SecureMeshMlsOperationRecord> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| anyhow!("secure mesh MLS operation crypto commit failed: {error}"))?;
        let (record, _, _) = read_operation_transaction(&tx, operation_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS operation journal entry is missing"))?;
        let expected_metadata = record
            .expected_metadata
            .as_ref()
            .ok_or_else(|| anyhow!("secure mesh MLS operation expected metadata is missing"))?;
        ensure!(
            expected_metadata == observed_metadata,
            "secure mesh MLS operation snapshot does not match prepared crypto state"
        );
        if matches!(
            record.state,
            SecureMeshMlsOperationState::CryptoCommitted
                | SecureMeshMlsOperationState::MetadataReconciled
                | SecureMeshMlsOperationState::Delivered
        ) {
            tx.commit().map_err(|error| {
                anyhow!("secure mesh MLS operation crypto recovery commit failed: {error}")
            })?;
            return Ok(record);
        }
        ensure!(
            record.state == SecureMeshMlsOperationState::CryptoPrepared,
            "secure mesh MLS operation crypto state is not prepared"
        );
        let security_json: String = tx.query_row(
            "SELECT prepared_security_json FROM secure_mesh_mls_operations WHERE operation_id = ?1",
            params![operation_id],
            |row| row.get(0),
        )?;
        let prepared: PreparedMlsSecurityInputs = serde_json::from_str(&security_json)
            .map_err(|_| anyhow!("secure mesh MLS prepared security journal is invalid"))?;
        validate_prepared_security_inputs(&prepared, prepared.consumed_at_unix_seconds)?;
        consume_prepared_security_transaction(&tx, &prepared, now_unix_seconds)?;
        for reservation_key in reservation_keys(&prepared) {
            let removed = tx.execute(
                r#"
                DELETE FROM secure_mesh_mls_operation_reservations
                WHERE operation_id = ?1
                  AND local_endpoint_scope_hash = ?2
                  AND reservation_key = ?3
                "#,
                params![
                    operation_id,
                    prepared.local_endpoint_scope_hash,
                    reservation_key
                ],
            )?;
            ensure!(
                removed == 1,
                "secure mesh MLS operation security reservation is incomplete"
            );
        }
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_mls_operations
            SET state = 'crypto_committed', updated_at_unix_seconds = ?1
            WHERE operation_id = ?2 AND state = 'crypto_prepared'
            "#,
            params![now_unix_seconds, operation_id],
        )?;
        ensure!(
            changed == 1,
            "secure mesh MLS operation crypto journal commit failed"
        );
        tx.commit()
            .map_err(|error| anyhow!("secure mesh MLS operation crypto commit failed: {error}"))?;
        self.operation(operation_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS committed operation disappeared"))
    }

    pub(crate) fn mark_operation_metadata_reconciled(
        &mut self,
        operation_id: &str,
        final_response: &Value,
        now_unix_seconds: i64,
    ) -> Result<SecureMeshMlsOperationRecord> {
        let response_json = serde_json::to_string(final_response)
            .map_err(|_| anyhow!("secure mesh MLS final response encoding failed"))?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (record, _, _) = read_operation_transaction(&tx, operation_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS operation journal entry is missing"))?;
        if matches!(
            record.state,
            SecureMeshMlsOperationState::MetadataReconciled
                | SecureMeshMlsOperationState::Delivered
        ) {
            ensure!(
                record.response.as_ref() == Some(final_response),
                "secure mesh MLS same-state metadata response diverges"
            );
            tx.commit()?;
            return Ok(record);
        }
        ensure!(
            record.state == SecureMeshMlsOperationState::CryptoCommitted,
            "secure mesh MLS metadata journal transition is invalid"
        );
        let writer_reservation_removed = tx.execute(
            r#"
            DELETE FROM secure_mesh_mls_operation_reservations
            WHERE operation_id = ?1 AND reservation_key = 'participant-writer'
            "#,
            params![operation_id],
        )?;
        ensure!(
            writer_reservation_removed == 1,
            "secure mesh MLS participant writer reservation is missing"
        );
        let changed = tx.execute(
            r#"
            UPDATE secure_mesh_mls_operations
            SET state = 'metadata_reconciled', response_json = ?1, updated_at_unix_seconds = ?2
            WHERE operation_id = ?3 AND state = 'crypto_committed'
            "#,
            params![response_json, now_unix_seconds, operation_id],
        )?;
        ensure!(
            changed == 1,
            "secure mesh MLS metadata journal transition lost ownership"
        );
        tx.commit()?;
        self.operation(operation_id)?.ok_or_else(|| {
            anyhow!("secure mesh MLS operation disappeared after metadata reconciliation")
        })
    }

    pub(crate) fn mark_operation_delivered(
        &mut self,
        operation_id: &str,
        now_unix_seconds: i64,
    ) -> Result<SecureMeshMlsOperationRecord> {
        self.advance_operation_state(
            operation_id,
            SecureMeshMlsOperationState::MetadataReconciled,
            SecureMeshMlsOperationState::Delivered,
            now_unix_seconds,
        )
    }

    pub(crate) fn operation(
        &self,
        operation_id: &str,
    ) -> Result<Option<SecureMeshMlsOperationRecord>> {
        read_operation_connection(&self.connection, operation_id)
            .map(|value| value.map(|(record, _, _)| record))
    }

    pub(crate) fn incomplete_writer_operations(
        &self,
        local_identity: &DeviceTrustPublicIdentity,
    ) -> Result<Vec<SecureMeshMlsOperationRecord>> {
        let scope = mls_security_scope_hash(local_identity)?;
        let mut statement = self.connection.prepare(
            r#"
            SELECT operations.operation_id
            FROM secure_mesh_mls_operations operations
            INNER JOIN secure_mesh_mls_operation_reservations reservations
                ON reservations.operation_id = operations.operation_id
            WHERE operations.local_endpoint_scope_hash = ?1
              AND reservations.reservation_key = 'participant-writer'
              AND operations.state IN ('crypto_prepared', 'crypto_committed')
            ORDER BY operations.created_at_unix_seconds, operations.operation_id
            "#,
        )?;
        let ids = statement
            .query_map(params![scope], |row| row.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        ids.into_iter()
            .map(|operation_id| {
                self.operation(&operation_id)?.ok_or_else(|| {
                    anyhow!("secure mesh MLS incomplete writer operation disappeared")
                })
            })
            .collect()
    }

    fn advance_operation_state(
        &mut self,
        operation_id: &str,
        expected: SecureMeshMlsOperationState,
        next: SecureMeshMlsOperationState,
        now_unix_seconds: i64,
    ) -> Result<SecureMeshMlsOperationRecord> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (record, _, _) = read_operation_transaction(&tx, operation_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS operation journal entry is missing"))?;
        if record.state == next || record.state == SecureMeshMlsOperationState::Delivered {
            tx.commit()?;
            return Ok(record);
        }
        ensure!(
            record.state == expected,
            "secure mesh MLS operation journal transition is invalid"
        );
        let changed = tx.execute(
            "UPDATE secure_mesh_mls_operations SET state = ?1, updated_at_unix_seconds = ?2 WHERE operation_id = ?3 AND state = ?4",
            params![next.as_str(), now_unix_seconds, operation_id, expected.as_str()],
        )?;
        ensure!(
            changed == 1,
            "secure mesh MLS operation journal transition lost ownership"
        );
        if next == SecureMeshMlsOperationState::Delivered {
            let scope: String = tx.query_row(
                "SELECT local_endpoint_scope_hash FROM secure_mesh_mls_operations WHERE operation_id = ?1",
                params![operation_id],
                |row| row.get(0),
            )?;
            tx.execute(
                r#"
                DELETE FROM secure_mesh_mls_operations
                WHERE operation_id IN (
                    SELECT operation_id FROM secure_mesh_mls_operations
                    WHERE local_endpoint_scope_hash = ?1
                      AND state = 'delivered'
                      AND operation_id != ?3
                    ORDER BY updated_at_unix_seconds DESC, operation_id DESC
                    LIMIT -1 OFFSET ?2
                )
                "#,
                params![
                    scope,
                    i64::try_from(MAX_DELIVERED_MLS_OPERATIONS_PER_SCOPE)
                        .unwrap_or(i64::MAX)
                        .saturating_sub(1),
                    operation_id,
                ],
            )?;
        }
        tx.commit()?;
        self.operation(operation_id)?
            .ok_or_else(|| anyhow!("secure mesh MLS operation disappeared after transition"))
    }

    #[cfg(test)]
    fn was_key_package_consumed(
        &self,
        consumer_identity: &DeviceTrustPublicIdentity,
        key_package_id: &str,
    ) -> Result<bool> {
        let consumer_scope_hash = mls_security_scope_hash(consumer_identity)?;
        let key_package_id_hash = hex_sha256(key_package_id.as_bytes());
        let found: Option<i64> = self
            .connection
            .query_row(
                r#"
                SELECT 1 FROM secure_mesh_mls_keypackage_uses
                WHERE consumer_endpoint_id = ?1 AND key_package_id = ?2
                "#,
                params![consumer_scope_hash, key_package_id_hash],
                |row| row.get(0),
            )
            .optional()?;
        Ok(found.is_some())
    }

    #[cfg(test)]
    fn key_package_consumed_at(
        &self,
        consumer_identity: &DeviceTrustPublicIdentity,
        key_package_id: &str,
    ) -> Result<Option<i64>> {
        let consumer_scope_hash = mls_security_scope_hash(consumer_identity)?;
        let key_package_id_hash = hex_sha256(key_package_id.as_bytes());
        self.connection
            .query_row(
                r#"
                SELECT used_at FROM secure_mesh_mls_keypackage_uses
                WHERE consumer_endpoint_id = ?1 AND key_package_id = ?2
                "#,
                params![consumer_scope_hash, key_package_id_hash],
                |row| {
                    let value: String = row.get(0)?;
                    value.parse::<i64>().map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            value.len(),
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })
                },
            )
            .optional()
            .map_err(Into::into)
    }
}

pub(crate) fn prepare_member_add_security_inputs(
    consumer_identity: &DeviceTrustPublicIdentity,
    key_package_id: &str,
    key_package_public_bytes: &[u8],
    group_id_hash: &str,
    first_proof: &SignedCapabilityProof,
    second_proof: &SignedCapabilityProof,
    now_unix_seconds: i64,
) -> Result<PreparedMlsSecurityInputs> {
    ensure!(
        !key_package_id.trim().is_empty(),
        "secure mesh MLS keypackage id is required"
    );
    let mut prepared = prepare_capability_security_inputs(
        consumer_identity,
        first_proof,
        second_proof,
        now_unix_seconds,
    )?;
    prepared.key_package = Some(PreparedMlsKeyPackageUse {
        key_package_id_hash: hex_sha256(key_package_id.as_bytes()),
        key_package_public_key_hash: hex_sha256(key_package_public_bytes),
        group_id_hash: group_id_hash.to_string(),
    });
    Ok(prepared)
}

pub(crate) fn prepare_capability_security_inputs(
    observing_identity: &DeviceTrustPublicIdentity,
    first_proof: &SignedCapabilityProof,
    second_proof: &SignedCapabilityProof,
    now_unix_seconds: i64,
) -> Result<PreparedMlsSecurityInputs> {
    let first = PreparedMlsCapabilityProofUse {
        proof_digest: signed_capability_proof_digest(first_proof)?,
        expires_at_unix_seconds: first_proof.claims.expires_at_unix_seconds,
    };
    let second = PreparedMlsCapabilityProofUse {
        proof_digest: signed_capability_proof_digest(second_proof)?,
        expires_at_unix_seconds: second_proof.claims.expires_at_unix_seconds,
    };
    let prepared = PreparedMlsSecurityInputs {
        local_endpoint_scope_hash: mls_security_scope_hash(observing_identity)?,
        key_package: None,
        capability_proofs: [first, second],
        consumed_at_unix_seconds: now_unix_seconds,
    };
    validate_prepared_security_inputs(&prepared, now_unix_seconds)?;
    Ok(prepared)
}

pub(crate) fn empty_prepared_security_inputs(
    observing_identity: &DeviceTrustPublicIdentity,
    now_unix_seconds: i64,
) -> Result<PreparedMlsSecurityInputs> {
    let placeholder = PreparedMlsCapabilityProofUse {
        proof_digest: format!(
            "none:{}",
            hex_sha256(b"secure-mesh-mls-no-capability-update")
        ),
        expires_at_unix_seconds: i64::MAX,
    };
    Ok(PreparedMlsSecurityInputs {
        local_endpoint_scope_hash: mls_security_scope_hash(observing_identity)?,
        key_package: None,
        capability_proofs: [placeholder.clone(), placeholder],
        consumed_at_unix_seconds: now_unix_seconds,
    })
}

fn validate_operation_identity(
    operation_id: &str,
    action: &str,
    request_digest: &str,
) -> Result<()> {
    for (label, value) in [
        ("operation id", operation_id),
        ("request digest", request_digest),
    ] {
        ensure!(
            value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "secure mesh MLS {label} is invalid"
        );
    }
    ensure!(
        matches!(
            action,
            "secure_mesh.mls.member.add"
                | "secure_mesh.mls.member.remove"
                | "secure_mesh.mls.group.join"
                | "secure_mesh.mls.commit.process"
        ),
        "secure mesh MLS journal action is invalid"
    );
    Ok(())
}

fn validate_prepared_security_inputs(
    prepared: &PreparedMlsSecurityInputs,
    now_unix_seconds: i64,
) -> Result<()> {
    ensure!(
        prepared.local_endpoint_scope_hash.len() == 64,
        "secure mesh MLS prepared security scope is invalid"
    );
    let [first, second] = &prepared.capability_proofs;
    let no_capability_update = first.proof_digest.starts_with("none:")
        && first == second
        && prepared.key_package.is_none();
    if no_capability_update {
        return Ok(());
    }
    ensure!(
        first.proof_digest != second.proof_digest,
        "secure mesh MLS prepared capability proofs must be distinct"
    );
    ensure!(
        first.expires_at_unix_seconds >= now_unix_seconds
            && second.expires_at_unix_seconds >= now_unix_seconds,
        "secure mesh MLS prepared capability proof is expired"
    );
    if let Some(key_package) = &prepared.key_package {
        ensure!(
            !key_package.group_id_hash.is_empty()
                && key_package.key_package_id_hash.len() == 64
                && key_package.key_package_public_key_hash.len() == 64,
            "secure mesh MLS prepared keypackage input is invalid"
        );
    }
    Ok(())
}

fn reservation_keys(prepared: &PreparedMlsSecurityInputs) -> Vec<String> {
    let mut keys = Vec::new();
    if let Some(key_package) = &prepared.key_package {
        keys.push(format!("keypackage-id:{}", key_package.key_package_id_hash));
        keys.push(format!(
            "keypackage-public:{}",
            key_package.key_package_public_key_hash
        ));
    }
    if !prepared.capability_proofs[0]
        .proof_digest
        .starts_with("none:")
    {
        for proof in &prepared.capability_proofs {
            keys.push(format!("capability-proof:{}", proof.proof_digest));
        }
    }
    keys
}

fn reserve_prepared_security_transaction(
    tx: &Transaction<'_>,
    operation_id: &str,
    prepared: &PreparedMlsSecurityInputs,
) -> Result<()> {
    let effective_now_unix_seconds =
        advance_mls_replay_time_watermark(tx, prepared.consumed_at_unix_seconds)?;
    validate_prepared_security_inputs(prepared, effective_now_unix_seconds)?;
    tx.execute(
        "DELETE FROM secure_mesh_mls_capability_proof_uses WHERE expires_at_unix_seconds < ?1",
        params![effective_now_unix_seconds],
    )?;
    if !prepared.capability_proofs[0]
        .proof_digest
        .starts_with("none:")
    {
        let used: i64 = tx.query_row(
            "SELECT COUNT(*) FROM secure_mesh_mls_capability_proof_uses WHERE local_endpoint_scope_hash = ?1",
            params![prepared.local_endpoint_scope_hash],
            |row| row.get(0),
        )?;
        let reserved: i64 = tx.query_row(
            r#"
            SELECT COUNT(*) FROM secure_mesh_mls_operation_reservations
            WHERE local_endpoint_scope_hash = ?1
              AND reservation_key LIKE 'capability-proof:%'
              AND operation_id != ?2
            "#,
            params![prepared.local_endpoint_scope_hash, operation_id],
            |row| row.get(0),
        )?;
        ensure!(
            usize::try_from(used.saturating_add(reserved))
                .unwrap_or(usize::MAX)
                .saturating_add(2)
                <= MAX_PERSISTED_MLS_CAPABILITY_PROOFS,
            "secure mesh MLS capability replay guard is at capacity"
        );
    }
    if let Some(key_package) = &prepared.key_package {
        let used_count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM secure_mesh_mls_keypackage_uses WHERE consumer_endpoint_id = ?1",
            params![prepared.local_endpoint_scope_hash],
            |row| row.get(0),
        )?;
        let reserved_count: i64 = tx.query_row(
            r#"
            SELECT COUNT(*) FROM secure_mesh_mls_operation_reservations
            WHERE local_endpoint_scope_hash = ?1
              AND reservation_key LIKE 'keypackage-id:%'
              AND operation_id != ?2
            "#,
            params![prepared.local_endpoint_scope_hash, operation_id],
            |row| row.get(0),
        )?;
        ensure!(
            usize::try_from(used_count.saturating_add(reserved_count)).unwrap_or(usize::MAX)
                < MAX_PERSISTED_MLS_KEY_PACKAGES_PER_SCOPE,
            "secure mesh MLS keypackage replay guard is at capacity"
        );
        let existing: i64 = tx.query_row(
            r#"
            SELECT COUNT(*) FROM secure_mesh_mls_keypackage_uses
            WHERE consumer_endpoint_id = ?1
              AND (key_package_id = ?2 OR key_package_public_key_hash = ?3)
            "#,
            params![
                prepared.local_endpoint_scope_hash,
                key_package.key_package_id_hash,
                key_package.key_package_public_key_hash
            ],
            |row| row.get(0),
        )?;
        ensure!(
            existing == 0,
            "secure mesh MLS keypackage was already consumed"
        );
    }
    for proof in &prepared.capability_proofs {
        if proof.proof_digest.starts_with("none:") {
            continue;
        }
        let existing: i64 = tx.query_row(
            r#"
            SELECT COUNT(*) FROM secure_mesh_mls_capability_proof_uses
            WHERE local_endpoint_scope_hash = ?1 AND proof_digest = ?2
            "#,
            params![prepared.local_endpoint_scope_hash, proof.proof_digest],
            |row| row.get(0),
        )?;
        ensure!(
            existing == 0,
            "secure mesh MLS capability proof replay rejected"
        );
    }
    for reservation_key in reservation_keys(prepared) {
        reserve_operation_key_transaction(
            tx,
            operation_id,
            &prepared.local_endpoint_scope_hash,
            &reservation_key,
        )?;
    }
    Ok(())
}

fn reserve_operation_key_transaction(
    tx: &Transaction<'_>,
    operation_id: &str,
    local_scope_hash: &str,
    reservation_key: &str,
) -> Result<()> {
    tx.execute(
        r#"
        INSERT OR IGNORE INTO secure_mesh_mls_operation_reservations (
            local_endpoint_scope_hash, reservation_key, operation_id
        ) VALUES (?1, ?2, ?3)
        "#,
        params![local_scope_hash, reservation_key, operation_id],
    )?;
    let owner: String = tx.query_row(
        r#"
        SELECT operation_id FROM secure_mesh_mls_operation_reservations
        WHERE local_endpoint_scope_hash = ?1 AND reservation_key = ?2
        "#,
        params![local_scope_hash, reservation_key],
        |row| row.get(0),
    )?;
    ensure!(
        owner == operation_id,
        "secure mesh MLS operation input is reserved by another writer"
    );
    Ok(())
}

fn consume_prepared_security_transaction(
    tx: &Transaction<'_>,
    prepared: &PreparedMlsSecurityInputs,
    now_unix_seconds: i64,
) -> Result<()> {
    let effective_now_unix_seconds = advance_mls_replay_time_watermark(tx, now_unix_seconds)?;
    validate_prepared_security_inputs(prepared, effective_now_unix_seconds)
        .map_err(|_| anyhow!("secure mesh MLS capability proof revived by clock rollback"))?;
    if let Some(key_package) = &prepared.key_package {
        consume_key_package_in_transaction(
            tx,
            &prepared.local_endpoint_scope_hash,
            &key_package.key_package_id_hash,
            &key_package.key_package_public_key_hash,
            &key_package.group_id_hash,
            prepared.consumed_at_unix_seconds,
        )?;
    }
    if prepared.capability_proofs[0]
        .proof_digest
        .starts_with("none:")
    {
        return Ok(());
    }
    tx.execute(
        "DELETE FROM secure_mesh_mls_capability_proof_uses WHERE expires_at_unix_seconds < ?1",
        params![effective_now_unix_seconds],
    )?;
    let unexpired_count: i64 = tx.query_row(
        r#"
        SELECT COUNT(*) FROM secure_mesh_mls_capability_proof_uses
        WHERE local_endpoint_scope_hash = ?1
        "#,
        params![prepared.local_endpoint_scope_hash],
        |row| row.get(0),
    )?;
    ensure!(
        usize::try_from(unexpired_count)
            .unwrap_or(usize::MAX)
            .saturating_add(2)
            <= MAX_PERSISTED_MLS_CAPABILITY_PROOFS,
        "secure mesh MLS capability replay guard is at capacity"
    );
    for proof in &prepared.capability_proofs {
        tx.execute(
            r#"
            INSERT INTO secure_mesh_mls_capability_proof_uses (
                local_endpoint_scope_hash,
                proof_digest,
                expires_at_unix_seconds,
                consumed_at_unix_seconds
            ) VALUES (?1, ?2, ?3, ?4)
            "#,
            params![
                prepared.local_endpoint_scope_hash,
                proof.proof_digest,
                proof.expires_at_unix_seconds,
                prepared.consumed_at_unix_seconds
            ],
        )?;
    }
    Ok(())
}

fn advance_mls_replay_time_watermark(tx: &Transaction<'_>, now_unix_seconds: i64) -> Result<i64> {
    ensure!(
        now_unix_seconds >= 0,
        "secure mesh MLS replay clock is before unix epoch"
    );
    let persisted: i64 = tx.query_row(
        "SELECT max_observed_unix_seconds FROM secure_mesh_mls_time_guard WHERE singleton = 1",
        [],
        |row| row.get(0),
    )?;
    let effective = persisted.max(now_unix_seconds);
    tx.execute(
        "UPDATE secure_mesh_mls_time_guard SET max_observed_unix_seconds = ?1 WHERE singleton = 1",
        params![effective],
    )?;
    Ok(effective)
}

fn read_operation_connection(
    connection: &Connection,
    operation_id: &str,
) -> Result<Option<(SecureMeshMlsOperationRecord, String, String)>> {
    connection
        .query_row(
            r#"
            SELECT action, request_digest, state, response_json, group_id_base64url,
                   base_metadata_json, expected_metadata_json
            FROM secure_mesh_mls_operations WHERE operation_id = ?1
            "#,
            params![operation_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                ))
            },
        )
        .optional()?
        .map(
            |(
                action,
                request_digest,
                state,
                response_json,
                group_id_base64url,
                base_metadata_json,
                metadata_json,
            )|
             -> Result<_> {
                let state = SecureMeshMlsOperationState::parse(&state)?;
                let response = response_json
                    .map(|json| {
                        serde_json::from_str(&json).map_err(|_| {
                            anyhow!("secure mesh MLS operation response journal is invalid")
                        })
                    })
                    .transpose()?;
                let expected_metadata = metadata_json
                    .map(|json| {
                        serde_json::from_str(&json).map_err(|_| {
                            anyhow!("secure mesh MLS operation metadata journal is invalid")
                        })
                    })
                    .transpose()?;
                let group_id = group_id_base64url
                    .map(|value| {
                        general_purpose::URL_SAFE_NO_PAD.decode(value).map_err(|_| {
                            anyhow!("secure mesh MLS operation group id journal is invalid")
                        })
                    })
                    .transpose()?;
                let base_metadata = base_metadata_json
                    .map(|json| {
                        serde_json::from_str(&json).map_err(|_| {
                            anyhow!("secure mesh MLS operation base metadata journal is invalid")
                        })
                    })
                    .transpose()?;
                Ok((
                    SecureMeshMlsOperationRecord {
                        operation_id: operation_id.to_string(),
                        action: action.clone(),
                        state,
                        response,
                        group_id,
                        base_metadata,
                        expected_metadata,
                    },
                    action,
                    request_digest,
                ))
            },
        )
        .transpose()
}

fn read_operation_transaction(
    tx: &Transaction<'_>,
    operation_id: &str,
) -> Result<Option<(SecureMeshMlsOperationRecord, String, String)>> {
    read_operation_connection(tx, operation_id)
}

fn mls_security_scope_hash(identity: &DeviceTrustPublicIdentity) -> Result<String> {
    let mut scope = Vec::new();
    scope.extend_from_slice(b"LICO-SM-MLS-SECURITY-LEDGER-SCOPE-v1");
    append_len_prefixed(&mut scope, &mls_credential_identity_bytes(identity)?)?;
    append_len_prefixed(&mut scope, &identity.signing_public_key)?;
    Ok(hex_sha256(&scope))
}

fn consume_key_package_in_transaction(
    tx: &Transaction<'_>,
    consumer_scope_hash: &str,
    key_package_id_hash: &str,
    public_key_hash: &str,
    group_id_hash: &str,
    now_unix_seconds: i64,
) -> Result<()> {
    let changed = tx.execute(
        r#"
        INSERT OR IGNORE INTO secure_mesh_mls_keypackage_uses (
            consumer_endpoint_id,
            key_package_id,
            key_package_public_key_hash,
            group_id_hash,
            used_at
        ) VALUES (?1, ?2, ?3, ?4, ?5)
        "#,
        params![
            consumer_scope_hash,
            key_package_id_hash,
            public_key_hash,
            group_id_hash,
            now_unix_seconds.to_string(),
        ],
    )?;
    ensure!(
        changed == 1,
        "secure mesh MLS keypackage was already consumed"
    );
    Ok(())
}

pub fn create_product_group(
    owner: &SecureMeshMlsParticipant,
    owner_identity: &DeviceTrustPublicIdentity,
    owner_trust_state: &DeviceTrustState,
    group_id: impl AsRef<[u8]>,
) -> Result<SecureMeshMlsGroup> {
    require_verified_member_trust(owner_trust_state)?;
    ensure!(
        participant_identity_matches(owner, owner_identity)?,
        "secure mesh MLS owner credential is not identity-bound"
    );
    SecureMeshMlsGroup::create(owner, group_id)
}

pub(crate) fn add_product_member_prepared(
    group: &mut SecureMeshMlsGroup,
    owner: &SecureMeshMlsParticipant,
    owner_identity: &DeviceTrustPublicIdentity,
    owner_signing_key: &SigningKey,
    owner_capability_evaluation: &CapabilityEvaluation,
    owner_trust_state: &DeviceTrustState,
    member_key_package: &SecureMeshMlsKeyPackage,
    member_identity: &DeviceTrustPublicIdentity,
    member_capability_proof: &SignedCapabilityProof,
    member_trust_state: &DeviceTrustState,
    member_directory_authorization: &AuthorizedDirectoryLeaf,
    member_directory_version: u64,
    member_key_package_version: u64,
    key_package_id: &str,
    now: OffsetDateTime,
) -> Result<(SecureMeshMlsWelcome, PreparedMlsSecurityInputs)> {
    require_verified_member_trust(owner_trust_state)?;
    require_verified_member_trust(member_trust_state)?;
    authorize_member_add_with_directory(
        member_directory_authorization,
        member_identity,
        member_key_package,
        member_directory_version,
        member_key_package_version,
    )?;
    ensure!(
        participant_identity_matches(owner, owner_identity)?,
        "secure mesh MLS owner credential is not identity-bound"
    );
    ensure!(
        key_package_identity_matches(member_key_package, member_identity)?,
        "secure mesh MLS keypackage credential is not identity-bound"
    );
    ensure!(
        owner_signing_key.verifying_key().to_bytes() == owner_identity.signing_public_key,
        "secure mesh MLS owner capability signing key does not match identity"
    );
    let previous_extension = group.capability_extension()?;
    if matches!(
        previous_extension,
        SecureMeshMlsCapabilityExtension::AwaitingMemberNegotiation { .. }
    ) {
        ensure!(
            group.member_count() == 1,
            "secure mesh MLS pre-existing members lack capability negotiation"
        );
    }
    let challenge = mls_key_package_capability_challenge(member_key_package);
    ensure!(
        signed_capability_proof_challenge(member_capability_proof)? == challenge,
        "secure mesh MLS member capability proof is not bound to its key package"
    );
    let owner_capability_proof = sign_capability_proof(
        owner_identity,
        owner_signing_key,
        owner_capability_evaluation,
        &mls_capability_proof_request(challenge, now)?,
    )?;
    let verification_context = mls_capability_verification_context(challenge, now)?;
    let owner_verified = crate::core::secure_mesh_capability_proof::verify_capability_proof(
        owner_identity,
        &owner_capability_proof,
        &verification_context,
    )?;
    let member_verified = crate::core::secure_mesh_capability_proof::verify_capability_proof(
        member_identity,
        member_capability_proof,
        &verification_context,
    )?;
    let base_transcript_digest = group.capability_add_base_transcript_digest(member_key_package)?;
    let pair_binding =
        create_mls_capability_binding(&owner_verified, &member_verified, &base_transcript_digest)?;
    let current_roster_endpoint_ids = group
        .member_credential_identities()?
        .into_iter()
        .map(|credential| endpoint_id_from_credential_identity(&credential))
        .collect::<Result<BTreeSet<_>>>()?;
    let (previous_extension_digest, mut member_capability_proofs) = match &previous_extension {
        SecureMeshMlsCapabilityExtension::AwaitingMemberNegotiation { .. } => {
            (None, BTreeMap::new())
        }
        SecureMeshMlsCapabilityExtension::Active {
            member_capability_proofs,
            ..
        } => {
            ensure!(
                member_capability_proofs
                    .keys()
                    .cloned()
                    .collect::<BTreeSet<_>>()
                    == current_roster_endpoint_ids,
                "secure mesh MLS prior member capability proof map does not match roster"
            );
            (
                Some(secure_mesh_mls_capability_extension_digest(
                    &previous_extension,
                )?),
                member_capability_proofs.clone(),
            )
        }
    };
    member_capability_proofs.insert(
        owner_identity.endpoint_id.clone(),
        SecureMeshMlsMemberCapabilityProof {
            endpoint_id: owner_identity.endpoint_id.clone(),
            accepted_at_unix_seconds: now.unix_timestamp(),
            proof: owner_capability_proof,
        },
    );
    ensure!(
        member_capability_proofs
            .insert(
                member_identity.endpoint_id.clone(),
                SecureMeshMlsMemberCapabilityProof {
                    endpoint_id: member_identity.endpoint_id.clone(),
                    accepted_at_unix_seconds: now.unix_timestamp(),
                    proof: member_capability_proof.clone(),
                },
            )
            .is_none(),
        "secure mesh MLS added member already has a capability proof record"
    );
    let mut expected_roster = current_roster_endpoint_ids;
    expected_roster.insert(member_identity.endpoint_id.clone());
    ensure!(
        member_capability_proofs
            .keys()
            .cloned()
            .collect::<BTreeSet<_>>()
            == expected_roster,
        "secure mesh MLS updated member capability proof map does not match roster"
    );
    let group_negotiated_protocol_capabilities =
        capability_intersection_from_member_proofs(&member_capability_proofs)?;
    let capability_extension = SecureMeshMlsCapabilityExtension::Active {
        schema_version: MLS_CAPABILITY_EXTENSION_SCHEMA_VERSION,
        activated_at_epoch: group.epoch().saturating_add(1),
        previous_extension_digest,
        committer_endpoint_id: owner_identity.endpoint_id.clone(),
        roster_transition: SecureMeshMlsRosterTransition::MemberAdded {
            member_endpoint_id: member_identity.endpoint_id.clone(),
            pair_binding,
        },
        member_capability_proofs,
        group_negotiated_protocol_capabilities,
    };
    verify_active_mls_capability_extension(
        &capability_extension,
        owner_identity,
        member_identity,
        now,
    )?;
    let group_id_hash = hex_sha256(&group.group_id_bytes()?);
    let (committer_proof, added_member_proof) =
        active_pair_capability_proofs(&capability_extension)?;
    let prepared_security = prepare_member_add_security_inputs(
        owner_identity,
        key_package_id,
        member_key_package.as_public_bytes(),
        &group_id_hash,
        committer_proof,
        added_member_proof,
        now.unix_timestamp(),
    )?;
    let welcome = group.add_member_with_capability_extension(
        owner,
        member_key_package,
        &capability_extension,
    )?;
    Ok((welcome, prepared_security))
}

pub(crate) fn remove_product_member_prepared(
    group: &mut SecureMeshMlsGroup,
    remover: &SecureMeshMlsParticipant,
    remover_identity: &DeviceTrustPublicIdentity,
    remover_trust_state: &DeviceTrustState,
    removed_member_identity: &DeviceTrustPublicIdentity,
    removed_member_trust_state: &DeviceTrustState,
    now: OffsetDateTime,
) -> Result<(SecureMeshMlsCommit, PreparedMlsSecurityInputs)> {
    require_verified_member_trust(remover_trust_state)?;
    ensure!(
        matches!(
            removed_member_trust_state,
            DeviceTrustState::Verified | DeviceTrustState::CrossSigned | DeviceTrustState::Revoked
        ),
        "secure mesh MLS removed member identity is not locally verified"
    );
    ensure!(
        participant_identity_matches(remover, remover_identity)?,
        "secure mesh MLS remover credential is not identity-bound"
    );
    ensure!(
        remover_identity.endpoint_id != removed_member_identity.endpoint_id,
        "secure mesh MLS member-remove action cannot remove the local identity"
    );
    ensure!(
        group.member_count() > 1,
        "secure mesh MLS member-remove action cannot empty the group"
    );

    let current_roster = directory_roster_from_group(group)?;
    ensure!(
        current_roster.get(&remover_identity.endpoint_id) == Some(remover_identity),
        "secure mesh MLS remover is not the exact current roster identity"
    );
    ensure!(
        current_roster.get(&removed_member_identity.endpoint_id) == Some(removed_member_identity),
        "secure mesh MLS removed member is not the exact current roster identity"
    );
    let current_roster_endpoint_ids = current_roster.keys().cloned().collect::<BTreeSet<_>>();
    let current_extension = group.capability_extension()?;
    verify_complete_member_capability_proof_map(
        &current_extension,
        &current_roster_endpoint_ids,
        &current_roster,
    )?;
    let SecureMeshMlsCapabilityExtension::Active {
        member_capability_proofs,
        ..
    } = &current_extension
    else {
        return Err(anyhow!(
            "secure mesh MLS member capability negotiation is incomplete"
        ));
    };

    let removed_leaf_index = group.member_leaf_index_for_identity(
        &mls_credential_identity_bytes(removed_member_identity)?,
        &removed_member_identity.signing_public_key,
    )?;
    ensure!(
        removed_leaf_index != group.own_leaf_index(),
        "secure mesh MLS member-remove action resolved the local leaf"
    );
    let mut next_member_capability_proofs = member_capability_proofs.clone();
    let removed_proof = next_member_capability_proofs
        .remove(&removed_member_identity.endpoint_id)
        .ok_or_else(|| anyhow!("secure mesh MLS removed member capability proof is missing"))?;
    ensure!(
        removed_proof.endpoint_id == removed_member_identity.endpoint_id,
        "secure mesh MLS removed member capability proof binding is invalid"
    );
    let mut next_roster = current_roster;
    ensure!(
        next_roster
            .remove(&removed_member_identity.endpoint_id)
            .is_some(),
        "secure mesh MLS removed member disappeared from the current roster"
    );
    let next_group_capabilities =
        capability_intersection_from_member_proofs(&next_member_capability_proofs)?;
    let next_extension = SecureMeshMlsCapabilityExtension::Active {
        schema_version: MLS_CAPABILITY_EXTENSION_SCHEMA_VERSION,
        activated_at_epoch: group.epoch().saturating_add(1),
        previous_extension_digest: Some(secure_mesh_mls_capability_extension_digest(
            &current_extension,
        )?),
        committer_endpoint_id: remover_identity.endpoint_id.clone(),
        roster_transition: SecureMeshMlsRosterTransition::MemberRemoved {
            member_endpoint_id: removed_member_identity.endpoint_id.clone(),
        },
        member_capability_proofs: next_member_capability_proofs,
        group_negotiated_protocol_capabilities: next_group_capabilities,
    };
    verify_complete_member_capability_proof_map(
        &next_extension,
        &next_roster.keys().cloned().collect(),
        &next_roster,
    )?;
    let commit = group.remove_member_with_capability_extension(
        remover,
        removed_leaf_index,
        &next_extension,
    )?;
    ensure!(
        directory_roster_from_group(group)? == next_roster,
        "secure mesh MLS committed remove roster differs from the verified next roster"
    );
    Ok((
        commit,
        empty_prepared_security_inputs(remover_identity, now.unix_timestamp())?,
    ))
}

pub(crate) fn join_product_group_from_welcome_prepared(
    participant: &SecureMeshMlsParticipant,
    participant_identity: &DeviceTrustPublicIdentity,
    invitation: &SecureMeshMlsExpectedInvitation,
    inviter_identity: &DeviceTrustPublicIdentity,
    inviter_trust_state: &DeviceTrustState,
    trusted_roster: &BTreeMap<String, DeviceTrustPublicIdentity>,
    welcome: &SecureMeshMlsWelcome,
    now: OffsetDateTime,
) -> Result<(SecureMeshMlsGroup, PreparedMlsSecurityInputs)> {
    ensure!(
        participant_identity_matches(participant, participant_identity)?,
        "secure mesh MLS joiner credential is not identity-bound"
    );
    require_verified_member_trust(inviter_trust_state)?;
    ensure!(
        inviter_identity.endpoint_id == invitation.inviter_endpoint_id,
        "secure mesh MLS inviter identity does not match invitation"
    );
    let group = SecureMeshMlsGroup::join_from_welcome_with_capability_verifier(
        participant,
        &welcome.welcome_message,
        |extension| {
            verify_complete_member_capability_proof_map(
                extension,
                &invitation.expected_roster_endpoint_ids,
                trusted_roster,
            )?;
            verify_active_mls_capability_extension(
                extension,
                inviter_identity,
                participant_identity,
                now,
            )?;
            Ok(())
        },
    )?;
    authorize_welcome_acceptance(invitation, inviter_trust_state, &group.group_id_bytes()?)?;
    cross_check_roster(
        &invitation.expected_roster_endpoint_ids,
        &group.member_credential_identities()?,
        trusted_roster,
    )?;
    let extension = group.capability_extension()?;
    let SecureMeshMlsCapabilityExtension::Active {
        activated_at_epoch,
        previous_extension_digest,
        ..
    } = &extension
    else {
        return Err(anyhow!(
            "secure mesh MLS joined capability extension is inactive"
        ));
    };
    ensure!(
        *activated_at_epoch <= group.epoch(),
        "secure mesh MLS capability extension epoch is from the future"
    );
    if invitation.expected_roster_endpoint_ids.len() == 2 {
        ensure!(
            previous_extension_digest.is_none(),
            "secure mesh MLS initial capability extension has unexpected history"
        );
    }
    let (committer_proof, added_member_proof) = active_pair_capability_proofs(&extension)?;
    let prepared_security = prepare_capability_security_inputs(
        participant_identity,
        committer_proof,
        added_member_proof,
        now.unix_timestamp(),
    )?;
    Ok((group, prepared_security))
}

pub(crate) fn process_product_commit_prepared(
    group: &mut SecureMeshMlsGroup,
    participant: &SecureMeshMlsParticipant,
    observing_identity: &DeviceTrustPublicIdentity,
    committer_identity: &DeviceTrustPublicIdentity,
    committer_trust_state: &DeviceTrustState,
    added_member_identity: Option<&DeviceTrustPublicIdentity>,
    removed_member_identity: Option<&DeviceTrustPublicIdentity>,
    trusted_roster: &BTreeMap<String, DeviceTrustPublicIdentity>,
    commit_message: &[u8],
    now: OffsetDateTime,
) -> Result<PreparedMlsSecurityInputs> {
    require_verified_member_trust(committer_trust_state)?;
    ensure!(
        participant_identity_matches(participant, observing_identity)?,
        "secure mesh MLS observing participant credential is not identity-bound"
    );
    ensure!(
        added_member_identity.is_none() || removed_member_identity.is_none(),
        "secure mesh MLS commit cannot add and remove a member in one product transition"
    );
    let current_roster = directory_roster_from_group(group)?;
    let roster = current_roster.keys().cloned().collect::<BTreeSet<_>>();
    ensure!(
        current_roster.get(&observing_identity.endpoint_id) == Some(observing_identity),
        "secure mesh MLS observing identity is not the exact current roster member"
    );
    authorize_commit_sender(
        &committer_identity.endpoint_id,
        committer_trust_state,
        &roster,
    )?;
    ensure!(
        current_roster.get(&committer_identity.endpoint_id) == Some(committer_identity),
        "secure mesh MLS committer identity differs from the current roster"
    );
    verify_complete_member_capability_proof_map(
        &group.capability_extension()?,
        &roster,
        &current_roster,
    )?;

    let mut expected_roster = current_roster.clone();
    if let Some(added_member_identity) = added_member_identity {
        ensure!(
            expected_roster
                .insert(
                    added_member_identity.endpoint_id.clone(),
                    added_member_identity.clone(),
                )
                .is_none(),
            "secure mesh MLS commit added member is already in the current roster"
        );
    }
    let expected_removed_leaf = if let Some(removed_member_identity) = removed_member_identity {
        ensure!(
            expected_roster.get(&removed_member_identity.endpoint_id)
                == Some(removed_member_identity),
            "secure mesh MLS removed member identity differs from the current roster"
        );
        let leaf = group.member_leaf_index_for_identity(
            &mls_credential_identity_bytes(removed_member_identity)?,
            &removed_member_identity.signing_public_key,
        )?;
        ensure!(
            expected_roster
                .remove(&removed_member_identity.endpoint_id)
                .is_some(),
            "secure mesh MLS removed member is absent from the current roster"
        );
        Some(leaf)
    } else {
        None
    };
    ensure!(
        &expected_roster == trusted_roster,
        "secure mesh MLS trusted roster does not equal the expected post-commit roster"
    );
    let expected_roster_endpoint_ids = expected_roster.keys().cloned().collect::<BTreeSet<_>>();
    let expected_next_epoch = group.epoch().saturating_add(1);
    let mut prepared_security = None;
    group.process_commit_with_capability_verifier(
        participant,
        commit_message,
        true,
        |credential_identity, signing_public_key, _leaf_index| {
            ensure!(
                credential_identity == mls_credential_identity_bytes(committer_identity)?
                    && signing_public_key == committer_identity.signing_public_key,
                "secure mesh MLS commit signer does not match trusted committer identity"
            );
            Ok(())
        },
        |current, staged, removed_leaf_indices, added_member_count| {
            verify_complete_member_capability_proof_map(
                staged,
                &expected_roster_endpoint_ids,
                trusted_roster,
            )?;
            if current == staged {
                ensure!(
                    added_member_identity.is_none()
                        && removed_member_identity.is_none()
                        && removed_leaf_indices.is_empty()
                        && added_member_count == 0,
                    "secure mesh MLS roster-changing commit did not authenticate a capability transition"
                );
                return Ok(());
            }
            let SecureMeshMlsCapabilityExtension::Active {
                activated_at_epoch,
                committer_endpoint_id,
                roster_transition,
                group_negotiated_protocol_capabilities: staged_group_capabilities,
                ..
            } = staged
            else {
                return Err(anyhow!(
                    "secure mesh MLS capability-changing commit is inactive"
                ));
            };
            ensure!(
                *activated_at_epoch == expected_next_epoch
                    && committer_endpoint_id == &committer_identity.endpoint_id,
                "secure mesh MLS roster transition epoch or committer binding is invalid"
            );
            match (added_member_identity, removed_member_identity) {
                (Some(added_member_identity), None) => {
                    ensure!(
                        added_member_count == 1 && removed_leaf_indices.is_empty(),
                        "secure mesh MLS member-add commit has an invalid roster delta"
                    );
                    let pair_capabilities = verify_active_mls_capability_extension(
                        staged,
                        committer_identity,
                        added_member_identity,
                        now,
                    )?;
                    let (committer_proof, added_member_proof) =
                        active_pair_capability_proofs(staged)?;
                    prepared_security = Some(prepare_capability_security_inputs(
                        observing_identity,
                        committer_proof,
                        added_member_proof,
                        now.unix_timestamp(),
                    )?);
                    let expected_group_capabilities = current
                        .group_negotiated_protocol_capabilities()
                        .map(|capabilities| {
                            capabilities
                                .intersection(&pair_capabilities)
                                .copied()
                                .collect::<BTreeSet<_>>()
                        })
                        .unwrap_or(pair_capabilities);
                    ensure!(
                        staged_group_capabilities == &expected_group_capabilities,
                        "secure mesh MLS cumulative capability intersection is invalid"
                    );
                }
                (None, Some(removed_member_identity)) => {
                    ensure!(
                        added_member_count == 0
                            && removed_leaf_indices == expected_removed_leaf.as_slice(),
                        "secure mesh MLS member-remove commit targets the wrong leaf"
                    );
                    ensure!(
                        matches!(
                            roster_transition,
                            SecureMeshMlsRosterTransition::MemberRemoved { member_endpoint_id }
                                if member_endpoint_id == &removed_member_identity.endpoint_id
                        ),
                        "secure mesh MLS member-remove capability transition targets the wrong endpoint"
                    );
                }
                (None, None) => {
                    return Err(anyhow!(
                        "secure mesh MLS capability-changing commit lacks a roster transition"
                    ));
                }
                (Some(_), Some(_)) => unreachable!(),
            }
            Ok(())
        },
    )?;
    cross_check_roster(
        &expected_roster_endpoint_ids,
        &group.member_credential_identities()?,
        trusted_roster,
    )?;
    prepared_security
        .map(Ok)
        .unwrap_or_else(|| empty_prepared_security_inputs(observing_identity, now.unix_timestamp()))
}

pub fn seal_product_payload_message(
    group: &mut SecureMeshMlsGroup,
    sender: &SecureMeshMlsParticipant,
    sender_identity: &DeviceTrustPublicIdentity,
    sender_trust_state: &DeviceTrustState,
    trusted_roster: &BTreeMap<String, DeviceTrustPublicIdentity>,
    context: &SecureMeshContentContext,
    plaintext: &SecureMeshPlaintext,
) -> Result<Vec<u8>> {
    let roster_endpoint_ids = trusted_roster.keys().cloned().collect::<BTreeSet<_>>();
    authorize_commit_sender(
        &sender_identity.endpoint_id,
        sender_trust_state,
        &roster_endpoint_ids,
    )?;
    verify_complete_member_capability_proof_map(
        &group.capability_extension()?,
        &roster_endpoint_ids,
        trusted_roster,
    )?;
    authorize_sender_endpoint_binding(&context.sender_endpoint_id, &sender_identity.endpoint_id)?;
    ensure!(
        participant_identity_matches(sender, sender_identity)?,
        "secure mesh MLS payload signer does not match trusted sender identity"
    );
    group.require_active_capability_negotiation()?;
    group.seal_payload_message(sender, context, plaintext)
}

pub fn open_product_payload_message(
    group: &mut SecureMeshMlsGroup,
    receiver: &SecureMeshMlsParticipant,
    receiver_identity: &DeviceTrustPublicIdentity,
    trusted_sender_identity: &DeviceTrustPublicIdentity,
    trusted_sender_state: &DeviceTrustState,
    trusted_roster: &BTreeMap<String, DeviceTrustPublicIdentity>,
    context: &SecureMeshContentContext,
    message: &[u8],
    expected_kind: SecureMeshPayloadKind,
) -> Result<OpenedSecureMeshPayload> {
    ensure!(
        participant_identity_matches(receiver, receiver_identity)?,
        "secure mesh MLS receiving participant credential is not identity-bound"
    );
    let roster_endpoint_ids = trusted_roster.keys().cloned().collect::<BTreeSet<_>>();
    authorize_commit_sender(
        &trusted_sender_identity.endpoint_id,
        trusted_sender_state,
        &roster_endpoint_ids,
    )?;
    verify_complete_member_capability_proof_map(
        &group.capability_extension()?,
        &roster_endpoint_ids,
        trusted_roster,
    )?;
    authorize_sender_endpoint_binding(
        &context.sender_endpoint_id,
        &trusted_sender_identity.endpoint_id,
    )?;
    group.require_active_capability_negotiation()?;
    group.open_payload_message_with_sender_verifier(
        receiver,
        context,
        message,
        expected_kind,
        |credential_identity, signing_public_key, _leaf_index| {
            ensure!(
                credential_identity == mls_credential_identity_bytes(trusted_sender_identity)?
                    && signing_public_key == trusted_sender_identity.signing_public_key,
                "secure mesh MLS payload signer does not match trusted sender identity"
            );
            Ok(())
        },
    )
}

fn participant_identity_matches(
    participant: &SecureMeshMlsParticipant,
    identity: &DeviceTrustPublicIdentity,
) -> Result<bool> {
    Ok(
        participant.credential_identity_bytes()? == mls_credential_identity_bytes(identity)?
            && participant.signing_public_key() == identity.signing_public_key,
    )
}

fn key_package_identity_matches(
    key_package: &SecureMeshMlsKeyPackage,
    identity: &DeviceTrustPublicIdentity,
) -> Result<bool> {
    Ok(
        key_package.credential_identity_bytes()? == mls_credential_identity_bytes(identity)?
            && key_package.signing_public_key() == identity.signing_public_key,
    )
}

fn endpoint_id_from_credential_identity(credential: &[u8]) -> Result<String> {
    ensure!(
        credential.starts_with(MLS_CREDENTIAL_MAGIC),
        "secure mesh MLS credential magic mismatch"
    );
    let mut offset = MLS_CREDENTIAL_MAGIC.len();
    let endpoint = read_len_prefixed(credential, &mut offset)?;
    Ok(String::from_utf8(endpoint)
        .map_err(|_| anyhow!("secure mesh MLS credential endpoint is not utf8"))?)
}

fn identity_validate(identity: &DeviceTrustPublicIdentity) -> Result<()> {
    ensure!(
        !identity.endpoint_id.trim().is_empty(),
        "secure mesh endpoint id is required"
    );
    Ok(())
}

fn append_len_prefixed(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len = u32::try_from(value.len()).map_err(|_| anyhow!("field too large"))?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

fn read_len_prefixed(bytes: &[u8], offset: &mut usize) -> Result<Vec<u8>> {
    ensure!(
        bytes.len() >= *offset + 4,
        "secure mesh MLS credential is truncated"
    );
    let len = u32::from_be_bytes(bytes[*offset..*offset + 4].try_into().unwrap()) as usize;
    *offset += 4;
    ensure!(
        bytes.len() >= *offset + len,
        "secure mesh MLS credential is truncated"
    );
    let value = bytes[*offset..*offset + len].to_vec();
    *offset += len;
    Ok(value)
}

fn hex_sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_crypto::{
        SecureMeshContentContext, SecureMeshPayloadKind, SecureMeshPlaintext,
    };
    use crate::core::secure_mesh_directory::{
        SecureMeshDirectoryAuthority, SecureMeshDirectoryKeyMaterialCommitment,
        SecureMeshDirectoryLeafClaim, UntrustedDirectoryResponse,
    };
    use crate::core::secure_mesh_transparency::{
        KtFreshnessPolicy, SecureMeshKtLog, SecureMeshTransparencyLeafBody,
        directory_scope_commitment,
    };
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct DeviceFixture {
        identity: DeviceTrustPublicIdentity,
        signing_key: SigningKey,
        participant: SecureMeshMlsParticipant,
    }

    fn device(endpoint_id: &str) -> DeviceFixture {
        let identity_key = SigningKey::generate(&mut OsRng);
        let signing_key = SigningKey::generate(&mut OsRng);
        let identity = DeviceTrustPublicIdentity::new(
            endpoint_id,
            identity_key.verifying_key().to_bytes(),
            signing_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        let participant = participant_from_device_identity(&identity, &signing_key).unwrap();
        DeviceFixture {
            identity,
            signing_key,
            participant,
        }
    }

    fn capability_evaluation() -> CapabilityEvaluation {
        let facts = crate::core::secure_mesh_capability::mandatory_protocol_facts(
            crate::core::secure_mesh_capability::CapabilityEvidenceKind::TestFixture,
        )
        .unwrap();
        capability_catalog().unwrap().evaluate(&facts).unwrap()
    }

    fn capability_now() -> OffsetDateTime {
        OffsetDateTime::from_unix_timestamp(1_900_000_000).unwrap()
    }

    fn authorized_member_add_directory(
        member: &DeviceFixture,
        member_key_package: &SecureMeshMlsKeyPackage,
        member_directory_version: u64,
        member_key_package_version: u64,
        issued_at: OffsetDateTime,
        purpose: DirectoryAuthorizationPurpose,
    ) -> AuthorizedDirectoryLeaf {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let claim = SecureMeshDirectoryLeafClaim {
            endpoint: SecureMeshTransparencyLeafBody {
                directory_scope_commitment: directory_scope_commitment(
                    "test-tenant",
                    "test-account",
                    "test-workspace",
                ),
                endpoint_id: member.identity.endpoint_id.clone(),
                endpoint_kind: "test".to_string(),
                identity_public_key: member
                    .identity
                    .identity_public_key
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect(),
                signing_public_key: member
                    .identity
                    .signing_public_key
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect(),
                fingerprint: member.identity.fingerprint().unwrap(),
                rotation_epoch: member.identity.rotation_epoch,
                directory_state: "active".to_string(),
                updated_at: "2026-07-12T00:00:00Z".to_string(),
            },
            key_material: SecureMeshDirectoryKeyMaterialCommitment {
                signed_prekey_bundle_digest: hex_sha256(b"test-signed-prekey-bundle"),
                one_time_prekey_batch_digest: hex_sha256(b"test-one-time-prekey-batch"),
                pairwise_prekey_version: 1,
                mls_key_package_digest: hex_sha256(member_key_package.as_public_bytes()),
                mls_key_package_version: member_key_package_version,
            },
            directory_version: member_directory_version,
        };
        let leaf_index = log
            .append_hashed_directory_leaf(
                &claim.stable_label(),
                claim.version(),
                claim.revoked(),
                claim.leaf_hash().unwrap(),
            )
            .unwrap();
        let issued_at = u64::try_from(issued_at.unix_timestamp()).unwrap();
        let response = UntrustedDirectoryResponse {
            claim: claim.clone(),
            inclusion: log.inclusion_proof_at(leaf_index, issued_at).unwrap(),
            latest_map: log.map_proof_at(&claim.stable_label(), issued_at).unwrap(),
            consistency: None,
        };
        let mut authority = SecureMeshDirectoryAuthority::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();
        authority.authorize(response, purpose, issued_at).unwrap()
    }

    fn begin_test_journal_operation(
        ledger: &mut SecureMeshMlsSecurityLedger,
        action: &str,
        request_binding: &[u8],
        identity: &DeviceTrustPublicIdentity,
        now: OffsetDateTime,
    ) -> Result<String> {
        let request_digest = hex_sha256(request_binding);
        let mut operation_binding = Vec::new();
        operation_binding.extend_from_slice(b"LICO-SM-MLS-TEST-OPERATION-v1");
        operation_binding.extend_from_slice(action.as_bytes());
        operation_binding.extend_from_slice(identity.fingerprint()?.as_bytes());
        operation_binding.extend_from_slice(request_digest.as_bytes());
        let operation_id = hex_sha256(&operation_binding);
        ledger.begin_operation(
            &operation_id,
            action,
            &request_digest,
            identity,
            now.unix_timestamp(),
        )?;
        Ok(operation_id)
    }

    #[allow(clippy::too_many_arguments)]
    fn stage_test_journal_operation(
        ledger: &mut SecureMeshMlsSecurityLedger,
        operation_id: &str,
        group_id: &[u8],
        base: Option<&SecureMeshMlsGroupMetadata>,
        expected: &SecureMeshMlsGroupMetadata,
        prepared: &PreparedMlsSecurityInputs,
        response: &Value,
        now: OffsetDateTime,
    ) -> Result<SecureMeshMlsOperationRecord> {
        match ledger.stage_operation(
            operation_id,
            response,
            group_id,
            base,
            expected,
            prepared,
            now.unix_timestamp(),
        ) {
            Ok(staged) => Ok(staged),
            Err(error) => {
                ledger.abort_empty_prepared_operation(operation_id)?;
                Err(error)
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn commit_test_journal_operation(
        ledger: &mut SecureMeshMlsSecurityLedger,
        operation_id: &str,
        group_id: &[u8],
        base: Option<&SecureMeshMlsGroupMetadata>,
        expected: &SecureMeshMlsGroupMetadata,
        prepared: &PreparedMlsSecurityInputs,
        response: &Value,
        now: OffsetDateTime,
    ) -> Result<()> {
        let staged = stage_test_journal_operation(
            ledger,
            operation_id,
            group_id,
            base,
            expected,
            prepared,
            response,
            now,
        )?;
        let committed =
            ledger.commit_operation_crypto(&staged.operation_id, expected, now.unix_timestamp())?;
        let reconciled = ledger.mark_operation_metadata_reconciled(
            &committed.operation_id,
            response,
            now.unix_timestamp(),
        )?;
        ledger.mark_operation_delivered(&reconciled.operation_id, now.unix_timestamp())?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn process_test_product_commit(
        group: &mut SecureMeshMlsGroup,
        participant: &SecureMeshMlsParticipant,
        observing_identity: &DeviceTrustPublicIdentity,
        committer_identity: &DeviceTrustPublicIdentity,
        committer_trust_state: &DeviceTrustState,
        added_member_identity: Option<&DeviceTrustPublicIdentity>,
        removed_member_identity: Option<&DeviceTrustPublicIdentity>,
        trusted_roster: &BTreeMap<String, DeviceTrustPublicIdentity>,
        commit_message: &[u8],
        ledger: &mut SecureMeshMlsSecurityLedger,
        now: OffsetDateTime,
    ) -> Result<()> {
        let group_id = group.group_id_bytes()?;
        let base = group.public_metadata(observing_identity.fingerprint()?)?;
        let mut request_binding = Vec::new();
        request_binding.extend_from_slice(commit_message);
        request_binding.extend_from_slice(base.public_state_digest.as_bytes());
        request_binding.extend_from_slice(committer_identity.endpoint_id.as_bytes());
        let operation_id = begin_test_journal_operation(
            ledger,
            "secure_mesh.mls.commit.process",
            &request_binding,
            observing_identity,
            now,
        )?;
        let prepared = match process_product_commit_prepared(
            group,
            participant,
            observing_identity,
            committer_identity,
            committer_trust_state,
            added_member_identity,
            removed_member_identity,
            trusted_roster,
            commit_message,
            now,
        ) {
            Ok(prepared) => prepared,
            Err(error) => {
                ledger.abort_empty_prepared_operation(&operation_id)?;
                return Err(error);
            }
        };
        let expected = group.public_metadata(observing_identity.fingerprint()?)?;
        commit_test_journal_operation(
            ledger,
            &operation_id,
            &group_id,
            Some(&base),
            &expected,
            &prepared,
            &serde_json::json!({"ok": true}),
            now,
        )
    }

    #[test]
    fn secure_mesh_mls_wire_profile_ignores_app_version_and_rejects_revision_mismatch() {
        let simulated_app_versions = ["0.0.1-alpha", "0.0.2", "27.4.9"];
        let digests = simulated_app_versions
            .iter()
            .map(|_| secure_mesh_mls_build_protocol_digest().unwrap())
            .collect::<Vec<_>>();
        assert!(digests.windows(2).all(|pair| pair[0] == pair[1]));

        let device = device("mobile:mls-wire-profile-revision");
        let now = capability_now();
        for incompatible_revision in [
            SECURE_MESH_PROTOCOL_BUILD_REVISION - 1,
            SECURE_MESH_PROTOCOL_BUILD_REVISION + 1,
        ] {
            let incompatible_digest =
                secure_mesh_mls_build_protocol_digest_for_revision(incompatible_revision).unwrap();
            assert_ne!(digests[0], incompatible_digest);
            let request = CapabilityProofRequest {
                build_protocol_digest: incompatible_digest,
                policy_revision: SECURE_MESH_MLS_CAPABILITY_POLICY_REVISION,
                challenge: [0x7e; 32],
                issued_at_unix_seconds: now.unix_timestamp() - 1,
                expires_at_unix_seconds: now.unix_timestamp() + 60,
            };
            let proof = sign_capability_proof(
                &device.identity,
                &device.signing_key,
                &capability_evaluation(),
                &request,
            )
            .unwrap();
            let error = crate::core::secure_mesh_capability_proof::verify_capability_proof(
                &device.identity,
                &proof,
                &mls_capability_verification_context(request.challenge, now).unwrap(),
            )
            .unwrap_err();
            assert!(error.to_string().contains("build protocol binding"));
        }
    }

    fn add_test_product_member(
        group: &mut SecureMeshMlsGroup,
        owner: &DeviceFixture,
        member: &DeviceFixture,
        member_key_package: &SecureMeshMlsKeyPackage,
        ledger: &mut SecureMeshMlsSecurityLedger,
        key_package_id: &str,
    ) -> SecureMeshMlsWelcome {
        add_test_product_member_with_times(
            group,
            owner,
            member,
            member_key_package,
            ledger,
            key_package_id,
            capability_now(),
            capability_now(),
        )
        .unwrap()
    }

    fn add_test_product_member_with_times(
        group: &mut SecureMeshMlsGroup,
        owner: &DeviceFixture,
        member: &DeviceFixture,
        member_key_package: &SecureMeshMlsKeyPackage,
        ledger: &mut SecureMeshMlsSecurityLedger,
        key_package_id: &str,
        member_proof_issued_at: OffsetDateTime,
        accepted_at: OffsetDateTime,
    ) -> Result<SecureMeshMlsWelcome> {
        let member_proof = sign_mls_keypackage_capability_proof(
            &member.identity,
            &member.signing_key,
            &capability_evaluation(),
            member_key_package,
            member_proof_issued_at,
        )
        .unwrap();
        let group_id = group.group_id_bytes()?;
        let base = group.public_metadata(owner.identity.fingerprint()?)?;
        let mut request_binding = Vec::new();
        request_binding.extend_from_slice(key_package_id.as_bytes());
        request_binding.extend_from_slice(member_key_package.as_public_bytes());
        request_binding.extend_from_slice(base.public_state_digest.as_bytes());
        let operation_id = begin_test_journal_operation(
            ledger,
            "secure_mesh.mls.member.add",
            &request_binding,
            &owner.identity,
            accepted_at,
        )?;
        let member_directory_version = 1;
        let member_key_package_version = 1;
        let member_directory_authorization = authorized_member_add_directory(
            member,
            member_key_package,
            member_directory_version,
            member_key_package_version,
            accepted_at,
            DirectoryAuthorizationPurpose::MlsMemberAdd,
        );
        let (welcome, prepared) = match add_product_member_prepared(
            group,
            &owner.participant,
            &owner.identity,
            &owner.signing_key,
            &capability_evaluation(),
            &DeviceTrustState::Verified,
            member_key_package,
            &member.identity,
            &member_proof,
            &DeviceTrustState::Verified,
            &member_directory_authorization,
            member_directory_version,
            member_key_package_version,
            key_package_id,
            accepted_at,
        ) {
            Ok(result) => result,
            Err(error) => {
                ledger.abort_empty_prepared_operation(&operation_id)?;
                return Err(error);
            }
        };
        let expected = group.public_metadata(owner.identity.fingerprint()?)?;
        commit_test_journal_operation(
            ledger,
            &operation_id,
            &group_id,
            Some(&base),
            &expected,
            &prepared,
            &serde_json::json!({"ok": true, "group": null}),
            accepted_at,
        )?;
        Ok(welcome)
    }

    fn join_test_product_group(
        member: &DeviceFixture,
        inviter: &DeviceFixture,
        invitation: &SecureMeshMlsExpectedInvitation,
        welcome: &SecureMeshMlsWelcome,
        ledger: &mut SecureMeshMlsSecurityLedger,
    ) -> Result<SecureMeshMlsGroup> {
        let trusted_roster = BTreeMap::from([
            (
                inviter.identity.endpoint_id.clone(),
                inviter.identity.clone(),
            ),
            (member.identity.endpoint_id.clone(), member.identity.clone()),
        ]);
        join_test_product_group_with_roster(
            member,
            inviter,
            invitation,
            welcome,
            &trusted_roster,
            ledger,
        )
    }

    fn join_test_product_group_with_roster(
        member: &DeviceFixture,
        inviter: &DeviceFixture,
        invitation: &SecureMeshMlsExpectedInvitation,
        welcome: &SecureMeshMlsWelcome,
        trusted_roster: &BTreeMap<String, DeviceTrustPublicIdentity>,
        ledger: &mut SecureMeshMlsSecurityLedger,
    ) -> Result<SecureMeshMlsGroup> {
        let mut request_binding = Vec::new();
        request_binding.extend_from_slice(&welcome.welcome_message);
        request_binding.extend_from_slice(&invitation.group_id);
        let operation_id = begin_test_journal_operation(
            ledger,
            "secure_mesh.mls.group.join",
            &request_binding,
            &member.identity,
            capability_now(),
        )?;
        let (group, prepared) = match join_product_group_from_welcome_prepared(
            &member.participant,
            &member.identity,
            invitation,
            &inviter.identity,
            &DeviceTrustState::Verified,
            trusted_roster,
            welcome,
            capability_now(),
        ) {
            Ok(result) => result,
            Err(error) => {
                ledger.abort_empty_prepared_operation(&operation_id)?;
                return Err(error);
            }
        };
        let expected = group.public_metadata(member.identity.fingerprint()?)?;
        commit_test_journal_operation(
            ledger,
            &operation_id,
            &invitation.group_id,
            None,
            &expected,
            &prepared,
            &serde_json::json!({"ok": true}),
            capability_now(),
        )?;
        Ok(group)
    }

    fn ledger_path(name: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let mut path = std::env::temp_dir();
        path.push(format!(
            "lico-mls-kp-{name}-{}-{nonce}.sqlite3",
            std::process::id()
        ));
        path
    }

    fn journal_metadata(
        group_id: &[u8],
        participant_endpoint_id: &str,
        epoch: u64,
        state_label: &str,
    ) -> SecureMeshMlsGroupMetadata {
        SecureMeshMlsGroupMetadata {
            group_id_hash: format!("sha256:{}", hex_sha256(group_id)),
            public_state_digest: format!("sha256:{}", hex_sha256(state_label.as_bytes())),
            epoch,
            member_count: usize::try_from(epoch).unwrap_or(1).max(1),
            own_leaf_index: 0,
            active: true,
            participant_endpoint_id: participant_endpoint_id.to_string(),
        }
    }

    #[test]
    fn secure_mesh_mls_journal_recovers_every_action_at_every_cross_store_boundary() {
        let local = device("desktop_gui:journal-recovery-local");
        let participant_scope = local.identity.fingerprint().unwrap();
        let actions = [
            "secure_mesh.mls.member.add",
            "secure_mesh.mls.member.remove",
            "secure_mesh.mls.group.join",
            "secure_mesh.mls.commit.process",
        ];
        let boundaries = [
            "after_stage_before_snapshot",
            "after_snapshot_before_crypto_commit",
            "after_crypto_commit_before_metadata",
            "after_metadata_before_delivery",
        ];

        for action in actions {
            for boundary in boundaries {
                let path = ledger_path(&format!("journal-{action}-{boundary}"));
                let group_id = format!("group-{action}-{boundary}").into_bytes();
                let base = (action != "secure_mesh.mls.group.join")
                    .then(|| journal_metadata(&group_id, &participant_scope, 1, "base"));
                let expected = journal_metadata(&group_id, &participant_scope, 2, "expected");
                let operation_id = hex_sha256(format!("{action}:{boundary}:operation").as_bytes());
                let request_digest = hex_sha256(format!("{action}:{boundary}:request").as_bytes());
                let now = capability_now().unix_timestamp();
                let prepared = empty_prepared_security_inputs(&local.identity, now).unwrap();
                let response = serde_json::json!({"ok": true, "action": action});

                let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
                ledger
                    .begin_operation(&operation_id, action, &request_digest, &local.identity, now)
                    .unwrap();
                ledger
                    .stage_operation(
                        &operation_id,
                        &serde_json::json!({}),
                        &group_id,
                        base.as_ref(),
                        &expected,
                        &prepared,
                        now,
                    )
                    .unwrap();

                match boundary {
                    "after_stage_before_snapshot" => {}
                    "after_snapshot_before_crypto_commit" => {}
                    "after_crypto_commit_before_metadata" => {
                        ledger
                            .commit_operation_crypto(&operation_id, &expected, now + 1)
                            .unwrap();
                    }
                    "after_metadata_before_delivery" => {
                        ledger
                            .commit_operation_crypto(&operation_id, &expected, now + 1)
                            .unwrap();
                        ledger
                            .mark_operation_metadata_reconciled(&operation_id, &response, now + 2)
                            .unwrap();
                    }
                    _ => unreachable!(),
                }
                drop(ledger);

                let mut recovered = SecureMeshMlsSecurityLedger::open(&path).unwrap();
                let record = recovered.operation(&operation_id).unwrap().unwrap();
                match boundary {
                    "after_stage_before_snapshot" => {
                        assert_eq!(record.state, SecureMeshMlsOperationState::CryptoPrepared);
                        assert_eq!(record.base_metadata, base);
                        recovered
                            .reset_crypto_prepared_operation_for_retry(&operation_id, now + 3)
                            .unwrap();
                        assert!(
                            recovered
                                .abort_empty_prepared_operation(&operation_id)
                                .unwrap()
                        );
                        assert!(recovered.operation(&operation_id).unwrap().is_none());

                        let next_operation_id =
                            hex_sha256(format!("{action}:{boundary}:next").as_bytes());
                        recovered
                            .begin_operation(
                                &next_operation_id,
                                action,
                                &hex_sha256(b"different-request-after-abandon"),
                                &local.identity,
                                now + 4,
                            )
                            .unwrap();
                        assert!(
                            recovered
                                .abort_empty_prepared_operation(&next_operation_id)
                                .unwrap()
                        );
                    }
                    "after_snapshot_before_crypto_commit" => {
                        assert_eq!(record.state, SecureMeshMlsOperationState::CryptoPrepared);
                        recovered
                            .commit_operation_crypto(&operation_id, &expected, now + 3)
                            .unwrap();
                        recovered
                            .mark_operation_metadata_reconciled(&operation_id, &response, now + 4)
                            .unwrap();
                        recovered
                            .mark_operation_delivered(&operation_id, now + 5)
                            .unwrap();
                    }
                    "after_crypto_commit_before_metadata" => {
                        assert_eq!(record.state, SecureMeshMlsOperationState::CryptoCommitted);
                        recovered
                            .mark_operation_metadata_reconciled(&operation_id, &response, now + 3)
                            .unwrap();
                        recovered
                            .mark_operation_delivered(&operation_id, now + 4)
                            .unwrap();
                    }
                    "after_metadata_before_delivery" => {
                        assert_eq!(
                            record.state,
                            SecureMeshMlsOperationState::MetadataReconciled
                        );
                        assert_eq!(record.response.as_ref(), Some(&response));
                        recovered
                            .mark_operation_delivered(&operation_id, now + 3)
                            .unwrap();
                    }
                    _ => unreachable!(),
                }
                if boundary != "after_stage_before_snapshot" {
                    assert_eq!(
                        recovered.operation(&operation_id).unwrap().unwrap().state,
                        SecureMeshMlsOperationState::Delivered
                    );
                }
                assert!(
                    recovered
                        .incomplete_writer_operations(&local.identity)
                        .unwrap()
                        .is_empty()
                );
                let foreign_key_errors: i64 = recovered
                    .connection
                    .query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
                        row.get(0)
                    })
                    .unwrap();
                assert_eq!(foreign_key_errors, 0);
                let _ = std::fs::remove_file(path);
            }
        }
    }

    #[test]
    fn secure_mesh_mls_invalid_prepared_requests_do_not_consume_journal_capacity() {
        let local = device("mobile:journal-invalid-local");
        let path = ledger_path("invalid-prepared-capacity");
        let now = capability_now().unix_timestamp();
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();

        for index in 0..(MAX_INCOMPLETE_MLS_OPERATIONS_PER_SCOPE * 2) {
            let operation_id = hex_sha256(format!("invalid-operation-{index}").as_bytes());
            ledger
                .begin_operation(
                    &operation_id,
                    "secure_mesh.mls.commit.process",
                    &hex_sha256(format!("invalid-request-{index}").as_bytes()),
                    &local.identity,
                    now,
                )
                .unwrap();
            assert!(
                ledger
                    .abort_empty_prepared_operation(&operation_id)
                    .unwrap()
            );
        }

        let valid_operation = hex_sha256(b"valid-operation-after-invalid-inputs");
        ledger
            .begin_operation(
                &valid_operation,
                "secure_mesh.mls.commit.process",
                &hex_sha256(b"valid-request-after-invalid-inputs"),
                &local.identity,
                now + 1,
            )
            .unwrap();
        assert!(
            ledger
                .abort_empty_prepared_operation(&valid_operation)
                .unwrap()
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_mls_journal_enforces_single_writer_exact_state_and_bounded_gc() {
        let local = device("desktop_gui:journal-invariants-local");
        let participant_scope = local.identity.fingerprint().unwrap();
        let path = ledger_path("journal-invariants");
        let now = capability_now().unix_timestamp();
        let prepared = empty_prepared_security_inputs(&local.identity, now).unwrap();
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();

        let first_group = b"journal-writer-first";
        let first_base = journal_metadata(first_group, &participant_scope, 1, "first-base");
        let first_expected = journal_metadata(first_group, &participant_scope, 2, "first-expected");
        let first_operation = hex_sha256(b"journal-writer-first-operation");
        ledger
            .begin_operation(
                &first_operation,
                "secure_mesh.mls.member.add",
                &hex_sha256(b"journal-writer-first-request"),
                &local.identity,
                now,
            )
            .unwrap();
        ledger
            .stage_operation(
                &first_operation,
                &serde_json::json!({"ok": true, "group": null}),
                first_group,
                Some(&first_base),
                &first_expected,
                &prepared,
                now,
            )
            .unwrap();

        let second_group = b"journal-writer-second";
        let second_base = journal_metadata(second_group, &participant_scope, 4, "second-base");
        let second_expected =
            journal_metadata(second_group, &participant_scope, 5, "second-expected");
        let second_operation = hex_sha256(b"journal-writer-second-operation");
        ledger
            .begin_operation(
                &second_operation,
                "secure_mesh.mls.commit.process",
                &hex_sha256(b"journal-writer-second-request"),
                &local.identity,
                now,
            )
            .unwrap();
        let writer_error = ledger
            .stage_operation(
                &second_operation,
                &serde_json::json!({}),
                second_group,
                Some(&second_base),
                &second_expected,
                &prepared,
                now,
            )
            .unwrap_err();
        assert!(writer_error.to_string().contains("another writer"));

        let mut same_epoch_divergence = first_expected.clone();
        same_epoch_divergence.public_state_digest = format!(
            "sha256:{}",
            hex_sha256(b"same-epoch-divergent-public-state")
        );
        let divergence_error = ledger
            .commit_operation_crypto(&first_operation, &same_epoch_divergence, now + 1)
            .unwrap_err();
        assert!(divergence_error.to_string().contains("does not match"));
        ledger
            .commit_operation_crypto(&first_operation, &first_expected, now + 1)
            .unwrap();
        let first_response = serde_json::json!({"ok": true, "group": {"epoch": 2}});
        ledger
            .mark_operation_metadata_reconciled(&first_operation, &first_response, now + 2)
            .unwrap();
        ledger
            .mark_operation_metadata_reconciled(&first_operation, &first_response, now + 2)
            .unwrap();
        let response_divergence = ledger
            .mark_operation_metadata_reconciled(
                &first_operation,
                &serde_json::json!({"ok": false}),
                now + 2,
            )
            .unwrap_err();
        assert!(
            response_divergence
                .to_string()
                .contains("response diverges")
        );
        ledger
            .mark_operation_delivered(&first_operation, now + 3)
            .unwrap();

        ledger
            .stage_operation(
                &second_operation,
                &serde_json::json!({}),
                second_group,
                Some(&second_base),
                &second_expected,
                &prepared,
                now + 4,
            )
            .unwrap();
        ledger
            .commit_operation_crypto(&second_operation, &second_expected, now + 5)
            .unwrap();
        ledger
            .mark_operation_metadata_reconciled(
                &second_operation,
                &serde_json::json!({"ok": true}),
                now + 6,
            )
            .unwrap();
        ledger
            .mark_operation_delivered(&second_operation, now + 7)
            .unwrap();

        let bound_operation = hex_sha256(b"journal-group-binding-operation");
        ledger
            .begin_operation(
                &bound_operation,
                "secure_mesh.mls.group.join",
                &hex_sha256(b"journal-group-binding-request"),
                &local.identity,
                now + 8,
            )
            .unwrap();
        let group_binding_error = ledger
            .stage_operation(
                &bound_operation,
                &serde_json::json!({}),
                b"wrong-group-id",
                None,
                &second_expected,
                &prepared,
                now + 8,
            )
            .unwrap_err();
        assert!(group_binding_error.to_string().contains("group id"));
        assert!(
            ledger
                .abort_empty_prepared_operation(&bound_operation)
                .unwrap()
        );

        let cascading_operation = hex_sha256(b"journal-cascade-operation");
        ledger
            .begin_operation(
                &cascading_operation,
                "secure_mesh.mls.commit.process",
                &hex_sha256(b"journal-cascade-request"),
                &local.identity,
                now + 9,
            )
            .unwrap();
        ledger
            .stage_operation(
                &cascading_operation,
                &serde_json::json!({}),
                second_group,
                Some(&second_base),
                &second_expected,
                &prepared,
                now + 9,
            )
            .unwrap();
        ledger
            .connection
            .execute(
                "DELETE FROM secure_mesh_mls_operations WHERE operation_id = ?1",
                params![cascading_operation],
            )
            .unwrap();
        let dangling_reservations: i64 = ledger
            .connection
            .query_row(
                "SELECT COUNT(*) FROM secure_mesh_mls_operation_reservations WHERE operation_id = ?1",
                params![cascading_operation],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(dangling_reservations, 0);
        let foreign_key_errors: i64 = ledger
            .connection
            .query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(foreign_key_errors, 0);

        let protected_prepared = hex_sha256(b"journal-gc-protected-prepared");
        ledger
            .begin_operation(
                &protected_prepared,
                "secure_mesh.mls.commit.process",
                &hex_sha256(b"journal-gc-protected-request"),
                &local.identity,
                now + 10,
            )
            .unwrap();
        let local_scope = mls_security_scope_hash(&local.identity).unwrap();
        {
            let tx = ledger.connection.transaction().unwrap();
            for index in 0..(MAX_DELIVERED_MLS_OPERATIONS_PER_SCOPE + 64) {
                tx.execute(
                    r#"
                    INSERT INTO secure_mesh_mls_operations (
                        operation_id, local_endpoint_scope_hash, action, request_digest, state,
                        response_json, group_id_base64url, base_metadata_json,
                        expected_metadata_json, prepared_security_json,
                        created_at_unix_seconds, updated_at_unix_seconds
                    ) VALUES (?1, ?2, 'secure_mesh.mls.commit.process', ?3, 'delivered',
                              '{}', NULL, NULL, NULL, NULL, ?4, ?4)
                    "#,
                    params![
                        hex_sha256(format!("gc-delivered-{index}").as_bytes()),
                        local_scope,
                        hex_sha256(format!("gc-request-{index}").as_bytes()),
                        now + i64::try_from(index).unwrap(),
                    ],
                )
                .unwrap();
            }
            tx.commit().unwrap();
        }
        let gc_trigger = hex_sha256(b"journal-gc-trigger");
        ledger
            .begin_operation(
                &gc_trigger,
                "secure_mesh.mls.commit.process",
                &hex_sha256(b"journal-gc-trigger-request"),
                &local.identity,
                now + 1000,
            )
            .unwrap();
        let delivered_count: i64 = ledger
            .connection
            .query_row(
                "SELECT COUNT(*) FROM secure_mesh_mls_operations WHERE local_endpoint_scope_hash = ?1 AND state = 'delivered'",
                params![local_scope],
                |row| row.get(0),
            )
            .unwrap();
        assert!(delivered_count <= i64::try_from(MAX_DELIVERED_MLS_OPERATIONS_PER_SCOPE).unwrap());
        assert!(ledger.operation(&protected_prepared).unwrap().is_some());
        assert!(
            ledger
                .abort_empty_prepared_operation(&protected_prepared)
                .unwrap()
        );
        assert!(ledger.abort_empty_prepared_operation(&gc_trigger).unwrap());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_mls_journal_and_replay_ledgers_fail_closed_at_capacity() {
        let local = device("mobile:journal-capacity-local");
        let participant_scope = local.identity.fingerprint().unwrap();
        let path = ledger_path("journal-capacity");
        let now = capability_now().unix_timestamp();
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        let mut prepared_operations = Vec::new();

        for index in 0..MAX_INCOMPLETE_MLS_OPERATIONS_PER_SCOPE {
            let operation_id = hex_sha256(format!("capacity-operation-{index}").as_bytes());
            ledger
                .begin_operation(
                    &operation_id,
                    "secure_mesh.mls.commit.process",
                    &hex_sha256(format!("capacity-request-{index}").as_bytes()),
                    &local.identity,
                    now,
                )
                .unwrap();
            prepared_operations.push(operation_id);
        }
        let overflow = hex_sha256(b"capacity-overflow-operation");
        let capacity_error = ledger
            .begin_operation(
                &overflow,
                "secure_mesh.mls.commit.process",
                &hex_sha256(b"capacity-overflow-request"),
                &local.identity,
                now,
            )
            .unwrap_err();
        assert!(capacity_error.to_string().contains("at capacity"));
        assert!(
            ledger
                .abort_empty_prepared_operation(&prepared_operations[0])
                .unwrap()
        );
        ledger
            .begin_operation(
                &overflow,
                "secure_mesh.mls.commit.process",
                &hex_sha256(b"capacity-overflow-request"),
                &local.identity,
                now + 1,
            )
            .unwrap();
        for operation_id in prepared_operations.iter().skip(1) {
            assert!(ledger.abort_empty_prepared_operation(operation_id).unwrap());
        }
        assert!(ledger.abort_empty_prepared_operation(&overflow).unwrap());

        let local_scope = mls_security_scope_hash(&local.identity).unwrap();
        {
            let tx = ledger.connection.transaction().unwrap();
            for index in 0..MAX_PERSISTED_MLS_KEY_PACKAGES_PER_SCOPE {
                tx.execute(
                    r#"
                    INSERT INTO secure_mesh_mls_keypackage_uses (
                        consumer_endpoint_id, key_package_id, key_package_public_key_hash,
                        group_id_hash, used_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5)
                    "#,
                    params![
                        local_scope,
                        hex_sha256(format!("keypackage-id-{index}").as_bytes()),
                        hex_sha256(format!("keypackage-public-{index}").as_bytes()),
                        format!("sha256:{}", hex_sha256(b"capacity-group")),
                        now.to_string(),
                    ],
                )
                .unwrap();
            }
            tx.commit().unwrap();
        }
        let capacity_group = b"capacity-group";
        let base = journal_metadata(capacity_group, &participant_scope, 1, "capacity-base");
        let expected = journal_metadata(capacity_group, &participant_scope, 2, "capacity-expected");
        let keypackage_operation = hex_sha256(b"keypackage-capacity-operation");
        ledger
            .begin_operation(
                &keypackage_operation,
                "secure_mesh.mls.member.add",
                &hex_sha256(b"keypackage-capacity-request"),
                &local.identity,
                now + 2,
            )
            .unwrap();
        let keypackage_prepared = PreparedMlsSecurityInputs {
            local_endpoint_scope_hash: local_scope.clone(),
            key_package: Some(PreparedMlsKeyPackageUse {
                key_package_id_hash: hex_sha256(b"new-keypackage-id"),
                key_package_public_key_hash: hex_sha256(b"new-keypackage-public"),
                group_id_hash: expected.group_id_hash.clone(),
            }),
            capability_proofs: [
                PreparedMlsCapabilityProofUse {
                    proof_digest: hex_sha256(b"keypackage-proof-one"),
                    expires_at_unix_seconds: now + 100,
                },
                PreparedMlsCapabilityProofUse {
                    proof_digest: hex_sha256(b"keypackage-proof-two"),
                    expires_at_unix_seconds: now + 100,
                },
            ],
            consumed_at_unix_seconds: now,
        };
        let keypackage_capacity_error = ledger
            .stage_operation(
                &keypackage_operation,
                &serde_json::json!({}),
                capacity_group,
                Some(&base),
                &expected,
                &keypackage_prepared,
                now + 2,
            )
            .unwrap_err();
        assert!(
            keypackage_capacity_error
                .to_string()
                .contains("at capacity")
        );
        assert!(
            ledger
                .abort_empty_prepared_operation(&keypackage_operation)
                .unwrap()
        );

        {
            let tx = ledger.connection.transaction().unwrap();
            for index in 0..(MAX_PERSISTED_MLS_CAPABILITY_PROOFS - 1) {
                tx.execute(
                    r#"
                    INSERT INTO secure_mesh_mls_capability_proof_uses (
                        local_endpoint_scope_hash, proof_digest,
                        expires_at_unix_seconds, consumed_at_unix_seconds
                    ) VALUES (?1, ?2, ?3, ?4)
                    "#,
                    params![
                        local_scope,
                        hex_sha256(format!("capability-proof-{index}").as_bytes()),
                        now + 100,
                        now,
                    ],
                )
                .unwrap();
            }
            tx.commit().unwrap();
        }
        let proof_operation = hex_sha256(b"proof-capacity-operation");
        ledger
            .begin_operation(
                &proof_operation,
                "secure_mesh.mls.commit.process",
                &hex_sha256(b"proof-capacity-request"),
                &local.identity,
                now + 3,
            )
            .unwrap();
        let proof_prepared = PreparedMlsSecurityInputs {
            local_endpoint_scope_hash: local_scope,
            key_package: None,
            capability_proofs: [
                PreparedMlsCapabilityProofUse {
                    proof_digest: hex_sha256(b"new-capability-proof-one"),
                    expires_at_unix_seconds: now + 100,
                },
                PreparedMlsCapabilityProofUse {
                    proof_digest: hex_sha256(b"new-capability-proof-two"),
                    expires_at_unix_seconds: now + 100,
                },
            ],
            consumed_at_unix_seconds: now,
        };
        let proof_capacity_error = ledger
            .stage_operation(
                &proof_operation,
                &serde_json::json!({}),
                capacity_group,
                Some(&base),
                &expected,
                &proof_prepared,
                now + 3,
            )
            .unwrap_err();
        assert!(proof_capacity_error.to_string().contains("at capacity"));
        assert!(
            ledger
                .abort_empty_prepared_operation(&proof_operation)
                .unwrap()
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_mls_product_identity_bound_credentials_and_welcome_roster() {
        let alice = device("desktop_gui:alice");
        let bob = device("mobile:bob");
        let group_id = b"product-group-1".as_slice();
        let mut group = create_product_group(
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            group_id,
        )
        .unwrap();
        let bob_kp = bob.participant.generate_key_package().unwrap();
        let path = ledger_path("welcome");
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        let welcome =
            add_test_product_member(&mut group, &alice, &bob, &bob_kp, &mut ledger, "kp-bob-1");

        let invitation = SecureMeshMlsExpectedInvitation::new(
            group_id,
            "desktop_gui:alice",
            ["desktop_gui:alice", "mobile:bob"],
        )
        .unwrap();
        let bob_group =
            join_test_product_group(&bob, &alice, &invitation, &welcome, &mut ledger).unwrap();
        assert_eq!(bob_group.member_count(), 2);

        let unexpected = SecureMeshMlsExpectedInvitation::new(
            b"other-group",
            "desktop_gui:alice",
            ["desktop_gui:alice", "mobile:bob"],
        )
        .unwrap();
        let rejected = join_test_product_group(&bob, &alice, &unexpected, &welcome, &mut ledger);
        assert!(rejected.is_err());
        let rejected = rejected.err().unwrap();
        assert!(
            rejected.to_string().contains("group id mismatch")
                || rejected.to_string().contains("welcome")
        );

        let unverified =
            authorize_welcome_acceptance(&invitation, &DeviceTrustState::Unverified, group_id)
                .unwrap_err();
        assert!(unverified.to_string().contains("not verified"));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn secure_mesh_mls_product_keypackage_one_time_consumption() {
        let alice = device("desktop_gui:alice");
        let bob = device("mobile:bob");
        let mut group = create_product_group(
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            b"kp-once",
        )
        .unwrap();
        let bob_kp = bob.participant.generate_key_package().unwrap();
        let path = ledger_path("once");
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        add_test_product_member(
            &mut group,
            &alice,
            &bob,
            &bob_kp,
            &mut ledger,
            "kp-bob-reuse",
        );
        let owner_proof = sign_mls_keypackage_capability_proof(
            &alice.identity,
            &alice.signing_key,
            &capability_evaluation(),
            &bob_kp,
            capability_now(),
        )
        .unwrap();
        let member_proof = sign_mls_keypackage_capability_proof(
            &bob.identity,
            &bob.signing_key,
            &capability_evaluation(),
            &bob_kp,
            capability_now(),
        )
        .unwrap();
        let group_id = group.group_id_bytes().unwrap();
        let base = group
            .public_metadata(alice.identity.fingerprint().unwrap())
            .unwrap();
        let mut expected = base.clone();
        expected.epoch += 1;
        expected.member_count += 1;
        expected.public_state_digest =
            format!("sha256:{}", hex_sha256(b"keypackage-replay-expected-state"));
        let prepared = prepare_member_add_security_inputs(
            &alice.identity,
            "kp-bob-reuse",
            bob_kp.as_public_bytes(),
            &expected.group_id_hash,
            &owner_proof,
            &member_proof,
            capability_now().unix_timestamp(),
        )
        .unwrap();
        let operation_id = begin_test_journal_operation(
            &mut ledger,
            "secure_mesh.mls.member.add",
            b"keypackage-replay-attempt",
            &alice.identity,
            capability_now(),
        )
        .unwrap();
        let reuse = stage_test_journal_operation(
            &mut ledger,
            &operation_id,
            &group_id,
            Some(&base),
            &expected,
            &prepared,
            &serde_json::json!({}),
            capability_now(),
        )
        .unwrap_err();
        assert!(reuse.to_string().contains("already consumed"));
        assert!(
            ledger
                .was_key_package_consumed(&alice.identity, "kp-bob-reuse")
                .unwrap()
        );
        assert_eq!(
            ledger
                .key_package_consumed_at(&alice.identity, "kp-bob-reuse")
                .unwrap(),
            Some(capability_now().unix_timestamp())
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn secure_mesh_mls_capability_proof_freshness_accepts_realistic_clock_windows() {
        let now = capability_now();

        for (name, proof_time, should_succeed) in [
            ("earlier", now - time::Duration::seconds(2), true),
            (
                "future-within-skew",
                now + time::Duration::seconds(CAPABILITY_PROOF_MAX_CLOCK_SKEW_SECONDS),
                true,
            ),
            (
                "future-beyond-skew",
                now + time::Duration::seconds(CAPABILITY_PROOF_MAX_CLOCK_SKEW_SECONDS + 1),
                false,
            ),
            (
                "expired",
                now - time::Duration::seconds(CAPABILITY_PROOF_MAX_LIFETIME_SECONDS + 1),
                false,
            ),
        ] {
            let owner = device(&format!("desktop_gui:freshness-owner-{name}"));
            let member = device(&format!("mobile:freshness-member-{name}"));
            let mut group = create_product_group(
                &owner.participant,
                &owner.identity,
                &DeviceTrustState::Verified,
                format!("freshness-{name}"),
            )
            .unwrap();
            let key_package = member.participant.generate_key_package().unwrap();
            let path = ledger_path(name);
            let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
            let result = add_test_product_member_with_times(
                &mut group,
                &owner,
                &member,
                &key_package,
                &mut ledger,
                &format!("kp-{name}"),
                proof_time,
                now,
            );
            assert_eq!(result.is_ok(), should_succeed, "freshness case {name}");
            let _ = std::fs::remove_file(path);
        }
    }

    #[test]
    fn secure_mesh_mls_replay_watermark_rejects_expiry_revival_after_clock_rollback() {
        let path = ledger_path("capability-proof-clock-rollback");
        let _ = std::fs::remove_file(&path);
        let scope = hex_sha256(b"mls-clock-rollback-scope");
        let prepared =
            |label: &str, consumed_at_unix_seconds: i64, expiry: i64| PreparedMlsSecurityInputs {
                local_endpoint_scope_hash: scope.clone(),
                key_package: None,
                capability_proofs: [
                    PreparedMlsCapabilityProofUse {
                        proof_digest: format!(
                            "sha256:{}",
                            hex_sha256(format!("{label}-a").as_bytes())
                        ),
                        expires_at_unix_seconds: expiry,
                    },
                    PreparedMlsCapabilityProofUse {
                        proof_digest: format!(
                            "sha256:{}",
                            hex_sha256(format!("{label}-b").as_bytes())
                        ),
                        expires_at_unix_seconds: expiry,
                    },
                ],
                consumed_at_unix_seconds,
            };
        let old = prepared("old", 900, 1_000);
        let new = prepared("new", 2_000, 2_100);
        {
            let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
            let tx = ledger
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .unwrap();
            consume_prepared_security_transaction(&tx, &old, 900).unwrap();
            tx.commit().unwrap();
            let tx = ledger
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .unwrap();
            consume_prepared_security_transaction(&tx, &new, 2_000).unwrap();
            tx.commit().unwrap();
        }
        let mut reopened = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        let tx = reopened
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .unwrap();
        let revived = consume_prepared_security_transaction(&tx, &old, 950).unwrap_err();
        assert!(revived.to_string().contains("clock rollback"));
        drop(tx);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_mls_security_ledger_survives_restart_and_rolls_back_atomically() {
        let alice = device("desktop_gui:ledger-alice");
        let bob = device("mobile:ledger-bob");
        let mut group = create_product_group(
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            b"persistent-ledger",
        )
        .unwrap();
        let bob_key_package = bob.participant.generate_key_package().unwrap();
        let path = ledger_path("persistent-replay");
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        add_test_product_member(
            &mut group,
            &alice,
            &bob,
            &bob_key_package,
            &mut ledger,
            "sensitive-key-package-id",
        );
        let extension = group.capability_extension().unwrap();
        let (first, second) = active_pair_capability_proofs(&extension).unwrap();
        let first = first.clone();
        let second = second.clone();
        drop(ledger);

        let mut reopened = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        let group_id = group.group_id_bytes().unwrap();
        let base = group
            .public_metadata(alice.identity.fingerprint().unwrap())
            .unwrap();
        let mut expected = base.clone();
        expected.epoch += 1;
        expected.public_state_digest =
            format!("sha256:{}", hex_sha256(b"capability-replay-expected-state"));
        let replay_prepared = prepare_capability_security_inputs(
            &alice.identity,
            &first,
            &second,
            capability_now().unix_timestamp(),
        )
        .unwrap();
        let replay_operation = begin_test_journal_operation(
            &mut reopened,
            "secure_mesh.mls.commit.process",
            b"capability-replay-after-reopen",
            &alice.identity,
            capability_now(),
        )
        .unwrap();
        let replay = stage_test_journal_operation(
            &mut reopened,
            &replay_operation,
            &group_id,
            Some(&base),
            &expected,
            &replay_prepared,
            &serde_json::json!({}),
            capability_now(),
        )
        .unwrap_err();
        assert!(replay.to_string().contains("replay"));

        let atomic_prepared = prepare_member_add_security_inputs(
            &alice.identity,
            "must-roll-back",
            b"different-public-key",
            &expected.group_id_hash,
            &first,
            &second,
            capability_now().unix_timestamp(),
        )
        .unwrap();
        let atomic_operation = begin_test_journal_operation(
            &mut reopened,
            "secure_mesh.mls.member.add",
            b"atomic-replay-after-reopen",
            &alice.identity,
            capability_now(),
        )
        .unwrap();
        let atomic_error = stage_test_journal_operation(
            &mut reopened,
            &atomic_operation,
            &group_id,
            Some(&base),
            &expected,
            &atomic_prepared,
            &serde_json::json!({}),
            capability_now(),
        )
        .unwrap_err();
        assert!(atomic_error.to_string().contains("replay"));
        assert!(
            !reopened
                .was_key_package_consumed(&alice.identity, "must-roll-back")
                .unwrap()
        );
        drop(reopened);

        let database_bytes = std::fs::read(&path).unwrap();
        let database_text = String::from_utf8_lossy(&database_bytes);
        assert!(!database_text.contains(&alice.identity.endpoint_id));
        assert!(!database_text.contains("sensitive-key-package-id"));
        assert!(!database_text.contains(&first.signature));
        assert!(!database_text.contains(&second.signature));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_mls_product_binds_claimed_identity_to_openmls_signers() {
        let alice = device("desktop_gui:signer-alice");
        let bob = device("mobile:signer-bob");
        let wrong_owner = create_product_group(
            &alice.participant,
            &bob.identity,
            &DeviceTrustState::Verified,
            b"wrong-owner",
        )
        .err()
        .expect("mismatched participant identity must fail");
        assert!(wrong_owner.to_string().contains("identity-bound"));

        let mut alice_group = create_product_group(
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            b"signer-binding",
        )
        .unwrap();
        let bob_key_package = bob.participant.generate_key_package().unwrap();
        let path = ledger_path("signer-binding");
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        let welcome = add_test_product_member(
            &mut alice_group,
            &alice,
            &bob,
            &bob_key_package,
            &mut ledger,
            "kp-signer-bob",
        );
        let invitation = SecureMeshMlsExpectedInvitation::new(
            b"signer-binding",
            &alice.identity.endpoint_id,
            [
                alice.identity.endpoint_id.clone(),
                bob.identity.endpoint_id.clone(),
            ],
        )
        .unwrap();
        let mut bob_group =
            join_test_product_group(&bob, &alice, &invitation, &welcome, &mut ledger).unwrap();
        let trusted_roster = BTreeMap::from([
            (alice.identity.endpoint_id.clone(), alice.identity.clone()),
            (bob.identity.endpoint_id.clone(), bob.identity.clone()),
        ]);
        let context = SecureMeshContentContext::new(
            "env-actual-signer",
            "msg-actual-signer",
            "mailbox-actual-signer",
            &bob.identity.endpoint_id,
            &bob.identity.endpoint_id,
            format!("mls:{}:actual-signer", alice_group.epoch()),
            "2026-07-11T00:00:00Z",
            "2026-07-11T00:10:00Z",
        );
        let plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, b"signed-by-alice");

        let claimed_sender_error = seal_product_payload_message(
            &mut alice_group,
            &alice.participant,
            &bob.identity,
            &DeviceTrustState::Verified,
            &trusted_roster,
            &context,
            &plaintext,
        )
        .unwrap_err();
        assert!(claimed_sender_error.to_string().contains("signer"));

        // A crate-internal raw message simulates an attempted bypass. Product open still checks
        // the actual OpenMLS credential and leaf signing key rather than trusting caller labels.
        let raw_message = alice_group
            .seal_payload_message(&alice.participant, &context, &plaintext)
            .unwrap();
        let actual_signer_error = open_product_payload_message(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &bob.identity,
            &DeviceTrustState::Verified,
            &trusted_roster,
            &context,
            &raw_message,
            SecureMeshPayloadKind::Command,
        )
        .unwrap_err();
        assert!(actual_signer_error.to_string().contains("payload signer"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_mls_product_rejects_commit_claimed_as_another_member() {
        let alice = device("desktop_gui:commit-signer-alice");
        let bob = device("mobile:commit-signer-bob");
        let charlie = device("mobile:commit-signer-charlie");
        let group_id = b"commit-signer-binding";
        let mut alice_group = create_product_group(
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            group_id,
        )
        .unwrap();
        let path = ledger_path("commit-signer-binding");
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        let bob_key_package = bob.participant.generate_key_package().unwrap();
        let bob_welcome = add_test_product_member(
            &mut alice_group,
            &alice,
            &bob,
            &bob_key_package,
            &mut ledger,
            "kp-commit-signer-bob",
        );
        let bob_invitation = SecureMeshMlsExpectedInvitation::new(
            group_id,
            &alice.identity.endpoint_id,
            [
                alice.identity.endpoint_id.clone(),
                bob.identity.endpoint_id.clone(),
            ],
        )
        .unwrap();
        let mut bob_group =
            join_test_product_group(&bob, &alice, &bob_invitation, &bob_welcome, &mut ledger)
                .unwrap();
        let charlie_key_package = charlie.participant.generate_key_package().unwrap();
        let charlie_welcome = add_test_product_member(
            &mut alice_group,
            &alice,
            &charlie,
            &charlie_key_package,
            &mut ledger,
            "kp-commit-signer-charlie",
        );
        let trusted_roster = BTreeMap::from([
            (alice.identity.endpoint_id.clone(), alice.identity.clone()),
            (bob.identity.endpoint_id.clone(), bob.identity.clone()),
            (
                charlie.identity.endpoint_id.clone(),
                charlie.identity.clone(),
            ),
        ]);
        let epoch_before = bob_group.epoch();
        let error = process_test_product_commit(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &bob.identity,
            &DeviceTrustState::Verified,
            Some(&charlie.identity),
            None,
            &trusted_roster,
            &charlie_welcome.commit_message,
            &mut ledger,
            capability_now(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("commit signer"));
        assert_eq!(bob_group.epoch(), epoch_before);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_mls_product_commit_sender_roster_and_epoch_lag() {
        let roster = BTreeSet::from(["desktop_gui:alice".to_string(), "mobile:bob".to_string()]);
        authorize_commit_sender("desktop_gui:alice", &DeviceTrustState::Verified, &roster).unwrap();
        let outsider = authorize_commit_sender("mobile:eve", &DeviceTrustState::Verified, &roster)
            .unwrap_err();
        assert!(outsider.to_string().contains("not in the verified roster"));
        authorize_epoch_lag(5, 5).unwrap();
        authorize_epoch_lag(5, 3).unwrap();
        let stale = authorize_epoch_lag(5, 2).unwrap_err();
        assert!(stale.to_string().contains("epoch lag"));
    }

    #[test]
    fn secure_mesh_mls_product_forged_sender_and_typed_kt_member_add() {
        authorize_sender_endpoint_binding("desktop_gui:alice", "desktop_gui:alice").unwrap();
        let forged =
            authorize_sender_endpoint_binding("mobile:attacker", "desktop_gui:alice").unwrap_err();
        assert!(forged.to_string().contains("forged sender"));

        let bob = device("mobile:bob-kt");
        let key_package = bob.participant.generate_key_package().unwrap();
        let authorization = authorized_member_add_directory(
            &bob,
            &key_package,
            7,
            11,
            capability_now(),
            DirectoryAuthorizationPurpose::MlsMemberAdd,
        );
        authorize_member_add_with_directory(&authorization, &bob.identity, &key_package, 7, 11)
            .unwrap();

        let wrong_identity = device("mobile:eve-kt");
        let identity_error = authorize_member_add_with_directory(
            &authorization,
            &wrong_identity.identity,
            &key_package,
            7,
            11,
        )
        .unwrap_err();
        assert!(identity_error.to_string().contains("identity commitment"));

        let directory_version_error =
            authorize_member_add_with_directory(&authorization, &bob.identity, &key_package, 8, 11)
                .unwrap_err();
        assert!(
            directory_version_error
                .to_string()
                .contains("publication version")
        );

        let key_package_version_error =
            authorize_member_add_with_directory(&authorization, &bob.identity, &key_package, 7, 12)
                .unwrap_err();
        assert!(
            key_package_version_error
                .to_string()
                .contains("KeyPackage commitment")
        );

        let substituted_key_package = bob.participant.generate_key_package().unwrap();
        let key_package_digest_error = authorize_member_add_with_directory(
            &authorization,
            &bob.identity,
            &substituted_key_package,
            7,
            11,
        )
        .unwrap_err();
        assert!(
            key_package_digest_error
                .to_string()
                .contains("KeyPackage commitment")
        );

        let wrong_purpose = authorized_member_add_directory(
            &bob,
            &key_package,
            7,
            11,
            capability_now(),
            DirectoryAuthorizationPurpose::Pairing,
        );
        let purpose_error =
            authorize_member_add_with_directory(&wrong_purpose, &bob.identity, &key_package, 7, 11)
                .unwrap_err();
        assert!(purpose_error.to_string().contains("purpose mismatch"));
    }

    #[test]
    fn secure_mesh_mls_product_payload_rejects_forged_sender_context() {
        let alice = device("desktop_gui:alice");
        let bob = device("mobile:bob");
        let mut alice_group = create_product_group(
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            b"sender-bind",
        )
        .unwrap();
        let bob_kp = bob.participant.generate_key_package().unwrap();
        let path = ledger_path("sender");
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        let welcome = add_test_product_member(
            &mut alice_group,
            &alice,
            &bob,
            &bob_kp,
            &mut ledger,
            "kp-bob-sender",
        );
        let invitation = SecureMeshMlsExpectedInvitation::new(
            b"sender-bind",
            "desktop_gui:alice",
            ["desktop_gui:alice", "mobile:bob"],
        )
        .unwrap();
        let mut bob_group =
            join_test_product_group(&bob, &alice, &invitation, &welcome, &mut ledger).unwrap();
        let context = SecureMeshContentContext::new(
            "env-sender",
            "msg-sender",
            "mailbox-bob",
            "desktop_gui:alice",
            "mobile:bob",
            format!("mls:{}:sender-bind", alice_group.epoch()),
            "2026-07-11T00:00:00Z",
            "2026-07-11T00:10:00Z",
        );
        let plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, br#"{"op":"ping"}"#)
                .with_content_type("application/json");
        let trusted_roster = BTreeMap::from([
            (alice.identity.endpoint_id.clone(), alice.identity.clone()),
            (bob.identity.endpoint_id.clone(), bob.identity.clone()),
        ]);
        let sealed = seal_product_payload_message(
            &mut alice_group,
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            &trusted_roster,
            &context,
            &plaintext,
        )
        .unwrap();
        authorize_sender_endpoint_binding(&context.sender_endpoint_id, "desktop_gui:alice")
            .unwrap();
        let mut forged = context.clone();
        forged.sender_endpoint_id = "mobile:attacker".to_string();
        let error =
            authorize_sender_endpoint_binding(&forged.sender_endpoint_id, "desktop_gui:alice")
                .unwrap_err();
        assert!(error.to_string().contains("forged sender"));
        // Opening with forged sender context fails closed on AAD/exporter binding.
        let open_error = open_product_payload_message(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            &trusted_roster,
            &forged,
            &sealed,
            SecureMeshPayloadKind::Command,
        )
        .unwrap_err();
        assert!(
            open_error.to_string().contains("forged sender")
                || open_error.to_string().contains("AAD")
                || open_error.to_string().contains("open failed")
                || open_error.to_string().contains("mismatch")
        );
        let opened = open_product_payload_message(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            &trusted_roster,
            &context,
            &sealed,
            SecureMeshPayloadKind::Command,
        )
        .unwrap();
        assert_eq!(opened.body, br#"{"op":"ping"}"#);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn secure_mesh_mls_capability_extension_is_in_authenticated_add_join_commit_and_payload_paths()
    {
        let alice = device("desktop_gui:capability-alice");
        let bob = device("desktop_sidecar:capability-bob");
        let charlie = device("mobile:capability-charlie");
        let group_id = b"secure-mesh-product-capability-group";
        let mut alice_group = create_product_group(
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            group_id,
        )
        .unwrap();
        let pending_context = SecureMeshContentContext::new(
            "env-capability-pending",
            "msg-capability-pending",
            "mailbox-capability-pending",
            &alice.identity.endpoint_id,
            &bob.identity.endpoint_id,
            "mls:capability-pending",
            "2026-07-11T00:00:00Z",
            "2026-07-11T00:10:00Z",
        );
        let pending_plaintext =
            SecureMeshPlaintext::new(SecureMeshPayloadKind::Command, b"blocked");
        let pending_error = seal_product_payload_message(
            &mut alice_group,
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            &BTreeMap::from([(alice.identity.endpoint_id.clone(), alice.identity.clone())]),
            &pending_context,
            &pending_plaintext,
        )
        .unwrap_err();
        assert!(
            pending_error
                .to_string()
                .contains("capability negotiation is incomplete")
        );

        let path = ledger_path("capability-group-context");
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();
        let bob_key_package = bob.participant.generate_key_package().unwrap();
        let bob_welcome = add_test_product_member(
            &mut alice_group,
            &alice,
            &bob,
            &bob_key_package,
            &mut ledger,
            "kp-capability-bob",
        );
        let bob_invitation = SecureMeshMlsExpectedInvitation::new(
            group_id,
            &alice.identity.endpoint_id,
            [
                alice.identity.endpoint_id.clone(),
                bob.identity.endpoint_id.clone(),
            ],
        )
        .unwrap();
        let mut bob_group =
            join_test_product_group(&bob, &alice, &bob_invitation, &bob_welcome, &mut ledger)
                .unwrap();
        alice_group.require_active_capability_negotiation().unwrap();
        bob_group.require_active_capability_negotiation().unwrap();

        let charlie_key_package = charlie.participant.generate_key_package().unwrap();
        let charlie_welcome = add_test_product_member(
            &mut alice_group,
            &alice,
            &charlie,
            &charlie_key_package,
            &mut ledger,
            "kp-capability-charlie",
        );
        assert!(!charlie_welcome.commit_message.is_empty());
        let trusted_roster = BTreeMap::from([
            (alice.identity.endpoint_id.clone(), alice.identity.clone()),
            (bob.identity.endpoint_id.clone(), bob.identity.clone()),
            (
                charlie.identity.endpoint_id.clone(),
                charlie.identity.clone(),
            ),
        ]);
        process_test_product_commit(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            Some(&charlie.identity),
            None,
            &trusted_roster,
            &charlie_welcome.commit_message,
            &mut ledger,
            capability_now(),
        )
        .unwrap();
        assert_eq!(
            alice_group.capability_extension().unwrap(),
            bob_group.capability_extension().unwrap()
        );
        let charlie_invitation = SecureMeshMlsExpectedInvitation::new(
            group_id,
            &alice.identity.endpoint_id,
            [
                alice.identity.endpoint_id.clone(),
                bob.identity.endpoint_id.clone(),
                charlie.identity.endpoint_id.clone(),
            ],
        )
        .unwrap();
        let mut charlie_group = join_test_product_group_with_roster(
            &charlie,
            &alice,
            &charlie_invitation,
            &charlie_welcome,
            &trusted_roster,
            &mut ledger,
        )
        .unwrap();
        let joined_extension = charlie_group.capability_extension().unwrap();
        let SecureMeshMlsCapabilityExtension::Active {
            member_capability_proofs,
            ..
        } = &joined_extension
        else {
            panic!("joined MLS capability extension must be active");
        };
        assert_eq!(member_capability_proofs.len(), 3);
        assert_eq!(
            member_capability_proofs
                .keys()
                .cloned()
                .collect::<BTreeSet<_>>(),
            charlie_invitation.expected_roster_endpoint_ids
        );
        let mut incomplete_history = joined_extension.clone();
        let SecureMeshMlsCapabilityExtension::Active {
            member_capability_proofs,
            ..
        } = &mut incomplete_history
        else {
            unreachable!();
        };
        member_capability_proofs.remove(&bob.identity.endpoint_id);
        let incomplete_error = verify_complete_member_capability_proof_map(
            &incomplete_history,
            &charlie_invitation.expected_roster_endpoint_ids,
            &trusted_roster,
        )
        .unwrap_err();
        assert!(
            incomplete_error
                .to_string()
                .contains("does not match roster")
        );

        let context = SecureMeshContentContext::new(
            "env-capability-active",
            "msg-capability-active",
            "mailbox-capability-active",
            &alice.identity.endpoint_id,
            "secure-mesh-capability-group",
            format!("mls:{}:capability-active", alice_group.epoch()),
            "2026-07-11T00:00:00Z",
            "2026-07-11T00:10:00Z",
        );
        let plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::Command,
            br#"{"op":"capability-bound-group"}"#,
        );
        let message = seal_product_payload_message(
            &mut alice_group,
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            &trusted_roster,
            &context,
            &plaintext,
        )
        .unwrap();
        let bob_opened = open_product_payload_message(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            &trusted_roster,
            &context,
            &message,
            SecureMeshPayloadKind::Command,
        )
        .unwrap();
        let charlie_opened = open_product_payload_message(
            &mut charlie_group,
            &charlie.participant,
            &charlie.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            &trusted_roster,
            &context,
            &message,
            SecureMeshPayloadKind::Command,
        )
        .unwrap();
        assert_eq!(bob_opened.body, charlie_opened.body);

        let stripped_extension_commit = alice_group
            .stage_test_stripped_capability_extension_commit(&alice.participant)
            .unwrap();
        let tamper_offset = stripped_extension_commit.len() / 2;
        let mut tampered_update = stripped_extension_commit.clone();
        tampered_update[tamper_offset] ^= 1;
        let bob_epoch_before = bob_group.epoch();
        let tampered_error = process_test_product_commit(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            None,
            None,
            &trusted_roster,
            &tampered_update,
            &mut ledger,
            capability_now(),
        )
        .unwrap_err();
        assert!(
            tampered_error.to_string().contains("commit")
                || tampered_error.to_string().contains("signature")
                || tampered_error.to_string().contains("confirmation")
        );
        assert_eq!(bob_group.epoch(), bob_epoch_before);

        let charlie_epoch_before = charlie_group.epoch();
        let stripped_error = process_test_product_commit(
            &mut charlie_group,
            &charlie.participant,
            &charlie.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            None,
            None,
            &trusted_roster,
            &stripped_extension_commit,
            &mut ledger,
            capability_now(),
        )
        .unwrap_err();
        assert!(
            stripped_error.to_string().contains("extension is missing")
                || stripped_error.to_string().contains("downgrade")
        );
        assert_eq!(charlie_group.epoch(), charlie_epoch_before);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_mls_product_remove_is_identity_exact_journaled_and_excludes_file_epoch() {
        let alice = device("desktop_gui:remove-alice");
        let bob = device("desktop_sidecar:remove-bob");
        let charlie = device("mobile:remove-charlie");
        let group_id = b"secure-mesh-product-remove-group";
        let now = capability_now();
        let path = ledger_path("product-remove");
        let mut ledger = SecureMeshMlsSecurityLedger::open(&path).unwrap();

        let mut alice_group = create_product_group(
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            group_id,
        )
        .unwrap();
        let bob_key_package = bob.participant.generate_key_package().unwrap();
        let bob_welcome = add_test_product_member(
            &mut alice_group,
            &alice,
            &bob,
            &bob_key_package,
            &mut ledger,
            "kp-remove-bob",
        );
        let bob_invitation = SecureMeshMlsExpectedInvitation::new(
            group_id,
            &alice.identity.endpoint_id,
            [
                alice.identity.endpoint_id.clone(),
                bob.identity.endpoint_id.clone(),
            ],
        )
        .unwrap();
        let mut bob_group =
            join_test_product_group(&bob, &alice, &bob_invitation, &bob_welcome, &mut ledger)
                .unwrap();

        let charlie_key_package = charlie.participant.generate_key_package().unwrap();
        let charlie_welcome = add_test_product_member(
            &mut alice_group,
            &alice,
            &charlie,
            &charlie_key_package,
            &mut ledger,
            "kp-remove-charlie",
        );
        let full_roster = BTreeMap::from([
            (alice.identity.endpoint_id.clone(), alice.identity.clone()),
            (bob.identity.endpoint_id.clone(), bob.identity.clone()),
            (
                charlie.identity.endpoint_id.clone(),
                charlie.identity.clone(),
            ),
        ]);
        process_test_product_commit(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            Some(&charlie.identity),
            None,
            &full_roster,
            &charlie_welcome.commit_message,
            &mut ledger,
            now,
        )
        .unwrap();
        let charlie_invitation = SecureMeshMlsExpectedInvitation::new(
            group_id,
            &alice.identity.endpoint_id,
            full_roster.keys().cloned(),
        )
        .unwrap();
        let mut charlie_group = join_test_product_group_with_roster(
            &charlie,
            &alice,
            &charlie_invitation,
            &charlie_welcome,
            &full_roster,
            &mut ledger,
        )
        .unwrap();

        let forged_key = SigningKey::generate(&mut OsRng);
        let forged_target = DeviceTrustPublicIdentity::new(
            charlie.identity.endpoint_id.clone(),
            SigningKey::generate(&mut OsRng).verifying_key().to_bytes(),
            forged_key.verifying_key().to_bytes(),
            charlie.identity.rotation_epoch,
        )
        .unwrap();
        let epoch_before_forgery = alice_group.epoch();
        let forged_error = match remove_product_member_prepared(
            &mut alice_group,
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            &forged_target,
            &DeviceTrustState::Verified,
            now,
        ) {
            Ok(_) => panic!("forged removal identity unexpectedly resolved"),
            Err(error) => error,
        };
        assert!(forged_error.to_string().contains("exact current roster"));
        assert_eq!(alice_group.epoch(), epoch_before_forgery);

        let base = alice_group
            .public_metadata(alice.identity.fingerprint().unwrap())
            .unwrap();
        let operation_id = begin_test_journal_operation(
            &mut ledger,
            "secure_mesh.mls.member.remove",
            charlie.identity.fingerprint().unwrap().as_bytes(),
            &alice.identity,
            now,
        )
        .unwrap();
        let (remove_commit, prepared) = remove_product_member_prepared(
            &mut alice_group,
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            &charlie.identity,
            &DeviceTrustState::Revoked,
            now,
        )
        .unwrap();
        assert!(remove_commit.welcome_message.is_none());
        let expected = alice_group
            .public_metadata(alice.identity.fingerprint().unwrap())
            .unwrap();
        commit_test_journal_operation(
            &mut ledger,
            &operation_id,
            group_id,
            Some(&base),
            &expected,
            &prepared,
            &serde_json::json!({"ok": true, "group": null}),
            now,
        )
        .unwrap();
        let replay_record = ledger
            .begin_operation(
                &operation_id,
                "secure_mesh.mls.member.remove",
                &hex_sha256(charlie.identity.fingerprint().unwrap().as_bytes()),
                &alice.identity,
                now.unix_timestamp(),
            )
            .unwrap();
        assert_eq!(replay_record.state, SecureMeshMlsOperationState::Delivered);

        let post_roster = BTreeMap::from([
            (alice.identity.endpoint_id.clone(), alice.identity.clone()),
            (bob.identity.endpoint_id.clone(), bob.identity.clone()),
        ]);
        process_test_product_commit(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            None,
            Some(&charlie.identity),
            &post_roster,
            &remove_commit.commit_message,
            &mut ledger,
            now,
        )
        .unwrap();
        process_test_product_commit(
            &mut charlie_group,
            &charlie.participant,
            &charlie.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            None,
            Some(&charlie.identity),
            &post_roster,
            &remove_commit.commit_message,
            &mut ledger,
            now,
        )
        .unwrap();
        assert!(!charlie_group.is_active());
        assert_eq!(alice_group.member_count(), 2);
        assert_eq!(bob_group.member_count(), 2);
        let SecureMeshMlsCapabilityExtension::Active {
            roster_transition,
            member_capability_proofs,
            ..
        } = alice_group.capability_extension().unwrap()
        else {
            panic!("removed-member group capability extension must remain active");
        };
        assert!(matches!(
            roster_transition,
            SecureMeshMlsRosterTransition::MemberRemoved { member_endpoint_id }
                if member_endpoint_id == charlie.identity.endpoint_id
        ));
        assert_eq!(
            member_capability_proofs
                .keys()
                .cloned()
                .collect::<BTreeSet<_>>(),
            post_roster.keys().cloned().collect::<BTreeSet<_>>()
        );

        let context = SecureMeshContentContext::new(
            "env-file-after-remove",
            "msg-file-after-remove",
            "mailbox-file-after-remove",
            &alice.identity.endpoint_id,
            &bob.identity.endpoint_id,
            format!("mls:{}:file-after-remove", alice_group.epoch()),
            "2026-07-11T00:00:00Z",
            "2026-07-11T00:10:00Z",
        );
        let file_chunk = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::FileChunk,
            b"new-epoch-file-key-material-is-not-for-removed-members",
        )
        .with_content_type("application/octet-stream");
        let sealed = seal_product_payload_message(
            &mut alice_group,
            &alice.participant,
            &alice.identity,
            &DeviceTrustState::Verified,
            &post_roster,
            &context,
            &file_chunk,
        )
        .unwrap();
        let opened = open_product_payload_message(
            &mut bob_group,
            &bob.participant,
            &bob.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            &post_roster,
            &context,
            &sealed,
            SecureMeshPayloadKind::FileChunk,
        )
        .unwrap();
        assert_eq!(opened.body, file_chunk.body);
        let removed_open_error = open_product_payload_message(
            &mut charlie_group,
            &charlie.participant,
            &charlie.identity,
            &alice.identity,
            &DeviceTrustState::Verified,
            &post_roster,
            &context,
            &sealed,
            SecureMeshPayloadKind::FileChunk,
        )
        .unwrap_err();
        assert!(
            removed_open_error.to_string().contains("not active")
                || removed_open_error.to_string().contains("inactive member")
                || removed_open_error.to_string().contains("eviction")
                || removed_open_error.to_string().contains("open failed")
                || removed_open_error.to_string().contains("epoch")
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_mls_product_roster_cross_check() {
        let alice = device("desktop_gui:alice");
        let bob = device("mobile:bob");
        let expected = BTreeSet::from([
            alice.identity.endpoint_id.clone(),
            bob.identity.endpoint_id.clone(),
        ]);
        let mut trusted = BTreeMap::new();
        trusted.insert(alice.identity.endpoint_id.clone(), alice.identity.clone());
        trusted.insert(bob.identity.endpoint_id.clone(), bob.identity.clone());
        let observed = vec![
            mls_credential_identity_bytes(&alice.identity).unwrap(),
            mls_credential_identity_bytes(&bob.identity).unwrap(),
        ];
        cross_check_roster(&expected, &observed, &trusted).unwrap();
        let diverged = cross_check_roster(&expected, &observed[..1], &trusted).unwrap_err();
        assert!(diverged.to_string().contains("roster size divergence"));
    }
}
