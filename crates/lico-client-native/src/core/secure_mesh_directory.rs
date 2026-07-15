//! Typed Key Transparency directory authority.
//!
//! The directory claim commits the endpoint identity, the complete Pairwise prekey publication,
//! and the MLS KeyPackage publication in one append-log leaf.  Callers never receive an
//! `AuthorizedDirectoryLeaf` without verification of the pinned log, fresh STH, RFC 9162
//! inclusion/consistency paths, authenticated sparse-map latest value, and durable monotonic CAS.

use anyhow::{Result, anyhow, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::Path;

use crate::core::secure_mesh_transparency::{
    DirectoryComponentCommitments, KT_JSON_SAFE_INTEGER_MAX, KtAuthorityProvenance,
    KtFreshnessPolicy, PinnedKtLogKey, SecureMeshKtAuthorizationReceipt,
    SecureMeshKtCachedCheckpoint, SecureMeshKtClientState, SecureMeshKtConsistencyProof,
    SecureMeshKtGossipPayload, SecureMeshKtInclusionProof, SecureMeshKtMapProof,
    SecureMeshSignedTreeHead, SecureMeshTransparencyLeafBody, VerifiedKtFreshness,
    kt_log_leaf_hash,
};
use crate::core::secure_mesh_trust::DeviceTrustPublicIdentity;

pub const SECURE_MESH_DIRECTORY_CLAIM_VERSION: &str = "licolite.secure-mesh.directory-claim.v1";
pub const SECURE_MESH_DIRECTORY_AUTHORITY_STATUS: &str =
    "typed_identity_pairwise_prekeys_mls_keypackage_pinned_kt_latest_map_authority";

const DIRECTORY_CLAIM_DOMAIN: &[u8] = b"LCOSM-KT-DIRECTORY-CLAIM-v1";
const DIRECTORY_IDENTITY_COMMITMENT_DOMAIN: &[u8] = b"LCOSM-KT-DIRECTORY-IDENTITY-COMMITMENT-v1";
const AUTHORIZED_LEAF_DOMAIN: &[u8] = b"LCOSM-KT-AUTHORIZED-LEAF-v1";
const AUTHORIZED_LEAF_TRANSCRIPT_BINDING_DOMAIN: &[u8] =
    b"LCOSM-KT-AUTHORIZED-LEAF-TRANSCRIPT-BINDING-v1";
const AUTHORIZED_ABSENCE_DOMAIN: &[u8] = b"LCOSM-KT-AUTHORIZED-ABSENCE-v1";
const HASH_HEX_LEN: usize = 64;
#[allow(dead_code)]
const MAX_DIRECTORY_PROOF_HASHES: usize = 256;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PinnedKtLogConfiguration {
    pub log_id: String,
    pub key_id: String,
    pub public_key_hex: String,
    pub provenance: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshKtVerifierConfiguration {
    pub pin: PinnedKtLogConfiguration,
    pub max_sth_age_seconds: u64,
    pub max_future_skew_seconds: u64,
}

impl SecureMeshKtVerifierConfiguration {
    pub fn validate(&self) -> Result<()> {
        self.pin.clone().into_pin()?;
        KtFreshnessPolicy::strict(self.max_sth_age_seconds, self.max_future_skew_seconds)?;
        Ok(())
    }
}

impl PinnedKtLogConfiguration {
    pub fn into_pin(self) -> Result<PinnedKtLogKey> {
        let public_key = parse_digest(&self.public_key_hex)?;
        match self.provenance.as_str() {
            "user-configured-external" => PinnedKtLogKey::from_user_configured_ed25519_bytes(
                self.log_id,
                self.key_id,
                public_key,
            ),
            #[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
            "local-acceptance-mock" => PinnedKtLogKey::from_acceptance_mock_ed25519_bytes(
                self.log_id,
                self.key_id,
                public_key,
            ),
            _ => Err(anyhow!(
                "secure mesh KT pin provenance is unsupported or not available in this build"
            )),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshDirectoryKeyMaterialCommitment {
    /// Digest of the signed Pairwise prekey record and its endpoint signature.
    pub signed_prekey_bundle_digest: String,
    /// Digest of the published one-time-prekey batch, including identifiers and public keys.
    pub one_time_prekey_batch_digest: String,
    /// Monotonic version of the Pairwise prekey publication.
    pub pairwise_prekey_version: u64,
    /// Digest of the exact MLS KeyPackage bytes and credential binding.
    pub mls_key_package_digest: String,
    /// Monotonic version of the MLS KeyPackage publication.
    pub mls_key_package_version: u64,
}

impl SecureMeshDirectoryKeyMaterialCommitment {
    fn validate(&self) -> Result<()> {
        validate_digest(
            "signed prekey bundle digest",
            &self.signed_prekey_bundle_digest,
        )?;
        validate_digest(
            "one-time prekey batch digest",
            &self.one_time_prekey_batch_digest,
        )?;
        validate_digest("MLS KeyPackage digest", &self.mls_key_package_digest)?;
        ensure!(
            self.pairwise_prekey_version <= KT_JSON_SAFE_INTEGER_MAX
                && self.mls_key_package_version <= KT_JSON_SAFE_INTEGER_MAX,
            "secure mesh directory component version exceeds the cross-language safe range"
        );
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct SecureMeshDirectoryLeafClaim {
    pub endpoint: SecureMeshTransparencyLeafBody,
    pub key_material: SecureMeshDirectoryKeyMaterialCommitment,
    /// Monotonic version of the combined identity/prekey/KeyPackage directory publication.
    pub directory_version: u64,
}

impl SecureMeshDirectoryLeafClaim {
    pub fn stable_label(&self) -> String {
        self.endpoint.directory_key()
    }

    pub fn version(&self) -> u64 {
        self.directory_version
    }

    pub fn revoked(&self) -> bool {
        self.endpoint.is_revoked()
    }

    pub fn leaf_hash(&self) -> Result<[u8; 32]> {
        self.key_material.validate()?;
        ensure!(
            self.directory_version <= KT_JSON_SAFE_INTEGER_MAX,
            "secure mesh directory version exceeds the cross-language safe range"
        );
        let endpoint_hash = self.endpoint.leaf_hash()?;
        let mut claim = Vec::new();
        claim.extend_from_slice(DIRECTORY_CLAIM_DOMAIN);
        append_len_prefixed(&mut claim, SECURE_MESH_DIRECTORY_CLAIM_VERSION.as_bytes());
        append_len_prefixed(&mut claim, self.stable_label().as_bytes());
        claim.extend_from_slice(&endpoint_hash);
        claim.extend_from_slice(&self.directory_version.to_be_bytes());
        claim.extend_from_slice(&parse_digest(
            &self.key_material.signed_prekey_bundle_digest,
        )?);
        claim.extend_from_slice(&parse_digest(
            &self.key_material.one_time_prekey_batch_digest,
        )?);
        claim.extend_from_slice(&self.key_material.pairwise_prekey_version.to_be_bytes());
        claim.extend_from_slice(&parse_digest(&self.key_material.mls_key_package_digest)?);
        claim.extend_from_slice(&self.key_material.mls_key_package_version.to_be_bytes());
        claim.push(u8::from(self.revoked()));
        Ok(kt_log_leaf_hash(&claim))
    }

    pub fn leaf_hash_hex(&self) -> Result<String> {
        Ok(hex_encode(&self.leaf_hash()?))
    }

    pub fn identity_key_digest(&self) -> String {
        let mut transcript = Vec::new();
        transcript.extend_from_slice(DIRECTORY_IDENTITY_COMMITMENT_DOMAIN);
        append_len_prefixed(&mut transcript, self.endpoint.endpoint_id.as_bytes());
        append_len_prefixed(
            &mut transcript,
            self.endpoint.identity_public_key.as_bytes(),
        );
        append_len_prefixed(&mut transcript, self.endpoint.signing_public_key.as_bytes());
        append_len_prefixed(&mut transcript, self.endpoint.fingerprint.as_bytes());
        hex_encode(&Sha256::digest(transcript))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DirectoryAuthorizationPurpose {
    Pairing,
    PairwiseSignedPrekey,
    PairwiseOneTimePrekey,
    PairwiseSessionBootstrap,
    IdentityKeyChange,
    Revocation,
    SelfMonitor,
    MlsKeyPackage,
    MlsMemberAdd,
}

#[derive(Clone, Copy)]
pub struct DirectoryAuthorizationRequest<'a> {
    purpose: DirectoryAuthorizationPurpose,
    expected_directory_scope_commitment: &'a str,
    expected_identity: Option<&'a DeviceTrustPublicIdentity>,
    expected_directory_version: Option<u64>,
    expected_signed_prekey: Option<(&'a str, u64)>,
    expected_one_time_prekey: Option<(&'a str, u64)>,
    expected_mls_key_package: Option<(&'a str, u64)>,
    expected_exact_claim: Option<&'a SecureMeshDirectoryLeafClaim>,
}

impl<'a> DirectoryAuthorizationRequest<'a> {
    pub fn for_pairwise(
        purpose: DirectoryAuthorizationPurpose,
        directory_scope_commitment: &'a str,
        identity: &'a DeviceTrustPublicIdentity,
        signed_prekey_digest: &'a str,
        one_time_prekey_digest: &'a str,
        prekey_version: u64,
    ) -> Self {
        Self {
            purpose,
            expected_directory_scope_commitment: directory_scope_commitment,
            expected_identity: Some(identity),
            expected_directory_version: None,
            expected_signed_prekey: Some((signed_prekey_digest, prekey_version)),
            expected_one_time_prekey: Some((one_time_prekey_digest, prekey_version)),
            expected_mls_key_package: None,
            expected_exact_claim: None,
        }
    }

    pub fn for_mls(
        purpose: DirectoryAuthorizationPurpose,
        directory_scope_commitment: &'a str,
        identity: &'a DeviceTrustPublicIdentity,
        directory_version: u64,
        key_package_digest: &'a str,
        key_package_version: u64,
    ) -> Self {
        Self {
            purpose,
            expected_directory_scope_commitment: directory_scope_commitment,
            expected_identity: Some(identity),
            expected_directory_version: Some(directory_version),
            expected_signed_prekey: None,
            expected_one_time_prekey: None,
            expected_mls_key_package: Some((key_package_digest, key_package_version)),
            expected_exact_claim: None,
        }
    }

    pub fn for_full_subject(
        purpose: DirectoryAuthorizationPurpose,
        directory_scope_commitment: &'a str,
        identity: &'a DeviceTrustPublicIdentity,
        directory_version: u64,
        signed_prekey_digest: &'a str,
        one_time_prekey_digest: &'a str,
        pairwise_prekey_version: u64,
        mls_key_package_digest: &'a str,
        mls_key_package_version: u64,
    ) -> Self {
        Self {
            purpose,
            expected_directory_scope_commitment: directory_scope_commitment,
            expected_identity: Some(identity),
            expected_directory_version: Some(directory_version),
            expected_signed_prekey: Some((signed_prekey_digest, pairwise_prekey_version)),
            expected_one_time_prekey: Some((one_time_prekey_digest, pairwise_prekey_version)),
            expected_mls_key_package: Some((mls_key_package_digest, mls_key_package_version)),
            expected_exact_claim: None,
        }
    }

    pub fn for_exact_claim(
        purpose: DirectoryAuthorizationPurpose,
        directory_scope_commitment: &'a str,
        claim: &'a SecureMeshDirectoryLeafClaim,
    ) -> Self {
        Self {
            purpose,
            expected_directory_scope_commitment: directory_scope_commitment,
            expected_identity: None,
            expected_directory_version: None,
            expected_signed_prekey: None,
            expected_one_time_prekey: None,
            expected_mls_key_package: None,
            expected_exact_claim: Some(claim),
        }
    }

    #[cfg(test)]
    fn unbound_for_test(
        purpose: DirectoryAuthorizationPurpose,
        directory_scope_commitment: &'a str,
    ) -> Self {
        Self {
            purpose,
            expected_directory_scope_commitment: directory_scope_commitment,
            expected_identity: None,
            expected_directory_version: None,
            expected_signed_prekey: None,
            expected_one_time_prekey: None,
            expected_mls_key_package: None,
            expected_exact_claim: None,
        }
    }
}

impl DirectoryAuthorizationPurpose {
    pub fn stable_code(self) -> &'static str {
        match self {
            Self::Pairing => "pairing",
            Self::PairwiseSignedPrekey => "pairwise-signed-prekey",
            Self::PairwiseOneTimePrekey => "pairwise-one-time-prekey",
            Self::PairwiseSessionBootstrap => "pairwise-session-bootstrap",
            Self::IdentityKeyChange => "identity-key-change",
            Self::Revocation => "revocation",
            Self::SelfMonitor => "self-monitor",
            Self::MlsKeyPackage => "mls-key-package",
            Self::MlsMemberAdd => "mls-member-add",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct UntrustedDirectoryResponse {
    pub claim: SecureMeshDirectoryLeafClaim,
    pub inclusion: SecureMeshKtInclusionProof,
    pub latest_map: SecureMeshKtMapProof,
    pub consistency: Option<SecureMeshKtConsistencyProof>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizedDirectoryLeaf {
    claim: SecureMeshDirectoryLeafClaim,
    log_id: String,
    key_id: String,
    signed_tree_head: SecureMeshSignedTreeHead,
    inclusion: SecureMeshKtInclusionProof,
    latest_map: SecureMeshKtMapProof,
    consistency: Option<SecureMeshKtConsistencyProof>,
    freshness: VerifiedKtFreshness,
    purpose: DirectoryAuthorizationPurpose,
    provenance: KtAuthorityProvenance,
    authorization_digest: String,
    transcript_binding_digest: String,
}

impl AuthorizedDirectoryLeaf {
    pub fn claim(&self) -> &SecureMeshDirectoryLeafClaim {
        &self.claim
    }

    pub fn log_id(&self) -> &str {
        &self.log_id
    }

    pub fn key_id(&self) -> &str {
        &self.key_id
    }

    pub fn signed_tree_head(&self) -> &SecureMeshSignedTreeHead {
        &self.signed_tree_head
    }

    pub fn inclusion(&self) -> &SecureMeshKtInclusionProof {
        &self.inclusion
    }

    pub fn latest_map(&self) -> &SecureMeshKtMapProof {
        &self.latest_map
    }

    pub fn consistency(&self) -> Option<&SecureMeshKtConsistencyProof> {
        self.consistency.as_ref()
    }

    pub fn freshness(&self) -> &VerifiedKtFreshness {
        &self.freshness
    }

    pub fn purpose(&self) -> DirectoryAuthorizationPurpose {
        self.purpose
    }

    pub fn provenance(&self) -> &KtAuthorityProvenance {
        &self.provenance
    }

    pub fn authorization_digest(&self) -> &str {
        &self.authorization_digest
    }

    /// Stable digest for binding the authorized directory subject into a peer transcript.
    ///
    /// Unlike `authorization_digest`, this intentionally excludes the verifier's current STH,
    /// consistency path, and observation time. Two clients can therefore bind the same latest
    /// claim while independently verifying fresh, append-consistent views of the pinned log.
    pub fn transcript_binding_digest(&self) -> &str {
        &self.transcript_binding_digest
    }

    pub fn require_purpose(&self, expected: DirectoryAuthorizationPurpose) -> Result<()> {
        ensure!(
            self.purpose == expected,
            "secure mesh directory authorization purpose mismatch"
        );
        Ok(())
    }

    pub fn require_device_identity(&self, identity: &DeviceTrustPublicIdentity) -> Result<()> {
        require_claim_device_identity(&self.claim, identity)
    }

    pub fn require_signed_prekey_digest(&self, digest: &str, version: u64) -> Result<()> {
        validate_digest("signed prekey bundle digest", digest)?;
        ensure!(
            self.claim.key_material.signed_prekey_bundle_digest == digest
                && self.claim.key_material.pairwise_prekey_version == version,
            "secure mesh directory signed prekey commitment mismatch"
        );
        Ok(())
    }

    pub fn require_one_time_prekey_batch_digest(&self, digest: &str, version: u64) -> Result<()> {
        validate_digest("one-time prekey batch digest", digest)?;
        ensure!(
            self.claim.key_material.one_time_prekey_batch_digest == digest
                && self.claim.key_material.pairwise_prekey_version == version,
            "secure mesh directory one-time prekey commitment mismatch"
        );
        Ok(())
    }

    pub fn require_mls_key_package_digest(&self, digest: &str, version: u64) -> Result<()> {
        validate_digest("MLS KeyPackage digest", digest)?;
        ensure!(
            self.claim.key_material.mls_key_package_digest == digest
                && self.claim.key_material.mls_key_package_version == version,
            "secure mesh directory MLS KeyPackage commitment mismatch"
        );
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct UntrustedDirectoryAbsenceResponse {
    pub stable_label: String,
    pub map_root_inclusion: SecureMeshKtInclusionProof,
    pub absence_map: SecureMeshKtMapProof,
    pub consistency: Option<SecureMeshKtConsistencyProof>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizedDirectoryAbsence {
    stable_label: String,
    signed_tree_head: SecureMeshSignedTreeHead,
    map_root_inclusion: SecureMeshKtInclusionProof,
    absence_map: SecureMeshKtMapProof,
    consistency: Option<SecureMeshKtConsistencyProof>,
    freshness: VerifiedKtFreshness,
    provenance: KtAuthorityProvenance,
    authorization_digest: String,
}

impl AuthorizedDirectoryAbsence {
    pub fn stable_label(&self) -> &str {
        &self.stable_label
    }

    pub fn signed_tree_head(&self) -> &SecureMeshSignedTreeHead {
        &self.signed_tree_head
    }

    pub fn absence_map(&self) -> &SecureMeshKtMapProof {
        &self.absence_map
    }

    pub fn map_root_inclusion(&self) -> &SecureMeshKtInclusionProof {
        &self.map_root_inclusion
    }

    pub fn consistency(&self) -> Option<&SecureMeshKtConsistencyProof> {
        self.consistency.as_ref()
    }

    pub fn freshness(&self) -> &VerifiedKtFreshness {
        &self.freshness
    }

    pub fn provenance(&self) -> &KtAuthorityProvenance {
        &self.provenance
    }

    pub fn authorization_digest(&self) -> &str {
        &self.authorization_digest
    }
}

pub struct SecureMeshDirectoryAuthority {
    state: SecureMeshKtClientState,
}

impl SecureMeshDirectoryAuthority {
    pub fn open(
        path: impl AsRef<Path>,
        pin: PinnedKtLogKey,
        freshness_policy: KtFreshnessPolicy,
    ) -> Result<Self> {
        Ok(Self {
            state: SecureMeshKtClientState::open(path, pin, freshness_policy)?,
        })
    }

    pub fn open_in_memory(
        pin: PinnedKtLogKey,
        freshness_policy: KtFreshnessPolicy,
    ) -> Result<Self> {
        Ok(Self {
            state: SecureMeshKtClientState::open_in_memory(pin, freshness_policy)?,
        })
    }

    #[cfg(test)]
    pub(crate) fn observe_response_gossip_for_test(
        &mut self,
        response: &UntrustedDirectoryResponse,
        now_epoch_seconds: u64,
    ) -> Result<()> {
        self.observe_gossip(
            &SecureMeshKtGossipPayload::from_sth(
                response.inclusion.signed_tree_head.clone(),
                response.consistency.clone(),
            ),
            now_epoch_seconds,
        )?;
        Ok(())
    }

    #[cfg(test)]
    pub fn authorize(
        &mut self,
        response: UntrustedDirectoryResponse,
        purpose: DirectoryAuthorizationPurpose,
        now_epoch_seconds: u64,
    ) -> Result<AuthorizedDirectoryLeaf> {
        self.observe_response_gossip_for_test(&response, now_epoch_seconds)?;
        self.authorize_request(
            response.clone(),
            DirectoryAuthorizationRequest::unbound_for_test(
                purpose,
                &response.claim.endpoint.directory_scope_commitment,
            ),
            now_epoch_seconds,
        )
    }

    pub fn authorize_request(
        &mut self,
        response: UntrustedDirectoryResponse,
        request: DirectoryAuthorizationRequest<'_>,
        now_epoch_seconds: u64,
    ) -> Result<AuthorizedDirectoryLeaf> {
        authorize_claim_state(&response.claim, request.purpose)?;
        validate_authorization_request(&response.claim, &request)?;
        let leaf_hash = response.claim.leaf_hash_hex()?;
        let stable_label = response.claim.stable_label();
        let pin = self.state.pin()?.clone();
        let (_, freshness) = self.state.authorize_hashed_directory_view(
            &stable_label,
            request.purpose.stable_code(),
            response.claim.version(),
            response.claim.revoked(),
            &leaf_hash,
            DirectoryComponentCommitments {
                identity_fingerprint: &response.claim.endpoint.fingerprint,
                identity_rotation_epoch: response.claim.endpoint.rotation_epoch,
                identity_key_digest: &response.claim.identity_key_digest(),
                pairwise_prekey_version: response.claim.key_material.pairwise_prekey_version,
                signed_prekey_digest: &response.claim.key_material.signed_prekey_bundle_digest,
                one_time_prekey_digest: &response.claim.key_material.one_time_prekey_batch_digest,
                mls_key_package_version: response.claim.key_material.mls_key_package_version,
                mls_key_package_digest: &response.claim.key_material.mls_key_package_digest,
            },
            &response.inclusion,
            &response.latest_map,
            response.consistency.as_ref(),
            now_epoch_seconds,
        )?;
        let authorization_digest = authorized_leaf_digest(
            &leaf_hash,
            request.purpose,
            &response.inclusion,
            &response.latest_map,
            response.consistency.as_ref(),
            &freshness,
            &pin,
        );
        let transcript_binding_digest =
            authorized_leaf_transcript_binding_digest(&leaf_hash, request.purpose, &pin);
        Ok(AuthorizedDirectoryLeaf {
            claim: response.claim,
            log_id: pin.log_id().to_string(),
            key_id: pin.key_id().to_string(),
            signed_tree_head: response.inclusion.signed_tree_head.clone(),
            inclusion: response.inclusion,
            latest_map: response.latest_map,
            consistency: response.consistency,
            freshness,
            purpose: request.purpose,
            provenance: pin.provenance().clone(),
            authorization_digest,
            transcript_binding_digest,
        })
    }

    pub fn authorize_absence(
        &mut self,
        response: UntrustedDirectoryAbsenceResponse,
        now_epoch_seconds: u64,
    ) -> Result<AuthorizedDirectoryAbsence> {
        let pin = self.state.pin()?.clone();
        let (_, freshness) = self.state.authorize_absence_view(
            &response.stable_label,
            &response.map_root_inclusion,
            &response.absence_map,
            response.consistency.as_ref(),
            now_epoch_seconds,
        )?;
        let authorization_digest = authorized_absence_digest(
            &response.stable_label,
            &response.absence_map,
            response.consistency.as_ref(),
            &freshness,
            &pin,
        );
        Ok(AuthorizedDirectoryAbsence {
            stable_label: response.stable_label,
            signed_tree_head: response.absence_map.signed_tree_head.clone(),
            map_root_inclusion: response.map_root_inclusion,
            absence_map: response.absence_map,
            consistency: response.consistency,
            freshness,
            provenance: pin.provenance().clone(),
            authorization_digest,
        })
    }

    pub fn observe_gossip(
        &mut self,
        gossip: &SecureMeshKtGossipPayload,
        now_epoch_seconds: u64,
    ) -> Result<SecureMeshKtCachedCheckpoint> {
        self.state
            .observe_peer_gossip_sth(gossip, now_epoch_seconds)
    }

    pub fn validate_outgoing_gossip(
        &mut self,
        gossip: &SecureMeshKtGossipPayload,
        now_epoch_seconds: u64,
    ) -> Result<SecureMeshKtCachedCheckpoint> {
        self.state
            .validate_outgoing_gossip_sth(gossip, now_epoch_seconds)
    }

    pub fn latest_checkpoint(&self) -> Result<Option<SecureMeshKtCachedCheckpoint>> {
        self.state.latest_checkpoint()
    }

    pub fn require_current_authorization(
        &mut self,
        stable_label: &str,
        purpose: DirectoryAuthorizationPurpose,
        now_epoch_seconds: u64,
    ) -> Result<SecureMeshKtAuthorizationReceipt> {
        self.state.require_current_directory_authorization(
            stable_label,
            purpose.stable_code(),
            now_epoch_seconds,
        )
    }

    pub fn security_blocked(&self) -> Result<bool> {
        self.state.equivocation_detected()
    }
}

fn authorize_claim_state(
    claim: &SecureMeshDirectoryLeafClaim,
    purpose: DirectoryAuthorizationPurpose,
) -> Result<()> {
    claim.key_material.validate()?;
    let state = claim.endpoint.directory_state.trim().to_ascii_lowercase();
    ensure!(
        matches!(state.as_str(), "active" | "revoked"),
        "secure mesh directory state must be active or revoked and cannot assert local trust"
    );
    match purpose {
        DirectoryAuthorizationPurpose::Revocation => ensure!(
            claim.revoked(),
            "secure mesh directory revocation purpose requires a revoked latest claim"
        ),
        DirectoryAuthorizationPurpose::SelfMonitor => {}
        DirectoryAuthorizationPurpose::IdentityKeyChange => ensure!(
            state == "active",
            "secure mesh directory identity-change claim must be active"
        ),
        _ => ensure!(
            !claim.revoked() && state == "active",
            "secure mesh directory operational authorization requires an active latest claim"
        ),
    }
    Ok(())
}

fn validate_authorization_request(
    claim: &SecureMeshDirectoryLeafClaim,
    request: &DirectoryAuthorizationRequest<'_>,
) -> Result<()> {
    validate_digest(
        "directory scope commitment",
        request.expected_directory_scope_commitment,
    )?;
    ensure!(
        claim.endpoint.directory_scope_commitment == request.expected_directory_scope_commitment,
        "secure mesh directory scope commitment mismatch"
    );
    if let Some(expected) = request.expected_exact_claim {
        ensure!(
            claim == expected,
            "secure mesh directory response does not match the exact locally prepared claim"
        );
    }
    if let Some(identity) = request.expected_identity {
        require_claim_device_identity(claim, identity)?;
    }
    if let Some(version) = request.expected_directory_version {
        ensure!(
            claim.directory_version == version,
            "secure mesh directory publication version mismatch"
        );
    }
    if let Some((digest, version)) = request.expected_signed_prekey {
        validate_digest("signed prekey bundle digest", digest)?;
        ensure!(
            claim.key_material.signed_prekey_bundle_digest == digest
                && claim.key_material.pairwise_prekey_version == version,
            "secure mesh directory signed prekey commitment mismatch"
        );
    }
    if let Some((digest, version)) = request.expected_one_time_prekey {
        validate_digest("one-time prekey batch digest", digest)?;
        ensure!(
            claim.key_material.one_time_prekey_batch_digest == digest
                && claim.key_material.pairwise_prekey_version == version,
            "secure mesh directory one-time prekey commitment mismatch"
        );
    }
    if let Some((digest, version)) = request.expected_mls_key_package {
        validate_digest("MLS KeyPackage digest", digest)?;
        ensure!(
            claim.key_material.mls_key_package_digest == digest
                && claim.key_material.mls_key_package_version == version,
            "secure mesh directory MLS KeyPackage commitment mismatch"
        );
    }
    Ok(())
}

fn require_claim_device_identity(
    claim: &SecureMeshDirectoryLeafClaim,
    identity: &DeviceTrustPublicIdentity,
) -> Result<()> {
    ensure!(
        claim.endpoint.endpoint_id == identity.endpoint_id
            && claim.endpoint.identity_public_key == hex_encode(&identity.identity_public_key)
            && claim.endpoint.signing_public_key == hex_encode(&identity.signing_public_key)
            && claim.endpoint.fingerprint == identity.fingerprint()?,
        "secure mesh directory endpoint identity commitment mismatch"
    );
    Ok(())
}

fn authorized_leaf_digest(
    leaf_hash: &str,
    purpose: DirectoryAuthorizationPurpose,
    inclusion: &SecureMeshKtInclusionProof,
    latest_map: &SecureMeshKtMapProof,
    consistency: Option<&SecureMeshKtConsistencyProof>,
    freshness: &VerifiedKtFreshness,
    pin: &PinnedKtLogKey,
) -> String {
    let mut transcript = Vec::new();
    transcript.extend_from_slice(AUTHORIZED_LEAF_DOMAIN);
    append_len_prefixed(&mut transcript, leaf_hash.as_bytes());
    append_len_prefixed(&mut transcript, purpose.stable_code().as_bytes());
    append_len_prefixed(&mut transcript, pin.log_id().as_bytes());
    append_len_prefixed(&mut transcript, pin.key_id().as_bytes());
    append_len_prefixed(&mut transcript, pin.provenance().stable_code().as_bytes());
    append_proof_evidence(
        &mut transcript,
        inclusion,
        latest_map,
        consistency,
        freshness,
    );
    hex_encode(&Sha256::digest(transcript))
}

fn authorized_leaf_transcript_binding_digest(
    leaf_hash: &str,
    purpose: DirectoryAuthorizationPurpose,
    pin: &PinnedKtLogKey,
) -> String {
    let mut transcript = Vec::new();
    transcript.extend_from_slice(AUTHORIZED_LEAF_TRANSCRIPT_BINDING_DOMAIN);
    append_len_prefixed(&mut transcript, leaf_hash.as_bytes());
    append_len_prefixed(&mut transcript, purpose.stable_code().as_bytes());
    append_len_prefixed(&mut transcript, pin.log_id().as_bytes());
    append_len_prefixed(&mut transcript, pin.key_id().as_bytes());
    append_len_prefixed(&mut transcript, pin.provenance().stable_code().as_bytes());
    hex_encode(&Sha256::digest(transcript))
}

fn authorized_absence_digest(
    stable_label: &str,
    absence_map: &SecureMeshKtMapProof,
    consistency: Option<&SecureMeshKtConsistencyProof>,
    freshness: &VerifiedKtFreshness,
    pin: &PinnedKtLogKey,
) -> String {
    let mut transcript = Vec::new();
    transcript.extend_from_slice(AUTHORIZED_ABSENCE_DOMAIN);
    append_len_prefixed(&mut transcript, stable_label.as_bytes());
    append_len_prefixed(&mut transcript, pin.log_id().as_bytes());
    append_len_prefixed(&mut transcript, pin.key_id().as_bytes());
    append_len_prefixed(&mut transcript, pin.provenance().stable_code().as_bytes());
    append_len_prefixed(
        &mut transcript,
        absence_map.signed_tree_head.root_hash.as_bytes(),
    );
    append_len_prefixed(
        &mut transcript,
        absence_map.signed_tree_head.map_root_hash.as_bytes(),
    );
    transcript.extend_from_slice(&absence_map.signed_tree_head.tree_size.to_be_bytes());
    transcript.extend_from_slice(&freshness.observed_at_epoch_seconds.to_be_bytes());
    if let Some(proof) = consistency {
        transcript.extend_from_slice(&proof.first_tree_size.to_be_bytes());
        transcript.extend_from_slice(&proof.second_tree_size.to_be_bytes());
    }
    hex_encode(&Sha256::digest(transcript))
}

fn append_proof_evidence(
    transcript: &mut Vec<u8>,
    inclusion: &SecureMeshKtInclusionProof,
    latest_map: &SecureMeshKtMapProof,
    consistency: Option<&SecureMeshKtConsistencyProof>,
    freshness: &VerifiedKtFreshness,
) {
    append_len_prefixed(transcript, inclusion.signed_tree_head.root_hash.as_bytes());
    append_len_prefixed(
        transcript,
        inclusion.signed_tree_head.map_root_hash.as_bytes(),
    );
    transcript.extend_from_slice(&inclusion.signed_tree_head.tree_size.to_be_bytes());
    transcript.extend_from_slice(&inclusion.leaf_index.to_be_bytes());
    transcript.extend_from_slice(&(inclusion.siblings.len() as u64).to_be_bytes());
    transcript.extend_from_slice(&(latest_map.siblings.len() as u64).to_be_bytes());
    transcript.extend_from_slice(&freshness.issued_at_epoch_seconds.to_be_bytes());
    if let Some(proof) = consistency {
        transcript.push(1);
        transcript.extend_from_slice(&proof.first_tree_size.to_be_bytes());
        transcript.extend_from_slice(&proof.second_tree_size.to_be_bytes());
        transcript.extend_from_slice(&(proof.path.len() as u64).to_be_bytes());
    } else {
        transcript.push(0);
    }
}

fn validate_digest(label: &str, value: &str) -> Result<()> {
    ensure!(
        value.len() == HASH_HEX_LEN && value.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "secure mesh directory {label} must be a SHA-256 hex digest"
    );
    Ok(())
}

fn parse_digest(value: &str) -> Result<[u8; 32]> {
    validate_digest("digest", value)?;
    let mut bytes = [0u8; 32];
    for (index, chunk) in value.as_bytes().chunks(2).enumerate() {
        let text = std::str::from_utf8(chunk)
            .map_err(|_| anyhow!("secure mesh directory digest is invalid"))?;
        bytes[index] = u8::from_str_radix(text, 16)
            .map_err(|_| anyhow!("secure mesh directory digest is invalid"))?;
    }
    Ok(bytes)
}

fn append_len_prefixed(out: &mut Vec<u8>, value: &[u8]) {
    out.extend_from_slice(&(value.len() as u64).to_be_bytes());
    out.extend_from_slice(value);
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

const _: () = assert!(MAX_DIRECTORY_PROOF_HASHES == 256);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_transparency::{
        KtAuthorityProvenance, SecureMeshKtLog, directory_scope_commitment, stable_directory_label,
    };
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;

    #[test]
    fn typed_authority_carries_identity_pairwise_mls_and_test_provenance() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let claim = claim("device-a", 1, "active", 1);
        let response = append_response(&mut log, &claim, 100, None);
        let mut authority = SecureMeshDirectoryAuthority::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();
        let authorized = authority
            .authorize(response, DirectoryAuthorizationPurpose::Pairing, 100)
            .unwrap();

        assert_eq!(authorized.claim(), &claim);
        assert_eq!(authorized.purpose(), DirectoryAuthorizationPurpose::Pairing);
        assert_eq!(
            authorized.provenance(),
            &KtAuthorityProvenance::LocalAcceptanceMock
        );
        assert_eq!(authorized.inclusion().siblings.len(), 0);
        assert_eq!(authorized.latest_map().siblings.len(), 256);
        assert_eq!(authorized.authorization_digest().len(), 64);
        authorized
            .require_signed_prekey_digest(
                &claim.key_material.signed_prekey_bundle_digest,
                claim.key_material.pairwise_prekey_version,
            )
            .unwrap();
        authorized
            .require_one_time_prekey_batch_digest(
                &claim.key_material.one_time_prekey_batch_digest,
                claim.key_material.pairwise_prekey_version,
            )
            .unwrap();
        authorized
            .require_mls_key_package_digest(
                &claim.key_material.mls_key_package_digest,
                claim.key_material.mls_key_package_version,
            )
            .unwrap();
    }

    #[test]
    fn transcript_binding_is_stable_across_independently_verified_fresh_log_views() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let claim = claim("device-a", 1, "active", 1);
        let first_response = append_response(&mut log, &claim, 100, None);
        let mut authority = SecureMeshDirectoryAuthority::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();
        let first = authority
            .authorize(
                first_response,
                DirectoryAuthorizationPurpose::PairwiseSessionBootstrap,
                100,
            )
            .unwrap();

        let index = log.append_current_map_checkpoint_for_test().unwrap();
        let second_response = current_response(&log, &claim, index, 101, Some(1));
        let second = authority
            .authorize(
                second_response,
                DirectoryAuthorizationPurpose::PairwiseSessionBootstrap,
                101,
            )
            .unwrap();

        assert_eq!(
            first.transcript_binding_digest(),
            second.transcript_binding_digest()
        );
        assert_ne!(first.authorization_digest(), second.authorization_digest());
    }

    #[test]
    fn purpose_receipt_requires_target_label_at_current_sth_and_freshness_after_restart() {
        let path = state_path("purpose-receipt-current-label");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(60, 2).unwrap();
        let target = claim("device-a", 1, "active", 1);
        let target_response = append_response(&mut log, &target, 100, None);
        let mut authority = SecureMeshDirectoryAuthority::open(&path, pin.clone(), policy).unwrap();
        authority
            .authorize(
                target_response,
                DirectoryAuthorizationPurpose::SelfMonitor,
                100,
            )
            .unwrap();
        let receipt = authority
            .require_current_authorization(
                &target.stable_label(),
                DirectoryAuthorizationPurpose::SelfMonitor,
                101,
            )
            .unwrap();
        assert_eq!(receipt.tree_size, 1);
        assert_eq!(receipt.purpose, "self-monitor");

        let other = claim("device-b", 1, "active", 2);
        let other_response = append_response(&mut log, &other, 102, Some(1));
        authority
            .authorize(other_response, DirectoryAuthorizationPurpose::Pairing, 102)
            .unwrap();
        let target_lag = authority
            .require_current_authorization(
                &target.stable_label(),
                DirectoryAuthorizationPurpose::SelfMonitor,
                102,
            )
            .unwrap_err();
        assert!(
            target_lag
                .to_string()
                .contains("purpose-bound authorization is missing")
        );
        drop(authority);

        let mut restored = SecureMeshDirectoryAuthority::open(&path, pin.clone(), policy).unwrap();
        assert!(
            restored
                .require_current_authorization(
                    &target.stable_label(),
                    DirectoryAuthorizationPurpose::SelfMonitor,
                    102,
                )
                .unwrap_err()
                .to_string()
                .contains("purpose-bound authorization is missing")
        );
        let refreshed_target = current_response(&log, &target, 1, 103, None);
        restored
            .authorize(
                refreshed_target,
                DirectoryAuthorizationPurpose::SelfMonitor,
                103,
            )
            .unwrap();
        assert!(
            restored
                .require_current_authorization(
                    &target.stable_label(),
                    DirectoryAuthorizationPurpose::Pairing,
                    103,
                )
                .unwrap_err()
                .to_string()
                .contains("purpose-bound authorization is missing")
        );
        let latest_receipt = restored
            .require_current_authorization(
                &target.stable_label(),
                DirectoryAuthorizationPurpose::SelfMonitor,
                160,
            )
            .unwrap();
        assert_eq!(latest_receipt.validated_at_epoch_seconds, 160);
        assert!(
            restored
                .require_current_authorization(
                    &target.stable_label(),
                    DirectoryAuthorizationPurpose::SelfMonitor,
                    164,
                )
                .unwrap_err()
                .to_string()
                .contains("authenticated_sth_expired")
        );
        drop(restored);
        let mut clock_rolled_back = SecureMeshDirectoryAuthority::open(&path, pin, policy).unwrap();
        let blocked = clock_rolled_back
            .require_current_authorization(
                &target.stable_label(),
                DirectoryAuthorizationPurpose::SelfMonitor,
                101,
            )
            .unwrap_err()
            .to_string();
        assert!(blocked.contains("previously persisted"));
        assert!(clock_rolled_back.security_blocked().unwrap());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn typed_authority_rejects_commitment_tamper_and_map_log_mismatch() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let original = claim("device-a", 1, "active", 1);
        let original_response = append_response(&mut log, &original, 100, None);

        let mut tampered_response = original_response.clone();
        tampered_response.claim.key_material.mls_key_package_digest = digest(99);
        let mut tamper_authority = SecureMeshDirectoryAuthority::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();
        let tamper = tamper_authority
            .authorize(
                tampered_response,
                DirectoryAuthorizationPurpose::MlsMemberAdd,
                100,
            )
            .unwrap_err();
        assert!(tamper.to_string().contains("sparse-map leaf is not latest"));

        let old_map = original_response.latest_map;
        let other = claim("device-b", 1, "active", 2);
        log.append_hashed_directory_leaf(
            &other.stable_label(),
            other.version(),
            other.revoked(),
            other.leaf_hash().unwrap(),
        )
        .unwrap();
        let mixed = UntrustedDirectoryResponse {
            claim: original.clone(),
            inclusion: log.inclusion_proof_at(1, 101).unwrap(),
            latest_map: old_map,
            consistency: None,
        };
        let mut mixed_authority = SecureMeshDirectoryAuthority::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();
        let mismatch = mixed_authority
            .authorize(mixed, DirectoryAuthorizationPurpose::Pairing, 101)
            .unwrap_err();
        assert!(
            mismatch
                .to_string()
                .contains("do not share one signed tree head")
        );
    }

    #[test]
    fn request_mismatch_does_not_advance_or_poison_persistent_authority_state() {
        let path = state_path("request-mismatch-atomic");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(120, 2).unwrap();
        let malicious = claim("device-a", 1, "active", 9);
        let expected = claim("device-a", 1, "active", 1);
        let malicious_response = append_response(&mut log, &malicious, 100, None);
        let mut authority = SecureMeshDirectoryAuthority::open(&path, pin.clone(), policy).unwrap();
        let error = authority
            .authorize_request(
                malicious_response,
                DirectoryAuthorizationRequest::for_exact_claim(
                    DirectoryAuthorizationPurpose::SelfMonitor,
                    &expected.endpoint.directory_scope_commitment,
                    &expected,
                ),
                100,
            )
            .unwrap_err();
        assert!(error.to_string().contains("exact locally prepared claim"));
        assert!(authority.latest_checkpoint().unwrap().is_none());
        assert!(!authority.security_blocked().unwrap());
        drop(authority);

        let mut corrected = expected;
        corrected.directory_version = 2;
        corrected.endpoint.rotation_epoch = 2;
        let corrected_response = append_response(&mut log, &corrected, 101, None);
        let mut restored = SecureMeshDirectoryAuthority::open(&path, pin, policy).unwrap();
        restored
            .observe_gossip(
                &SecureMeshKtGossipPayload::from_sth(
                    corrected_response.inclusion.signed_tree_head.clone(),
                    corrected_response.consistency.clone(),
                ),
                101,
            )
            .unwrap();
        restored
            .authorize_request(
                corrected_response,
                DirectoryAuthorizationRequest::for_exact_claim(
                    DirectoryAuthorizationPurpose::SelfMonitor,
                    &corrected.endpoint.directory_scope_commitment,
                    &corrected,
                ),
                101,
            )
            .unwrap();
        assert_eq!(restored.latest_checkpoint().unwrap().unwrap().tree_size, 2);
        assert!(!restored.security_blocked().unwrap());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn typed_request_rejects_foreign_scope_under_the_same_pinned_log() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let published = claim("device-scope", 1, "active", 11);
        let response = append_response(&mut log, &published, 100, None);
        let foreign_scope =
            directory_scope_commitment("tenant-a", "account-a", "workspace-foreign");
        let request = DirectoryAuthorizationRequest {
            purpose: DirectoryAuthorizationPurpose::Pairing,
            expected_directory_scope_commitment: &foreign_scope,
            expected_identity: None,
            expected_directory_version: Some(published.directory_version),
            expected_signed_prekey: None,
            expected_one_time_prekey: None,
            expected_mls_key_package: None,
            expected_exact_claim: None,
        };
        let mut authority = SecureMeshDirectoryAuthority::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();

        let error = authority
            .authorize_request(response, request, 100)
            .unwrap_err()
            .to_string();
        assert!(error.contains("scope commitment mismatch"));
        assert!(authority.latest_checkpoint().unwrap().is_none());
        assert!(!authority.security_blocked().unwrap());
    }

    #[test]
    fn full_subject_request_rejects_mls_key_package_substitution_before_state_advance() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let published = claim("device-mls-package", 1, "active", 12);
        let response = append_response(&mut log, &published, 100, None);
        let substituted_digest = digest(99);
        let request = DirectoryAuthorizationRequest {
            purpose: DirectoryAuthorizationPurpose::SelfMonitor,
            expected_directory_scope_commitment: &published.endpoint.directory_scope_commitment,
            expected_identity: None,
            expected_directory_version: Some(published.directory_version),
            expected_signed_prekey: None,
            expected_one_time_prekey: None,
            expected_mls_key_package: Some((
                &substituted_digest,
                published.key_material.mls_key_package_version,
            )),
            expected_exact_claim: None,
        };
        let mut authority = SecureMeshDirectoryAuthority::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();

        let error = authority
            .authorize_request(response, request, 100)
            .unwrap_err()
            .to_string();
        assert!(error.contains("MLS KeyPackage commitment mismatch"));
        assert!(authority.latest_checkpoint().unwrap().is_none());
        assert!(!authority.security_blocked().unwrap());
    }

    #[test]
    fn latest_version_requires_consistency_and_revoked_resurrection_blocks_after_restart() {
        let path = state_path("latest-revoke");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(120, 2).unwrap();
        let first = claim("device-a", 1, "active", 1);
        let first_response = append_response(&mut log, &first, 100, None);
        let mut authority = SecureMeshDirectoryAuthority::open(&path, pin.clone(), policy).unwrap();
        authority
            .authorize(
                first_response,
                DirectoryAuthorizationPurpose::PairwiseSignedPrekey,
                100,
            )
            .unwrap();

        let second = claim("device-a", 2, "active", 2);
        let missing_consistency = append_response(&mut log, &second, 101, None);
        let error = authority
            .authorize(
                missing_consistency,
                DirectoryAuthorizationPurpose::MlsKeyPackage,
                101,
            )
            .unwrap_err();
        assert!(error.to_string().contains("consistency proof is required"));
        let second_response = current_response(&log, &second, 1, 101, Some(1));
        authority
            .authorize(
                second_response,
                DirectoryAuthorizationPurpose::MlsKeyPackage,
                101,
            )
            .unwrap();

        let revoked = claim("device-a", 3, "revoked", 3);
        let revoked_response = append_response(&mut log, &revoked, 102, Some(2));
        authority
            .authorize(
                revoked_response,
                DirectoryAuthorizationPurpose::Revocation,
                102,
            )
            .unwrap();

        let resurrected = claim("device-a", 4, "active", 4);
        let index = log
            .force_append_hashed_directory_leaf_for_adversarial_test(
                &resurrected.stable_label(),
                resurrected.version(),
                resurrected.revoked(),
                resurrected.leaf_hash().unwrap(),
            )
            .unwrap();
        let resurrection_response = current_response(&log, &resurrected, index, 103, Some(3));
        let error = authority
            .authorize(
                resurrection_response,
                DirectoryAuthorizationPurpose::Pairing,
                103,
            )
            .unwrap_err();
        assert!(error.to_string().contains("revoked identity resurrection"));
        drop(authority);

        let restored = SecureMeshDirectoryAuthority::open(&path, pin, policy).unwrap();
        assert!(restored.security_blocked().unwrap());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn authenticated_absence_is_typed_and_bound_to_requested_label() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let scope = directory_scope_commitment("tenant-a", "account-a", "workspace-a");
        let missing = stable_directory_label(&scope, "missing");
        let map_root_index = log.append_empty_map_checkpoint_for_test().unwrap();
        let response = UntrustedDirectoryAbsenceResponse {
            stable_label: missing.clone(),
            map_root_inclusion: log.inclusion_proof_at(map_root_index, 100).unwrap(),
            absence_map: log.map_proof_at(&missing, 100).unwrap(),
            consistency: None,
        };
        let mut authority = SecureMeshDirectoryAuthority::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();
        authority
            .observe_gossip(
                &SecureMeshKtGossipPayload::from_sth(
                    response.map_root_inclusion.signed_tree_head.clone(),
                    response.consistency.clone(),
                ),
                100,
            )
            .unwrap();
        let authorized = authority.authorize_absence(response, 100).unwrap();
        assert_eq!(authorized.stable_label(), missing);
        assert_eq!(authorized.absence_map().siblings.len(), 256);
        assert_eq!(authorized.authorization_digest().len(), 64);
        assert_eq!(
            authorized.provenance(),
            &KtAuthorityProvenance::LocalAcceptanceMock
        );
    }

    #[test]
    fn directory_authorization_requires_persisted_fresh_peer_gossip() {
        let path = state_path("fresh-peer-gossip-required");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(3_600, 2).unwrap();
        let published = claim("device-gossip", 1, "active", 7);
        let response = append_response(&mut log, &published, 100, None);
        let request = DirectoryAuthorizationRequest::for_exact_claim(
            DirectoryAuthorizationPurpose::SelfMonitor,
            &published.endpoint.directory_scope_commitment,
            &published,
        );
        let mut authority = SecureMeshDirectoryAuthority::open(&path, pin.clone(), policy).unwrap();
        let missing = authority
            .authorize_request(response.clone(), request.clone(), 100)
            .unwrap_err();
        assert!(missing.to_string().contains("peer-gossip or witness"));
        authority
            .observe_gossip(
                &SecureMeshKtGossipPayload::from_sth(
                    response.inclusion.signed_tree_head.clone(),
                    response.consistency.clone(),
                ),
                100,
            )
            .unwrap();
        authority.authorize_request(response, request, 100).unwrap();
        drop(authority);

        let mut restored = SecureMeshDirectoryAuthority::open(&path, pin, policy).unwrap();
        restored
            .require_current_authorization(
                &published.stable_label(),
                DirectoryAuthorizationPurpose::SelfMonitor,
                101,
            )
            .unwrap();
        let stale = restored
            .require_current_authorization(
                &published.stable_label(),
                DirectoryAuthorizationPurpose::SelfMonitor,
                1_001,
            )
            .unwrap_err();
        assert!(
            stale
                .to_string()
                .contains("peer-gossip or witness observation is stale")
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn independently_consistent_clients_persist_split_view_on_cross_gossip() {
        let signing_key = SigningKey::generate(&mut OsRng);
        let mut first_log = SecureMeshKtLog::with_identity(
            signing_key.clone(),
            "split-gossip-log",
            "split-gossip-key",
        );
        let mut second_log =
            SecureMeshKtLog::with_identity(signing_key, "split-gossip-log", "split-gossip-key");
        let first_claim = claim("device-split-a", 1, "active", 1);
        let second_claim = claim("device-split-b", 1, "active", 2);
        let first_response = append_response(&mut first_log, &first_claim, 100, None);
        let second_response = append_response(&mut second_log, &second_claim, 100, None);
        let policy = KtFreshnessPolicy::strict(3_600, 2).unwrap();
        let mut first_client =
            SecureMeshDirectoryAuthority::open_in_memory(first_log.pin(), policy).unwrap();
        let mut second_client =
            SecureMeshDirectoryAuthority::open_in_memory(second_log.pin(), policy).unwrap();
        first_client
            .authorize(
                first_response,
                DirectoryAuthorizationPurpose::SelfMonitor,
                100,
            )
            .unwrap();
        second_client
            .authorize(
                second_response.clone(),
                DirectoryAuthorizationPurpose::SelfMonitor,
                100,
            )
            .unwrap();

        let split = first_client
            .observe_gossip(
                &SecureMeshKtGossipPayload::from_sth(
                    second_response.inclusion.signed_tree_head,
                    None,
                ),
                101,
            )
            .unwrap_err();
        assert!(split.to_string().contains("same-size split view"));
        assert!(first_client.security_blocked().unwrap());
    }

    #[test]
    fn directory_active_state_cannot_substitute_for_local_device_trust() {
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let attacker_claim = claim("device-a", 1, "active", 9);
        let response = append_response(&mut log, &attacker_claim, 100, None);
        let mut authority = SecureMeshDirectoryAuthority::open_in_memory(
            log.pin(),
            KtFreshnessPolicy::strict(60, 2).unwrap(),
        )
        .unwrap();
        let directory_leaf = authority
            .authorize(response, DirectoryAuthorizationPurpose::Pairing, 100)
            .unwrap();
        let locally_trusted_identity =
            DeviceTrustPublicIdentity::new("device-a", [1u8; 32], [2u8; 32], 1).unwrap();
        let error = directory_leaf
            .require_device_identity(&locally_trusted_identity)
            .unwrap_err();
        assert!(error.to_string().contains("identity commitment mismatch"));
    }

    #[test]
    fn directory_versions_reject_cross_language_unsafe_json_integers() {
        let mut unsafe_claim = claim("device-a", 1, "active", 1);
        unsafe_claim.directory_version = KT_JSON_SAFE_INTEGER_MAX + 1;
        assert!(
            unsafe_claim
                .leaf_hash()
                .unwrap_err()
                .to_string()
                .contains("cross-language safe range")
        );
        unsafe_claim.directory_version = 1;
        unsafe_claim.key_material.mls_key_package_version = KT_JSON_SAFE_INTEGER_MAX + 1;
        assert!(
            unsafe_claim
                .leaf_hash()
                .unwrap_err()
                .to_string()
                .contains("cross-language safe range")
        );
    }

    #[test]
    fn component_versions_and_same_version_digests_are_monotonic_across_restart() {
        let first = claim("device-a", 1, "active", 1);

        let mut pairwise_rollback = claim("device-a", 2, "active", 2);
        pairwise_rollback.key_material.pairwise_prekey_version = 0;
        assert_component_violation(
            first.clone(),
            pairwise_rollback,
            "Pairwise prekey version rollback",
            "pairwise-rollback",
        );

        let mut pairwise_split = claim("device-a", 2, "active", 2);
        pairwise_split.key_material.pairwise_prekey_version = 1;
        assert_component_violation(
            first.clone(),
            pairwise_split,
            "Pairwise prekey same-version split view",
            "pairwise-split",
        );

        let mut mls_rollback = claim("device-a", 2, "active", 2);
        mls_rollback.key_material.mls_key_package_version = 0;
        assert_component_violation(
            first.clone(),
            mls_rollback,
            "MLS KeyPackage version rollback",
            "mls-rollback",
        );

        let mut mls_split = claim("device-a", 2, "active", 2);
        mls_split.key_material.mls_key_package_version = 1;
        assert_component_violation(
            first,
            mls_split,
            "MLS KeyPackage same-version split view",
            "mls-split",
        );
    }

    #[test]
    fn identity_rotation_is_monotonic_and_prekey_only_updates_keep_the_same_epoch() {
        let first = claim("device-a", 1, "active", 1);

        let mut same_epoch_key_change = claim("device-a", 2, "active", 2);
        same_epoch_key_change.endpoint.rotation_epoch = 1;
        assert_component_violation(
            first.clone(),
            same_epoch_key_change,
            "identity key changed without strict rotation epoch advance",
            "identity-same-epoch-key-change",
        );

        let mut unchanged_key_epoch_change = first.clone();
        unchanged_key_epoch_change.directory_version = 2;
        unchanged_key_epoch_change.endpoint.rotation_epoch = 2;
        unchanged_key_epoch_change
            .key_material
            .pairwise_prekey_version = 2;
        unchanged_key_epoch_change
            .key_material
            .signed_prekey_bundle_digest = digest(7);
        unchanged_key_epoch_change
            .key_material
            .one_time_prekey_batch_digest = digest(8);
        assert_component_violation(
            first.clone(),
            unchanged_key_epoch_change,
            "identity epoch changed without identity material change",
            "identity-epoch-without-key-change",
        );

        let mut prekey_only = first.clone();
        prekey_only.directory_version = 2;
        prekey_only.key_material.pairwise_prekey_version = 2;
        prekey_only.key_material.signed_prekey_bundle_digest = digest(7);
        prekey_only.key_material.one_time_prekey_batch_digest = digest(8);
        let path = state_path("identity-prekey-only");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(120, 2).unwrap();
        let first_response = append_response(&mut log, &first, 100, None);
        let mut authority = SecureMeshDirectoryAuthority::open(&path, pin.clone(), policy).unwrap();
        authority
            .authorize(
                first_response,
                DirectoryAuthorizationPurpose::SelfMonitor,
                100,
            )
            .unwrap();
        let next_response = append_response(&mut log, &prekey_only, 101, Some(1));
        authority
            .authorize(
                next_response,
                DirectoryAuthorizationPurpose::PairwiseSignedPrekey,
                101,
            )
            .unwrap();
        drop(authority);
        let restored = SecureMeshDirectoryAuthority::open(&path, pin, policy).unwrap();
        assert!(!restored.security_blocked().unwrap());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn previously_present_label_cannot_become_absent_across_restart() {
        let path = state_path("present-to-absent");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(120, 2).unwrap();
        let present = claim("device-a", 1, "active", 1);
        let present_response = append_response(&mut log, &present, 100, None);
        let mut authority = SecureMeshDirectoryAuthority::open(&path, pin.clone(), policy).unwrap();
        authority
            .authorize(
                present_response,
                DirectoryAuthorizationPurpose::SelfMonitor,
                100,
            )
            .unwrap();

        let map_root_index = log
            .force_remove_map_label_for_adversarial_test(&present.stable_label())
            .unwrap();
        let absence = UntrustedDirectoryAbsenceResponse {
            stable_label: present.stable_label(),
            map_root_inclusion: log.inclusion_proof_at(map_root_index, 101).unwrap(),
            absence_map: log.map_proof_at(&present.stable_label(), 101).unwrap(),
            consistency: Some(log.consistency_proof_at(1, 101).unwrap()),
        };
        authority
            .observe_gossip(
                &SecureMeshKtGossipPayload::from_sth(
                    absence.map_root_inclusion.signed_tree_head.clone(),
                    absence.consistency.clone(),
                ),
                101,
            )
            .unwrap();
        let error = authority.authorize_absence(absence, 101).unwrap_err();
        assert!(error.to_string().contains("previously present"));
        drop(authority);
        let restored = SecureMeshDirectoryAuthority::open(&path, pin, policy).unwrap();
        assert!(restored.security_blocked().unwrap());
        let _ = std::fs::remove_file(path);
    }

    fn append_response(
        log: &mut SecureMeshKtLog,
        claim: &SecureMeshDirectoryLeafClaim,
        issued_at: u64,
        first_size: Option<u64>,
    ) -> UntrustedDirectoryResponse {
        let index = log
            .append_hashed_directory_leaf(
                &claim.stable_label(),
                claim.version(),
                claim.revoked(),
                claim.leaf_hash().unwrap(),
            )
            .unwrap();
        current_response(log, claim, index, issued_at, first_size)
    }

    fn assert_component_violation(
        first: SecureMeshDirectoryLeafClaim,
        second: SecureMeshDirectoryLeafClaim,
        expected: &str,
        label: &str,
    ) {
        let path = state_path(label);
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pin = log.pin();
        let policy = KtFreshnessPolicy::strict(120, 2).unwrap();
        let first_response = append_response(&mut log, &first, 100, None);
        let mut authority = SecureMeshDirectoryAuthority::open(&path, pin.clone(), policy).unwrap();
        authority
            .authorize(
                first_response,
                DirectoryAuthorizationPurpose::SelfMonitor,
                100,
            )
            .unwrap();
        let second_response = append_response(&mut log, &second, 101, Some(1));
        let error = authority
            .authorize(
                second_response,
                DirectoryAuthorizationPurpose::SelfMonitor,
                101,
            )
            .unwrap_err();
        assert!(error.to_string().contains(expected), "{error}");
        drop(authority);
        let restored = SecureMeshDirectoryAuthority::open(&path, pin, policy).unwrap();
        assert!(restored.security_blocked().unwrap());
        let _ = std::fs::remove_file(path);
    }

    fn current_response(
        log: &SecureMeshKtLog,
        claim: &SecureMeshDirectoryLeafClaim,
        index: u64,
        issued_at: u64,
        first_size: Option<u64>,
    ) -> UntrustedDirectoryResponse {
        UntrustedDirectoryResponse {
            claim: claim.clone(),
            inclusion: log.inclusion_proof_at(index, issued_at).unwrap(),
            latest_map: log.map_proof_at(&claim.stable_label(), issued_at).unwrap(),
            consistency: first_size
                .map(|first| log.consistency_proof_at(first, issued_at).unwrap()),
        }
    }

    fn claim(
        endpoint_id: &str,
        version: u64,
        directory_state: &str,
        seed: u8,
    ) -> SecureMeshDirectoryLeafClaim {
        SecureMeshDirectoryLeafClaim {
            endpoint: SecureMeshTransparencyLeafBody {
                directory_scope_commitment: directory_scope_commitment(
                    "tenant-a",
                    "account-a",
                    "workspace-a",
                ),
                endpoint_id: endpoint_id.to_string(),
                endpoint_kind: "test".to_string(),
                identity_public_key: format!("{endpoint_id}-identity-{seed}"),
                signing_public_key: format!("{endpoint_id}-signing-{seed}"),
                fingerprint: format!("{endpoint_id}-fingerprint-{seed}"),
                rotation_epoch: version,
                directory_state: directory_state.to_string(),
                updated_at: "2026-07-12T00:00:00Z".to_string(),
            },
            key_material: SecureMeshDirectoryKeyMaterialCommitment {
                signed_prekey_bundle_digest: digest(seed),
                one_time_prekey_batch_digest: digest(seed.wrapping_add(1)),
                pairwise_prekey_version: version,
                mls_key_package_digest: digest(seed.wrapping_add(2)),
                mls_key_package_version: version,
            },
            directory_version: version,
        }
    }

    fn digest(seed: u8) -> String {
        hex_encode(&[seed; 32])
    }

    fn state_path(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "lico-directory-{label}-{}-{}.sqlite3",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }
}
