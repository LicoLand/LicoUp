use std::collections::BTreeMap;
use std::sync::Arc;

use anyhow::{Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::SigningKey;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

use crate::core::secure_mesh_capability_proof::SignedCapabilityProof;
use crate::core::secure_mesh_crypto::{
    SecureMeshContentContext, SecureMeshPayloadKind, SecureMeshPlaintext,
};
use crate::core::secure_mesh_directory::{
    AuthorizedDirectoryLeaf, DirectoryAuthorizationPurpose, DirectoryAuthorizationRequest,
    SecureMeshDirectoryAuthority, SecureMeshKtVerifierConfiguration, UntrustedDirectoryResponse,
};
use crate::core::secure_mesh_mls::{
    SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION, SECURE_MESH_MLS_CIPHER_SUITE, SecureMeshMlsGroup,
    SecureMeshMlsKeyPackage, SecureMeshMlsParticipant,
};
use crate::core::secure_mesh_mls_product::{
    SECURE_MESH_MLS_PRODUCT_POLICY_STATUS, SecureMeshMlsExpectedInvitation,
    SecureMeshMlsOperationRecord, SecureMeshMlsOperationState, SecureMeshMlsSecurityLedger,
    add_product_member_prepared, create_product_group, cross_check_roster,
    directory_roster_from_group, join_product_group_from_welcome_prepared,
    open_product_payload_message, participant_from_device_identity,
    process_product_commit_prepared, remove_product_member_prepared, require_verified_member_trust,
    seal_product_payload_message, sign_mls_keypackage_capability_proof,
};
use crate::core::secure_mesh_transparency::{
    KtFreshnessPolicy, SecureMeshKtAuthorizationReceipt, stable_directory_label,
};
use crate::core::secure_mesh_trust::{DeviceTrustPublicIdentity, DeviceTrustState};
use crate::platform::secure_mesh_secret_store::{
    SecretStoreAuthorizationSession, SecretStoreHandle, SecureMeshSecretStore,
};

pub const SECURE_MESH_MLS_NATIVE_ACTIONS: &[&str] = &[
    "secure_mesh.mls.status",
    "secure_mesh.mls.participant.ensure",
    "secure_mesh.mls.keyPackage.create",
    "secure_mesh.mls.group.create",
    "secure_mesh.mls.member.add",
    "secure_mesh.mls.member.remove",
    "secure_mesh.mls.group.join",
    "secure_mesh.mls.commit.process",
    "secure_mesh.mls.payload.seal",
    "secure_mesh.mls.payload.open",
];

/// Pure wiring probe for process-startup and mobile FFI health checks.
///
/// Product readiness belongs to [`status`], which intentionally evaluates the
/// persisted relay and transparency state. Runtime loading probes must remain
/// side-effect free so they cannot create client state beside an executable or
/// mutate an installed application bundle.
pub fn runtime_binding_wired() -> bool {
    crate::core::secure_mesh_mls::SECURE_MESH_MLS_STATUS.contains("mlkem1024_epoch_hybrid_payload")
        && crate::core::secure_mesh_mls::runtime_crypto_self_test()
        && SECURE_MESH_MLS_PRODUCT_POLICY_STATUS.contains("cryptographic_native_path_wired")
        && SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION.starts_with("licolite.secure-mesh.group-mls.")
        && SECURE_MESH_MLS_CIPHER_SUITE.starts_with("MLS_")
        && SECURE_MESH_MLS_NATIVE_ACTIONS.len() >= 10
}

const MAX_GROUP_ID_BYTES: usize = 255;
const MAX_KEY_PACKAGE_BYTES: usize = 256 * 1024;
const MAX_MLS_MESSAGE_BYTES: usize = 20 * 1024 * 1024;
const MAX_PAYLOAD_BYTES: usize = 16 * 1024 * 1024;
const MLS_PARTICIPANT_SNAPSHOT_KEY_PREFIX: &str = "secureMeshMlsParticipantMlKem1024_";

pub fn dispatch(action: &str, params: &Value) -> Result<Value> {
    if action != "secure_mesh.mls.status" {
        crate::domain::mobile_relay::ensure_secure_mesh_protected_operation_allowed()?;
    }
    match action {
        "secure_mesh.mls.status" => status(),
        "secure_mesh.mls.participant.ensure" => participant_ensure(params),
        "secure_mesh.mls.keyPackage.create" => key_package_create(params),
        "secure_mesh.mls.group.create" => group_create(params),
        "secure_mesh.mls.member.add" => member_add(params),
        "secure_mesh.mls.member.remove" => member_remove(params),
        "secure_mesh.mls.group.join" => group_join(params),
        "secure_mesh.mls.commit.process" => commit_process(params),
        "secure_mesh.mls.payload.seal" => payload_seal(params),
        "secure_mesh.mls.payload.open" => payload_open(params),
        _ => Err(anyhow!("secure mesh MLS native action is unsupported")),
    }
}

pub fn status() -> Result<Value> {
    let evaluation = crate::domain::mobile_relay::selected_mobile_relay_capability_evaluation()?;
    let directory_readiness = (|| {
        let (config, identity) =
            crate::domain::mobile_relay::secure_mesh_mls_public_directory_context()?;
        let roster = BTreeMap::from([(identity.endpoint_id.clone(), identity.clone())]);
        require_mls_directory_authority(&config, &identity, &roster)
    })();
    let current_directory_receipts = directory_readiness.is_ok();
    let mut blockers = vec!["physical_multi_client_matrix_pending"];
    if !current_directory_receipts {
        blockers.push("current_key_transparency_receipts_unavailable");
    }
    let directory_status = directory_readiness
        .ok()
        .map(|readiness| {
            json!({
                "current": true,
                "treeSize": readiness.tree_size,
                "receiptCount": readiness.receipt_count,
                "rootCommitted": !readiness.root_hash.is_empty(),
                "mapRootCommitted": !readiness.map_root_hash.is_empty(),
            })
        })
        .unwrap_or_else(|| {
            json!({
                "current": false,
                "treeSize": Value::Null,
                "receiptCount": 0,
                "rootCommitted": false,
                "mapRootCommitted": false,
            })
        });
    Ok(json!({
        "ok": true,
        "protocolVersion": SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION,
        "cipherSuite": SECURE_MESH_MLS_CIPHER_SUITE,
        "openMlsControlPlaneCipherSuite": "MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519",
        "mlKem1024EpochContributionReady": true,
        "hybridPayloadKeyDerivationReady": true,
        "activeGroupRequiresMlKem1024Epoch": true,
        "legacySessionMigration": "re_pair_or_rekey_required",
        "productPolicyStatus": SECURE_MESH_MLS_PRODUCT_POLICY_STATUS,
        "cryptographicRuntimeWired": true,
        "nativeActionPathWired": true,
        "localPersistedPairTrustGateWired": true,
        "authorizedDirectoryLeafKtAuthorityWired": true,
        "currentDirectoryReceiptGateWired": true,
        "currentDirectoryReceipts": directory_status,
        "clientProductCallSiteAvailable": false,
        "productionPathAvailable": false,
        "productionReady": false,
        "blockers": blockers,
        "selectedCustody": evaluation.custody(),
        "actions": SECURE_MESH_MLS_NATIVE_ACTIONS,
        "rawProoflessApiExposed": false,
        "privateKeyMaterial": "redacted"
    }))
}

fn participant_ensure(params: &Value) -> Result<Value> {
    with_local_participant(params, ParticipantRequirement::CreateIfMissing, |runtime| {
        Ok((
            json!({
                "ok": true,
                "participant": public_local_participant(runtime.identity, runtime.participant)?,
                "custodyBackend": runtime.secret_store.backend(),
                "privateKeyMaterial": "redacted"
            }),
            true,
        ))
    })
}

fn key_package_create(params: &Value) -> Result<Value> {
    with_local_participant(params, ParticipantRequirement::CreateIfMissing, |runtime| {
        let key_package = runtime.participant.generate_key_package()?;
        let now = OffsetDateTime::now_utc();
        let capability_evaluation = runtime.secret_store.capability_evaluation()?;
        let proof = sign_mls_keypackage_capability_proof(
            runtime.identity,
            runtime.signing_key,
            &capability_evaluation,
            &key_package,
            now,
        )?;
        let key_package_id = hex_sha256(key_package.as_public_bytes());
        let previous_version = runtime
            .config
            .get("mobileRelayE2ee")
            .and_then(|state| state.get("mlsKeyPackageVersion"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let key_package_version = previous_version
            .checked_add(1)
            .ok_or_else(|| anyhow!("secure mesh MLS KeyPackage version overflow"))?;
        ensure!(
            key_package_version <= crate::core::secure_mesh_transparency::KT_JSON_SAFE_INTEGER_MAX,
            "secure mesh MLS KeyPackage version exceeds the cross-language safe range"
        );
        runtime.config["mobileRelayE2ee"]["mlsKeyPackageVersion"] = json!(key_package_version);
        runtime.config["mobileRelayE2ee"]["mlsKeyPackageDigest"] = json!(&key_package_id);
        #[cfg(test)]
        crate::domain::mobile_relay::refresh_secure_mesh_mls_test_directory_authority(
            runtime.config,
        )?;
        Ok((
            json!({
                "ok": true,
                "protocolVersion": SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION,
                "keyPackageId": key_package_id,
                "keyPackageBase64url": encode_base64url(key_package.as_public_bytes()),
                "keyPackageVersion": key_package_version,
                "capabilityProof": proof,
                "identity": identity_to_json(runtime.identity),
                "createdAtUnixSeconds": now.unix_timestamp(),
                "privateKeyMaterial": "redacted",
                "directoryPublicationRequired": true
            }),
            true,
        ))
    })
}

fn group_create(params: &Value) -> Result<Value> {
    let request: GroupCreateRequest = parse_params(params)?;
    let group_id = decode_base64url(
        &request.group_id_base64url,
        "MLS group id",
        MAX_GROUP_ID_BYTES,
    )?;
    with_local_participant(params, ParticipantRequirement::CreateIfMissing, |runtime| {
        let local_roster = BTreeMap::from([(
            runtime.identity.endpoint_id.clone(),
            runtime.identity.clone(),
        )]);
        let directory_readiness =
            require_mls_directory_authority(runtime.config, runtime.identity, &local_roster)?;
        let group = match SecureMeshMlsGroup::load_optional(runtime.participant, &group_id)? {
            Some(group) => group,
            None => create_product_group(
                runtime.participant,
                runtime.identity,
                &DeviceTrustState::Verified,
                &group_id,
            )?,
        };
        runtime.persist_participant()?;
        let metadata = reconcile_group_metadata(&group, runtime.identity)?;
        let mut response = group_status_json(&group, &metadata);
        response["directoryAuthority"] = json!({
            "current": true,
            "treeSize": directory_readiness.tree_size,
            "receiptCount": directory_readiness.receipt_count,
            "rootCommitted": !directory_readiness.root_hash.is_empty(),
            "mapRootCommitted": !directory_readiness.map_root_hash.is_empty(),
        });
        Ok((response, false))
    })
}

fn member_add(params: &Value) -> Result<Value> {
    reject_caller_asserted_trust(params)?;
    let request: MemberAddRequest = parse_params(params)?;
    let group_id = decode_base64url(
        &request.group_id_base64url,
        "MLS group id",
        MAX_GROUP_ID_BYTES,
    )?;
    let key_package_bytes = decode_base64url(
        &request.member_key_package_base64url,
        "MLS key package",
        MAX_KEY_PACKAGE_BYTES,
    )?;
    ensure!(
        request.member_key_package_id == hex_sha256(&key_package_bytes),
        "secure mesh MLS key package id is not canonically bound to the package"
    );
    let member_key_package = SecureMeshMlsKeyPackage::from_public_bytes(&key_package_bytes)?;
    let member_identity = request.member_identity.to_identity()?;
    with_local_participant(params, ParticipantRequirement::Required, |runtime| {
        ensure!(
            member_identity != *runtime.identity,
            "secure mesh MLS cannot add the local identity as a remote member"
        );
        let member_trust_state = runtime.authoritative_trust_state(&member_identity)?;
        let mut group = load_group_for_journal(runtime.participant, runtime.identity, &group_id)?;
        let current_roster = directory_roster_from_group(&group)?;
        require_mls_directory_authority(runtime.config, runtime.identity, &current_roster)?;
        let mut security_ledger = open_security_ledger()?;
        let (operation_id, request_digest) =
            journal_operation_identity("secure_mesh.mls.member.add", &request, runtime.identity)?;
        let mut operation = security_ledger.begin_operation(
            &operation_id,
            "secure_mesh.mls.member.add",
            &request_digest,
            runtime.identity,
            OffsetDateTime::now_utc().unix_timestamp(),
        )?;
        if let Some(response) = resume_journaled_operation(
            &mut security_ledger,
            operation.clone(),
            Some(&group),
            runtime.identity,
        )? {
            return Ok((response, false));
        }
        if operation.state == SecureMeshMlsOperationState::CryptoPrepared {
            operation = security_ledger.reset_crypto_prepared_operation_for_retry(
                &operation_id,
                OffsetDateTime::now_utc().unix_timestamp(),
            )?;
        }
        ensure!(
            operation.state == SecureMeshMlsOperationState::Prepared,
            "secure mesh MLS member-add operation is not retryable"
        );
        let staged_result = (|| {
            let base = current_group_metadata(&group, runtime.identity)?;
            require_group_base_current(
                Some(&base),
                &base.group_id_hash,
                &base.participant_endpoint_id,
            )?;
            let capability_evaluation = runtime.secret_store.capability_evaluation()?;
            let now = OffsetDateTime::now_utc();
            let key_package_directory_authorization = authorize_member_directory_response(
                runtime.config,
                runtime.identity,
                request.untrusted_directory_response.clone(),
                now,
                DirectoryAuthorizationPurpose::MlsKeyPackage,
                &member_identity,
                request.member_directory_version,
                &request.member_key_package_id,
                request.member_key_package_version,
            )?;
            key_package_directory_authorization
                .require_purpose(DirectoryAuthorizationPurpose::MlsKeyPackage)?;
            let member_directory_authorization = authorize_member_directory_response(
                runtime.config,
                runtime.identity,
                request.untrusted_directory_response.clone(),
                now,
                DirectoryAuthorizationPurpose::MlsMemberAdd,
                &member_identity,
                request.member_directory_version,
                &request.member_key_package_id,
                request.member_key_package_version,
            )?;
            let mut next_roster = directory_roster_from_group(&group)?;
            next_roster.insert(member_identity.endpoint_id.clone(), member_identity.clone());
            require_mls_directory_authority(runtime.config, runtime.identity, &next_roster)?;
            let (welcome, prepared_security) = add_product_member_prepared(
                &mut group,
                runtime.participant,
                runtime.identity,
                runtime.signing_key,
                &capability_evaluation,
                &DeviceTrustState::Verified,
                &member_key_package,
                &member_identity,
                &request.member_capability_proof,
                &member_trust_state,
                &member_directory_authorization,
                request.member_directory_version,
                request.member_key_package_version,
                &request.member_key_package_id,
                now,
            )?;
            let base_response = json!({
                "ok": true,
                "group": Value::Null,
                "commitMessageBase64url": encode_base64url(&welcome.commit_message),
                "welcomeMessageBase64url": encode_base64url(&welcome.welcome_message),
                "memberEndpointId": member_identity.endpoint_id,
                "privateKeyMaterial": "redacted"
            });
            let expected = current_group_metadata(&group, runtime.identity)?;
            security_ledger.stage_operation(
                &operation_id,
                &base_response,
                &group_id,
                Some(&base),
                &expected,
                &prepared_security,
                now.unix_timestamp(),
            )
        })();
        let staged =
            abort_empty_prepared_on_error(&mut security_ledger, &operation_id, staged_result)?;
        let response =
            commit_staged_journaled_operation(runtime, &mut security_ledger, staged, &group)?;
        Ok((response, false))
    })
}

fn member_remove(params: &Value) -> Result<Value> {
    reject_caller_asserted_trust(params)?;
    let request: MemberRemoveRequest = parse_params(params)?;
    let group_id = decode_base64url(
        &request.group_id_base64url,
        "MLS group id",
        MAX_GROUP_ID_BYTES,
    )?;
    let removed_member_identity = request.member_identity.to_identity()?;
    with_local_participant(params, ParticipantRequirement::Required, |runtime| {
        ensure!(
            removed_member_identity.endpoint_id != runtime.identity.endpoint_id,
            "secure mesh MLS member-remove action cannot remove the local identity"
        );
        let mut group = load_group_for_journal(runtime.participant, runtime.identity, &group_id)?;
        let mut security_ledger = open_security_ledger()?;
        let (operation_id, request_digest) = journal_operation_identity(
            "secure_mesh.mls.member.remove",
            &request,
            runtime.identity,
        )?;
        let mut operation = security_ledger.begin_operation(
            &operation_id,
            "secure_mesh.mls.member.remove",
            &request_digest,
            runtime.identity,
            OffsetDateTime::now_utc().unix_timestamp(),
        )?;
        if let Some(response) = resume_journaled_operation(
            &mut security_ledger,
            operation.clone(),
            Some(&group),
            runtime.identity,
        )? {
            return Ok((response, false));
        }
        if operation.state == SecureMeshMlsOperationState::CryptoPrepared {
            operation = security_ledger.reset_crypto_prepared_operation_for_retry(
                &operation_id,
                OffsetDateTime::now_utc().unix_timestamp(),
            )?;
        }
        ensure!(
            operation.state == SecureMeshMlsOperationState::Prepared,
            "secure mesh MLS member-remove operation is not retryable"
        );
        let staged_result = (|| {
            ensure!(
                group.epoch() == request.expected_epoch,
                "secure mesh MLS member-remove expected epoch is stale"
            );
            let removed_member_trust_state =
                runtime.authoritative_trust_state(&removed_member_identity)?;
            ensure!(
                matches!(
                    removed_member_trust_state,
                    DeviceTrustState::Verified
                        | DeviceTrustState::CrossSigned
                        | DeviceTrustState::Revoked
                ),
                "secure mesh MLS removed member identity is not locally verified"
            );
            let current_roster = directory_roster_from_group(&group)?;
            ensure!(
                current_roster.get(&runtime.identity.endpoint_id) == Some(runtime.identity),
                "secure mesh MLS remover is not the exact current roster identity"
            );
            ensure!(
                current_roster.get(&removed_member_identity.endpoint_id)
                    == Some(&removed_member_identity),
                "secure mesh MLS removed member is not the exact current roster identity"
            );
            let mut next_roster = current_roster;
            next_roster.remove(&removed_member_identity.endpoint_id);
            require_mls_directory_authority(runtime.config, runtime.identity, &next_roster)?;
            let base = current_group_metadata(&group, runtime.identity)?;
            require_group_base_current(
                Some(&base),
                &base.group_id_hash,
                &base.participant_endpoint_id,
            )?;
            let now = OffsetDateTime::now_utc();
            let (commit, prepared_security) = remove_product_member_prepared(
                &mut group,
                runtime.participant,
                runtime.identity,
                &DeviceTrustState::Verified,
                &removed_member_identity,
                &removed_member_trust_state,
                now,
            )?;
            let base_response = json!({
                "ok": true,
                "group": Value::Null,
                "commitMessageBase64url": encode_base64url(&commit.commit_message),
                "memberEndpointId": removed_member_identity.endpoint_id,
                "privateKeyMaterial": "redacted"
            });
            let expected = current_group_metadata(&group, runtime.identity)?;
            security_ledger.stage_operation(
                &operation_id,
                &base_response,
                &group_id,
                Some(&base),
                &expected,
                &prepared_security,
                now.unix_timestamp(),
            )
        })();
        let staged =
            abort_empty_prepared_on_error(&mut security_ledger, &operation_id, staged_result)?;
        let response =
            commit_staged_journaled_operation(runtime, &mut security_ledger, staged, &group)?;
        Ok((response, false))
    })
}

fn group_join(params: &Value) -> Result<Value> {
    reject_caller_asserted_trust(params)?;
    let request: GroupJoinRequest = parse_params(params)?;
    let group_id = decode_base64url(
        &request.group_id_base64url,
        "MLS group id",
        MAX_GROUP_ID_BYTES,
    )?;
    let welcome = decode_base64url(
        &request.welcome_message_base64url,
        "MLS welcome message",
        MAX_MLS_MESSAGE_BYTES,
    )?;
    let inviter_identity = request.inviter_identity.to_identity()?;
    ensure!(
        request
            .expected_roster_endpoint_ids
            .iter()
            .collect::<std::collections::BTreeSet<_>>()
            .len()
            == request.expected_roster_endpoint_ids.len(),
        "secure mesh MLS expected roster contains a duplicate endpoint"
    );
    let invitation = SecureMeshMlsExpectedInvitation::new(
        &group_id,
        inviter_identity.endpoint_id.clone(),
        request.expected_roster_endpoint_ids.clone(),
    )?;
    with_local_participant(params, ParticipantRequirement::Required, |runtime| {
        let trusted_roster =
            trusted_roster(&request.trusted_roster, runtime.config, runtime.identity)?;
        let inviter_trust_state = trusted_roster.state_for(&inviter_identity)?.clone();
        let mut security_ledger = open_security_ledger()?;
        let (operation_id, request_digest) =
            journal_operation_identity("secure_mesh.mls.group.join", &request, runtime.identity)?;
        let mut operation = security_ledger.begin_operation(
            &operation_id,
            "secure_mesh.mls.group.join",
            &request_digest,
            runtime.identity,
            OffsetDateTime::now_utc().unix_timestamp(),
        )?;
        if let Some(group) = SecureMeshMlsGroup::load_optional(runtime.participant, &group_id)? {
            ensure!(
                inviter_identity.endpoint_id == invitation.inviter_endpoint_id,
                "secure mesh MLS inviter identity does not match invitation"
            );
            require_verified_member_trust(&inviter_trust_state)?;
            trusted_roster.state_for(runtime.identity)?;
            cross_check_roster(
                &invitation.expected_roster_endpoint_ids,
                &group.member_credential_identities()?,
                &trusted_roster.identities,
            )?;
            group.require_active_capability_negotiation()?;
            if let Some(response) = resume_journaled_operation(
                &mut security_ledger,
                operation.clone(),
                Some(&group),
                runtime.identity,
            )? {
                return Ok((response, false));
            }
            ensure!(
                operation.state == SecureMeshMlsOperationState::Prepared,
                "secure mesh MLS joined state conflicts with an incomplete operation"
            );
            let metadata = reconcile_group_metadata(&group, runtime.identity)?;
            ensure!(
                security_ledger.abort_empty_prepared_operation(&operation_id)?,
                "secure mesh MLS joined-state no-op did not release its empty journal entry"
            );
            return Ok((group_status_json(&group, &metadata), false));
        }
        if operation.state == SecureMeshMlsOperationState::CryptoPrepared {
            operation = security_ledger.reset_crypto_prepared_operation_for_retry(
                &operation_id,
                OffsetDateTime::now_utc().unix_timestamp(),
            )?;
        }
        ensure!(
            operation.state == SecureMeshMlsOperationState::Prepared,
            "secure mesh MLS join operation lost selected-custody state"
        );
        let staged_result = (|| {
            let join_group_id_hash = format!("sha256:{}", hex_sha256(&group_id));
            let participant_scope = runtime.identity.fingerprint()?;
            require_group_base_current(None, &join_group_id_hash, &participant_scope)?;
            let now = OffsetDateTime::now_utc();
            let (group, prepared_security) = join_product_group_from_welcome_prepared(
                runtime.participant,
                runtime.identity,
                &invitation,
                &inviter_identity,
                &inviter_trust_state,
                &trusted_roster.identities,
                &crate::core::secure_mesh_mls::SecureMeshMlsWelcome {
                    commit_message: Vec::new(),
                    welcome_message: welcome,
                },
                now,
            )?;
            let expected = current_group_metadata(&group, runtime.identity)?;
            let staged = security_ledger.stage_operation(
                &operation_id,
                &json!({}),
                &group_id,
                None,
                &expected,
                &prepared_security,
                now.unix_timestamp(),
            )?;
            Ok((group, staged))
        })();
        let (group, staged) =
            abort_empty_prepared_on_error(&mut security_ledger, &operation_id, staged_result)?;
        let response =
            commit_staged_journaled_operation(runtime, &mut security_ledger, staged, &group)?;
        Ok((response, false))
    })
}

fn commit_process(params: &Value) -> Result<Value> {
    reject_caller_asserted_trust(params)?;
    let request: CommitProcessRequest = parse_params(params)?;
    let group_id = decode_base64url(
        &request.group_id_base64url,
        "MLS group id",
        MAX_GROUP_ID_BYTES,
    )?;
    let commit = decode_base64url(
        &request.commit_message_base64url,
        "MLS commit message",
        MAX_MLS_MESSAGE_BYTES,
    )?;
    let committer_identity = request.committer_identity.to_identity()?;
    let added_member_identity = request
        .added_member_identity
        .as_ref()
        .map(PublicIdentityInput::to_identity)
        .transpose()?;
    let removed_member_identity = request
        .removed_member_identity
        .as_ref()
        .map(PublicIdentityInput::to_identity)
        .transpose()?;
    ensure!(
        added_member_identity.is_none() || removed_member_identity.is_none(),
        "secure mesh MLS commit cannot add and remove a member in one product transition"
    );
    with_local_participant(params, ParticipantRequirement::Required, |runtime| {
        let local_is_removed = removed_member_identity.as_ref() == Some(runtime.identity);
        let trusted_roster = trusted_roster_with_local_policy(
            &request.trusted_roster,
            runtime.config,
            runtime.identity,
            !local_is_removed,
        )?;
        let committer_trust_state = trusted_roster.state_for(&committer_identity)?.clone();
        let mut group = load_group_for_journal(runtime.participant, runtime.identity, &group_id)?;
        let mut security_ledger = open_security_ledger()?;
        let (operation_id, request_digest) = journal_operation_identity(
            "secure_mesh.mls.commit.process",
            &request,
            runtime.identity,
        )?;
        let mut operation = security_ledger.begin_operation(
            &operation_id,
            "secure_mesh.mls.commit.process",
            &request_digest,
            runtime.identity,
            OffsetDateTime::now_utc().unix_timestamp(),
        )?;
        if let Some(response) = resume_journaled_operation(
            &mut security_ledger,
            operation.clone(),
            Some(&group),
            runtime.identity,
        )? {
            return Ok((response, false));
        }
        if operation.state == SecureMeshMlsOperationState::CryptoPrepared {
            operation = security_ledger.reset_crypto_prepared_operation_for_retry(
                &operation_id,
                OffsetDateTime::now_utc().unix_timestamp(),
            )?;
        }
        ensure!(
            operation.state == SecureMeshMlsOperationState::Prepared,
            "secure mesh MLS commit operation is not retryable"
        );
        let staged_result = (|| {
            let base = current_group_metadata(&group, runtime.identity)?;
            require_group_base_current(
                Some(&base),
                &base.group_id_hash,
                &base.participant_endpoint_id,
            )?;
            let now = OffsetDateTime::now_utc();
            let prepared_security = process_product_commit_prepared(
                &mut group,
                runtime.participant,
                runtime.identity,
                &committer_identity,
                &committer_trust_state,
                added_member_identity.as_ref(),
                removed_member_identity.as_ref(),
                &trusted_roster.identities,
                &commit,
                now,
            )?;
            let expected = current_group_metadata(&group, runtime.identity)?;
            security_ledger.stage_operation(
                &operation_id,
                &json!({}),
                &group_id,
                Some(&base),
                &expected,
                &prepared_security,
                now.unix_timestamp(),
            )
        })();
        let staged =
            abort_empty_prepared_on_error(&mut security_ledger, &operation_id, staged_result)?;
        let response =
            commit_staged_journaled_operation(runtime, &mut security_ledger, staged, &group)?;
        Ok((response, false))
    })
}

fn payload_seal(params: &Value) -> Result<Value> {
    reject_caller_asserted_trust(params)?;
    let request: PayloadSealRequest = parse_params(params)?;
    let group_id = decode_base64url(
        &request.group_id_base64url,
        "MLS group id",
        MAX_GROUP_ID_BYTES,
    )?;
    let context = request.context.to_context();
    let body = decode_base64url(
        &request.body_base64url,
        "MLS payload body",
        MAX_PAYLOAD_BYTES,
    )?;
    let mut plaintext = SecureMeshPlaintext::new(parse_payload_kind(&request.payload_kind)?, body);
    if let Some(content_type) = request.content_type.as_deref() {
        plaintext = plaintext.with_content_type(content_type);
    }
    with_local_participant(params, ParticipantRequirement::Required, |runtime| {
        let trusted_roster =
            trusted_roster(&request.trusted_roster, runtime.config, runtime.identity)?;
        let mut group = load_group_checked(runtime.participant, runtime.identity, &group_id)?;
        let sender_state = trusted_roster.state_for(runtime.identity)?;
        let message = seal_product_payload_message(
            &mut group,
            runtime.participant,
            runtime.identity,
            sender_state,
            &trusted_roster.identities,
            &context,
            &plaintext,
        )?;
        Ok((
            json!({
                "ok": true,
                "messageBase64url": encode_base64url(&message),
                "payloadKind": plaintext.kind.as_str(),
                "bodyRedacted": true,
                "privateKeyMaterial": "redacted"
            }),
            true,
        ))
    })
}

fn payload_open(params: &Value) -> Result<Value> {
    reject_caller_asserted_trust(params)?;
    let request: PayloadOpenRequest = parse_params(params)?;
    let group_id = decode_base64url(
        &request.group_id_base64url,
        "MLS group id",
        MAX_GROUP_ID_BYTES,
    )?;
    let message = decode_base64url(
        &request.message_base64url,
        "MLS application message",
        MAX_MLS_MESSAGE_BYTES,
    )?;
    let trusted_sender_identity = request.trusted_sender_identity.to_identity()?;
    let context = request.context.to_context();
    let expected_kind = parse_payload_kind(&request.expected_payload_kind)?;
    with_local_participant(params, ParticipantRequirement::Required, |runtime| {
        let trusted_roster =
            trusted_roster(&request.trusted_roster, runtime.config, runtime.identity)?;
        let trusted_sender_state = trusted_roster.state_for(&trusted_sender_identity)?.clone();
        let mut group = load_group_checked(runtime.participant, runtime.identity, &group_id)?;
        let opened = open_product_payload_message(
            &mut group,
            runtime.participant,
            runtime.identity,
            &trusted_sender_identity,
            &trusted_sender_state,
            &trusted_roster.identities,
            &context,
            &message,
            expected_kind,
        )?;
        Ok((
            json!({
                "ok": true,
                "payloadKind": opened.kind.as_str(),
                "bodyBase64url": encode_base64url(&opened.body),
                "contentType": opened.content_type,
                "createdAt": opened.created_at,
                "expiresAt": opened.expires_at,
                "privateKeyMaterial": "redacted"
            }),
            true,
        ))
    })
}

enum ParticipantRequirement {
    CreateIfMissing,
    Required,
}

struct LocalParticipantRuntime<'a> {
    config: &'a mut Value,
    identity: &'a DeviceTrustPublicIdentity,
    signing_key: &'a SigningKey,
    secret_store: &'a Arc<dyn SecureMeshSecretStore>,
    authorization: &'a SecretStoreAuthorizationSession,
    snapshot_handle: &'a SecretStoreHandle,
    participant: &'a mut SecureMeshMlsParticipant,
}

impl LocalParticipantRuntime<'_> {
    fn persist_participant(&self) -> Result<()> {
        self.participant.save_secret_store_with_session(
            self.secret_store.as_ref(),
            self.snapshot_handle,
            self.authorization,
        )
    }

    fn authoritative_trust_state(
        &self,
        identity: &DeviceTrustPublicIdentity,
    ) -> Result<DeviceTrustState> {
        if identity == self.identity {
            return Ok(DeviceTrustState::Verified);
        }
        crate::domain::mobile_relay::persisted_mobile_relay_peer_trust_state(
            self.config,
            self.identity,
            identity,
        )
    }
}

fn with_local_participant(
    params: &Value,
    requirement: ParticipantRequirement,
    operation: impl FnOnce(&mut LocalParticipantRuntime<'_>) -> Result<(Value, bool)>,
) -> Result<Value> {
    crate::domain::mobile_relay::with_secure_mesh_mls_local_runtime(
        params,
        4,
        |config, identity, signing_key, secret_store, authorization, namespace| {
            let handle = participant_snapshot_handle(namespace, identity)?;
            let exists = SecureMeshMlsParticipant::secret_store_snapshot_exists_with_session(
                secret_store.as_ref(),
                &handle,
                authorization,
            )?;
            let mut participant = if exists {
                SecureMeshMlsParticipant::load_from_secret_store_with_optional_session(
                    crate::core::secure_mesh_mls_product::mls_credential_identity_bytes(identity)?,
                    identity.signing_public_key,
                    secret_store.as_ref(),
                    &handle,
                    Some(authorization),
                )?
            } else {
                handle_missing_participant_snapshot(identity, secret_store.backend())?;
                ensure!(
                    matches!(requirement, ParticipantRequirement::CreateIfMissing),
                    "secure mesh MLS participant state is unavailable in selected custody"
                );
                participant_from_device_identity(identity, signing_key)?
            };
            let mut runtime = LocalParticipantRuntime {
                config,
                identity,
                signing_key,
                secret_store,
                authorization,
                snapshot_handle: &handle,
                participant: &mut participant,
            };
            recover_incomplete_writer_operations(runtime.participant, runtime.identity)?;
            let (response, persist) = operation(&mut runtime)?;
            if persist {
                participant.save_secret_store_with_session(
                    secret_store.as_ref(),
                    &handle,
                    authorization,
                )?;
            }
            Ok(response)
        },
    )
}

fn handle_missing_participant_snapshot(
    identity: &DeviceTrustPublicIdentity,
    selected_backend: &str,
) -> Result<()> {
    let state_dir = crate::domain::mobile_relay::secure_mesh_mls_state_dir()?;
    let mut group_store = crate::core::secure_mesh_mls::SecureMeshMlsDurableStore::open(
        state_dir.join("group-state.sqlite3"),
    )?;
    let participant_scope = identity.fingerprint()?;
    let has_group_state = group_store.has_records_for_participant(&participant_scope)?;
    if selected_backend == "memory-only-ephemeral" {
        group_store.purge_unrecoverable_memory_only_state()?;
        return Ok(());
    }
    ensure!(
        !has_group_state,
        "secure mesh MLS persistent participant snapshot is missing while durable group state exists"
    );
    Ok(())
}

fn participant_snapshot_handle(
    namespace: &str,
    identity: &DeviceTrustPublicIdentity,
) -> Result<SecretStoreHandle> {
    let digest = hex_sha256(identity.fingerprint()?.as_bytes());
    SecretStoreHandle::new(
        namespace,
        format!("{MLS_PARTICIPANT_SNAPSHOT_KEY_PREFIX}{digest}"),
    )
}

pub(crate) fn reset_selected_custody_for_kt_authority_change(
    identity: &DeviceTrustPublicIdentity,
    secret_store: &dyn SecureMeshSecretStore,
    authorization: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    let handle = participant_snapshot_handle(namespace, identity)?;
    secret_store.delete_secret_with_session(authorization, &handle)?;
    Ok(())
}

pub(crate) fn reset_durable_state_for_kt_authority_change() -> Result<()> {
    let state_dir = crate::domain::mobile_relay::secure_mesh_mls_state_dir()?;
    let mut group_store = crate::core::secure_mesh_mls::SecureMeshMlsDurableStore::open(
        state_dir.join("group-state.sqlite3"),
    )?;
    group_store.reset_for_kt_authority_change()?;
    let mut security_ledger =
        SecureMeshMlsSecurityLedger::open(state_dir.join("security-ledger.sqlite3"))?;
    security_ledger.reset_for_kt_authority_change()?;
    Ok(())
}

fn open_security_ledger() -> Result<SecureMeshMlsSecurityLedger> {
    SecureMeshMlsSecurityLedger::open(
        crate::domain::mobile_relay::secure_mesh_mls_state_dir()?.join("security-ledger.sqlite3"),
    )
}

#[derive(Clone, Debug)]
struct MlsDirectoryReadiness {
    tree_size: u64,
    root_hash: String,
    map_root_hash: String,
    receipt_count: usize,
}

fn open_mls_directory_authority(
    config: &Value,
    local_identity: &DeviceTrustPublicIdentity,
) -> Result<SecureMeshDirectoryAuthority> {
    crate::domain::mobile_relay::ensure_secure_mesh_protected_operation_allowed()?;
    let local_configuration = config
        .get("secureMeshKeyTransparency")
        .ok_or_else(|| anyhow!("secure mesh MLS local KT pin configuration is required"))?;
    let local_configuration: SecureMeshKtVerifierConfiguration =
        serde_json::from_value(local_configuration.clone())
            .map_err(|_| anyhow!("secure mesh MLS local KT pin configuration is invalid"))?;
    let policy = KtFreshnessPolicy::strict(
        local_configuration.max_sth_age_seconds,
        local_configuration.max_future_skew_seconds,
    )?;
    let pin = local_configuration.pin.into_pin()?;
    let state_path =
        crate::domain::mobile_relay::secure_mesh_kt_authority_path(&local_identity.endpoint_id)?;
    SecureMeshDirectoryAuthority::open(state_path, pin, policy)
}

fn require_mls_directory_authority(
    config: &Value,
    local_identity: &DeviceTrustPublicIdentity,
    identities: &BTreeMap<String, DeviceTrustPublicIdentity>,
) -> Result<MlsDirectoryReadiness> {
    require_mls_directory_authority_with_local_policy(config, local_identity, identities, true)
}

fn require_mls_directory_authority_with_local_policy(
    config: &Value,
    local_identity: &DeviceTrustPublicIdentity,
    identities: &BTreeMap<String, DeviceTrustPublicIdentity>,
    require_local_member: bool,
) -> Result<MlsDirectoryReadiness> {
    if require_local_member {
        ensure!(
            identities.get(&local_identity.endpoint_id) == Some(local_identity),
            "secure mesh MLS directory roster is missing the exact local identity"
        );
    } else {
        ensure!(
            !identities.contains_key(&local_identity.endpoint_id),
            "secure mesh MLS post-removal directory roster still contains the local identity"
        );
    }
    let scope = config
        .get("secureMeshDirectoryScopeCommitment")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure mesh MLS configured directory scope is required"))?;
    let now_epoch_seconds = u64::try_from(OffsetDateTime::now_utc().unix_timestamp())
        .map_err(|_| anyhow!("secure mesh MLS KT verification time is invalid"))?;
    let mut authority = open_mls_directory_authority(config, local_identity)?;
    let mut checkpoint: Option<(u64, String, String)> = None;
    let mut receipt_count = 0usize;
    for identity in identities.values() {
        let stable_label = stable_directory_label(scope, &identity.endpoint_id);
        let purposes: &[DirectoryAuthorizationPurpose] = if identity == local_identity {
            &[DirectoryAuthorizationPurpose::SelfMonitor]
        } else {
            &[
                DirectoryAuthorizationPurpose::MlsKeyPackage,
                DirectoryAuthorizationPurpose::MlsMemberAdd,
            ]
        };
        let mut identity_receipts = Vec::with_capacity(purposes.len());
        for purpose in purposes {
            let receipt = authority.require_current_authorization(
                &stable_label,
                *purpose,
                now_epoch_seconds,
            )?;
            ensure_mls_receipt_identity_binding(&receipt, identity)?;
            let binding = (
                receipt.tree_size,
                receipt.root_hash.clone(),
                receipt.map_root_hash.clone(),
            );
            if let Some(expected) = &checkpoint {
                ensure!(
                    expected == &binding,
                    "secure mesh MLS KT receipts do not share one current tree"
                );
            } else {
                checkpoint = Some(binding);
            }
            receipt_count = receipt_count.saturating_add(1);
            identity_receipts.push(receipt);
        }
        if identity == local_identity {
            if let (Some(digest), Some(version)) = (
                config
                    .get("mobileRelayE2ee")
                    .and_then(|state| state.get("mlsKeyPackageDigest"))
                    .and_then(Value::as_str),
                config
                    .get("mobileRelayE2ee")
                    .and_then(|state| state.get("mlsKeyPackageVersion"))
                    .and_then(Value::as_u64)
                    .filter(|version| *version > 0),
            ) {
                let self_monitor = &identity_receipts[0];
                ensure!(
                    self_monitor.mls_key_package_digest == digest
                        && self_monitor.mls_key_package_version == version,
                    "secure mesh MLS local KT receipt does not bind the current KeyPackage"
                );
                let key_package_receipt = authority.require_current_authorization(
                    &stable_label,
                    DirectoryAuthorizationPurpose::MlsKeyPackage,
                    now_epoch_seconds,
                )?;
                ensure_mls_receipt_identity_binding(&key_package_receipt, identity)?;
                ensure!(
                    key_package_receipt.mls_key_package_digest == digest
                        && key_package_receipt.mls_key_package_version == version,
                    "secure mesh MLS local KeyPackage receipt differs from local state"
                );
                ensure!(
                    checkpoint.as_ref()
                        == Some(&(
                            key_package_receipt.tree_size,
                            key_package_receipt.root_hash.clone(),
                            key_package_receipt.map_root_hash.clone(),
                        )),
                    "secure mesh MLS local KeyPackage receipt is not on the current tree"
                );
                receipt_count = receipt_count.saturating_add(1);
            }
        } else {
            let key_package = &identity_receipts[0];
            let member_add = &identity_receipts[1];
            ensure!(
                key_package.directory_version == member_add.directory_version
                    && key_package.mls_key_package_version == member_add.mls_key_package_version
                    && key_package.mls_key_package_digest == member_add.mls_key_package_digest
                    && member_add.mls_key_package_version > 0
                    && member_add.mls_key_package_digest != "0".repeat(64),
                "secure mesh MLS remote KT receipts do not bind one real KeyPackage publication"
            );
        }
    }
    let (tree_size, root_hash, map_root_hash) =
        checkpoint.ok_or_else(|| anyhow!("secure mesh MLS current KT receipt set is empty"))?;
    Ok(MlsDirectoryReadiness {
        tree_size,
        root_hash,
        map_root_hash,
        receipt_count,
    })
}

fn ensure_mls_receipt_identity_binding(
    receipt: &SecureMeshKtAuthorizationReceipt,
    identity: &DeviceTrustPublicIdentity,
) -> Result<()> {
    ensure!(
        !receipt.revoked
            && receipt.identity_fingerprint == identity.fingerprint()?
            && receipt.identity_rotation_epoch == identity.rotation_epoch,
        "secure mesh MLS KT receipt identity is revoked or differs from the roster"
    );
    Ok(())
}

#[cfg(test)]
fn authorize_member_add_directory_response(
    config: &Value,
    local_identity: &DeviceTrustPublicIdentity,
    response: UntrustedDirectoryResponse,
    now: OffsetDateTime,
) -> Result<AuthorizedDirectoryLeaf> {
    let local_configuration = config
        .get("secureMeshKeyTransparency")
        .ok_or_else(|| anyhow!("secure mesh MLS local KT pin configuration is required"))?;
    let local_configuration: SecureMeshKtVerifierConfiguration =
        serde_json::from_value(local_configuration.clone())
            .map_err(|_| anyhow!("secure mesh MLS local KT pin configuration is invalid"))?;
    let policy = KtFreshnessPolicy::strict(
        local_configuration.max_sth_age_seconds,
        local_configuration.max_future_skew_seconds,
    )?;
    let pin = local_configuration.pin.into_pin()?;
    let state_path =
        crate::domain::mobile_relay::secure_mesh_kt_authority_path(&local_identity.endpoint_id)?;
    let mut authority = SecureMeshDirectoryAuthority::open(state_path, pin, policy)?;
    let now_epoch_seconds = u64::try_from(now.unix_timestamp())
        .map_err(|_| anyhow!("secure mesh MLS KT verification time is invalid"))?;
    authority.authorize(
        response,
        DirectoryAuthorizationPurpose::MlsMemberAdd,
        now_epoch_seconds,
    )
}

fn authorize_member_directory_response(
    config: &Value,
    local_identity: &DeviceTrustPublicIdentity,
    response: UntrustedDirectoryResponse,
    now: OffsetDateTime,
    purpose: DirectoryAuthorizationPurpose,
    member_identity: &DeviceTrustPublicIdentity,
    member_directory_version: u64,
    member_key_package_digest: &str,
    member_key_package_version: u64,
) -> Result<AuthorizedDirectoryLeaf> {
    let local_configuration = config
        .get("secureMeshKeyTransparency")
        .ok_or_else(|| anyhow!("secure mesh MLS local KT pin configuration is required"))?;
    let local_configuration: SecureMeshKtVerifierConfiguration =
        serde_json::from_value(local_configuration.clone())
            .map_err(|_| anyhow!("secure mesh MLS local KT pin configuration is invalid"))?;
    let policy = KtFreshnessPolicy::strict(
        local_configuration.max_sth_age_seconds,
        local_configuration.max_future_skew_seconds,
    )?;
    let pin = local_configuration.pin.into_pin()?;
    let state_path =
        crate::domain::mobile_relay::secure_mesh_kt_authority_path(&local_identity.endpoint_id)?;
    let mut authority = SecureMeshDirectoryAuthority::open(state_path, pin, policy)?;
    let now_epoch_seconds = u64::try_from(now.unix_timestamp())
        .map_err(|_| anyhow!("secure mesh MLS KT verification time is invalid"))?;
    #[cfg(test)]
    if config
        .get("secureMeshKeyTransparency")
        .and_then(|settings| settings.get("pin"))
        .and_then(|pin| pin.get("provenance"))
        .and_then(Value::as_str)
        == Some("local-acceptance-mock")
    {
        authority.observe_response_gossip_for_test(&response, now_epoch_seconds)?;
    }
    authority.authorize_request(
        response,
        DirectoryAuthorizationRequest::for_mls(
            purpose,
            config
                .get("secureMeshDirectoryScopeCommitment")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("secure mesh MLS configured directory scope is required"))?,
            member_identity,
            member_directory_version,
            member_key_package_digest,
            member_key_package_version,
        ),
        now_epoch_seconds,
    )
}

fn journal_operation_identity<T: Serialize>(
    action: &str,
    request: &T,
    identity: &DeviceTrustPublicIdentity,
) -> Result<(String, String)> {
    let request_bytes = serde_json::to_vec(request)
        .map_err(|_| anyhow!("secure mesh MLS operation request encoding failed"))?;
    let request_digest = hex_sha256(&request_bytes);
    let mut transcript = Vec::new();
    transcript.extend_from_slice(b"LICO-SM-MLS-OPERATION-v1");
    transcript.extend_from_slice(action.as_bytes());
    transcript.extend_from_slice(identity.fingerprint()?.as_bytes());
    transcript.extend_from_slice(request_digest.as_bytes());
    Ok((hex_sha256(&transcript), request_digest))
}

fn recover_incomplete_writer_operations(
    participant: &SecureMeshMlsParticipant,
    identity: &DeviceTrustPublicIdentity,
) -> Result<()> {
    let mut ledger = open_security_ledger()?;
    for mut operation in ledger.incomplete_writer_operations(identity)? {
        let group_id = operation
            .group_id
            .as_ref()
            .ok_or_else(|| anyhow!("secure mesh MLS incomplete operation group id is missing"))?;
        let group = SecureMeshMlsGroup::load_optional(participant, group_id)?;
        match operation.state {
            SecureMeshMlsOperationState::CryptoPrepared => match group {
                None => {
                    ensure!(
                        operation.base_metadata.is_none(),
                        "secure mesh MLS incomplete operation lost its base snapshot"
                    );
                    ledger.reset_crypto_prepared_operation_for_retry(
                        &operation.operation_id,
                        OffsetDateTime::now_utc().unix_timestamp(),
                    )?;
                }
                Some(group) => {
                    let observed = current_group_metadata(&group, identity)?;
                    if operation.expected_metadata.as_ref() == Some(&observed) {
                        operation = ledger.commit_operation_crypto(
                            &operation.operation_id,
                            &observed,
                            OffsetDateTime::now_utc().unix_timestamp(),
                        )?;
                        let _ =
                            finish_journaled_operation(&mut ledger, operation, &group, identity)?;
                    } else if operation.base_metadata.as_ref() == Some(&observed) {
                        ledger.reset_crypto_prepared_operation_for_retry(
                            &operation.operation_id,
                            OffsetDateTime::now_utc().unix_timestamp(),
                        )?;
                    } else {
                        return Err(anyhow!(
                            "secure mesh MLS incomplete operation snapshot matches neither base nor expected state"
                        ));
                    }
                }
            },
            SecureMeshMlsOperationState::CryptoCommitted => {
                let group = group.ok_or_else(|| {
                    anyhow!("secure mesh MLS committed operation group snapshot is missing")
                })?;
                let observed = current_group_metadata(&group, identity)?;
                ensure!(
                    operation.expected_metadata.as_ref() == Some(&observed),
                    "secure mesh MLS committed operation snapshot diverges"
                );
                let _ = finish_journaled_operation(&mut ledger, operation, &group, identity)?;
            }
            _ => {
                return Err(anyhow!(
                    "secure mesh MLS writer reservation has an invalid journal state"
                ));
            }
        }
    }
    Ok(())
}

fn current_group_metadata(
    group: &SecureMeshMlsGroup,
    identity: &DeviceTrustPublicIdentity,
) -> Result<crate::core::secure_mesh_mls::SecureMeshMlsGroupMetadata> {
    group.public_metadata(identity.fingerprint()?)
}

fn abort_empty_prepared_on_error<T>(
    ledger: &mut SecureMeshMlsSecurityLedger,
    operation_id: &str,
    result: Result<T>,
) -> Result<T> {
    match result {
        Ok(value) => Ok(value),
        Err(error) => {
            let removed = ledger.abort_empty_prepared_operation(operation_id)?;
            if !removed {
                if let Some(record) = ledger.operation(operation_id)? {
                    ensure!(
                        record.state != SecureMeshMlsOperationState::Prepared,
                        "secure mesh MLS failed input left an unabortable prepared operation"
                    );
                }
            }
            Err(error)
        }
    }
}

fn resume_journaled_operation(
    ledger: &mut SecureMeshMlsSecurityLedger,
    mut record: SecureMeshMlsOperationRecord,
    group: Option<&SecureMeshMlsGroup>,
    identity: &DeviceTrustPublicIdentity,
) -> Result<Option<Value>> {
    if record.state == SecureMeshMlsOperationState::Prepared {
        return Ok(None);
    }
    if record.state == SecureMeshMlsOperationState::MetadataReconciled {
        record = ledger.mark_operation_delivered(
            &record.operation_id,
            OffsetDateTime::now_utc().unix_timestamp(),
        )?;
        return record
            .response
            .map(Some)
            .ok_or_else(|| anyhow!("secure mesh MLS reconciled response is missing"));
    }
    if record.state == SecureMeshMlsOperationState::Delivered {
        return record
            .response
            .map(Some)
            .ok_or_else(|| anyhow!("secure mesh MLS delivered response is missing"));
    }
    if group.is_none()
        && record.state == SecureMeshMlsOperationState::CryptoPrepared
        && record.base_metadata.is_none()
    {
        ledger.reset_crypto_prepared_operation_for_retry(
            &record.operation_id,
            OffsetDateTime::now_utc().unix_timestamp(),
        )?;
        return Ok(None);
    }
    let group = group.ok_or_else(|| {
        anyhow!("secure mesh MLS committed operation is missing selected-custody group state")
    })?;
    let observed = current_group_metadata(group, identity)?;
    let expected = record
        .expected_metadata
        .as_ref()
        .ok_or_else(|| anyhow!("secure mesh MLS operation journal expected metadata is missing"))?;
    if record.state == SecureMeshMlsOperationState::CryptoPrepared {
        if &observed != expected {
            let base = record.base_metadata.as_ref().ok_or_else(|| {
                anyhow!("secure mesh MLS prepared operation has no recoverable base state")
            })?;
            ensure!(
                &observed == base,
                "secure mesh MLS prepared operation snapshot matches neither base nor expected state"
            );
            return Ok(None);
        }
        record = ledger.commit_operation_crypto(
            &record.operation_id,
            &observed,
            OffsetDateTime::now_utc().unix_timestamp(),
        )?;
    } else {
        ensure!(
            &observed == expected,
            "secure mesh MLS operation journal detected selected-custody rollback"
        );
    }
    finish_journaled_operation(ledger, record, group, identity).map(Some)
}

fn finish_journaled_operation(
    ledger: &mut SecureMeshMlsSecurityLedger,
    mut record: SecureMeshMlsOperationRecord,
    group: &SecureMeshMlsGroup,
    identity: &DeviceTrustPublicIdentity,
) -> Result<Value> {
    if record.state == SecureMeshMlsOperationState::CryptoCommitted {
        journal_failpoint("after_crypto_commit_before_metadata")?;
        let durable = reconcile_group_metadata(group, identity)?;
        let group_status = group_status_json(group, &durable);
        let mut final_response = record
            .response
            .clone()
            .ok_or_else(|| anyhow!("secure mesh MLS operation journal response is missing"))?;
        if matches!(
            record.action.as_str(),
            "secure_mesh.mls.member.add" | "secure_mesh.mls.member.remove"
        ) {
            final_response["group"] = group_status;
        } else {
            final_response = group_status;
        }
        record = ledger.mark_operation_metadata_reconciled(
            &record.operation_id,
            &final_response,
            OffsetDateTime::now_utc().unix_timestamp(),
        )?;
    }
    if record.state == SecureMeshMlsOperationState::MetadataReconciled {
        journal_failpoint("after_metadata_before_delivery")?;
        record = ledger.mark_operation_delivered(
            &record.operation_id,
            OffsetDateTime::now_utc().unix_timestamp(),
        )?;
    }
    ensure!(
        record.state == SecureMeshMlsOperationState::Delivered,
        "secure mesh MLS operation journal did not reach delivery state"
    );
    record
        .response
        .ok_or_else(|| anyhow!("secure mesh MLS delivered operation response is missing"))
}

fn commit_staged_journaled_operation(
    runtime: &LocalParticipantRuntime<'_>,
    ledger: &mut SecureMeshMlsSecurityLedger,
    staged: SecureMeshMlsOperationRecord,
    group: &SecureMeshMlsGroup,
) -> Result<Value> {
    journal_failpoint("after_stage_before_snapshot")?;
    runtime.persist_participant()?;
    journal_failpoint("after_snapshot_before_crypto_commit")?;
    let observed = current_group_metadata(group, runtime.identity)?;
    let committed = ledger.commit_operation_crypto(
        &staged.operation_id,
        &observed,
        OffsetDateTime::now_utc().unix_timestamp(),
    )?;
    finish_journaled_operation(ledger, committed, group, runtime.identity)
}

#[cfg(not(test))]
fn journal_failpoint(_name: &str) -> Result<()> {
    Ok(())
}

#[cfg(test)]
std::thread_local! {
    static MLS_JOURNAL_FAILPOINT: std::cell::Cell<Option<&'static str>> = const {
        std::cell::Cell::new(None)
    };
}

#[cfg(test)]
struct MlsJournalFailpointGuard;

#[cfg(test)]
impl Drop for MlsJournalFailpointGuard {
    fn drop(&mut self) {
        MLS_JOURNAL_FAILPOINT.with(|failpoint| failpoint.set(None));
    }
}

#[cfg(test)]
fn set_journal_failpoint(name: &'static str) -> MlsJournalFailpointGuard {
    MLS_JOURNAL_FAILPOINT.with(|failpoint| {
        assert!(
            failpoint.replace(Some(name)).is_none(),
            "secure mesh MLS journal failpoint is already active on this test thread"
        );
    });
    MlsJournalFailpointGuard
}

#[cfg(test)]
fn journal_failpoint(name: &str) -> Result<()> {
    MLS_JOURNAL_FAILPOINT.with(|failpoint| {
        if failpoint.get() == Some(name) {
            failpoint.set(None);
            Err(anyhow!("secure mesh MLS injected journal boundary failure"))
        } else {
            Ok(())
        }
    })
}

fn load_group_checked(
    participant: &SecureMeshMlsParticipant,
    identity: &DeviceTrustPublicIdentity,
    group_id: &[u8],
) -> Result<SecureMeshMlsGroup> {
    let group = SecureMeshMlsGroup::load(participant, group_id)?;
    let metadata = group.public_metadata(identity.fingerprint()?)?;
    let mut store = crate::core::secure_mesh_mls::SecureMeshMlsDurableStore::open(
        crate::domain::mobile_relay::secure_mesh_mls_state_dir()?.join("group-state.sqlite3"),
    )?;
    if store
        .read(&metadata.group_id_hash, &metadata.participant_endpoint_id)?
        .is_some()
    {
        let previous = store.reconcile_authenticated_snapshot(
            &metadata,
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .map_err(|_| anyhow!("secure mesh MLS metadata timestamp is invalid"))?,
        )?;
        ensure!(
            metadata.epoch == previous.epoch
                && metadata.public_state_digest == previous.public_state_digest
                && metadata.member_count == previous.member_count
                && metadata.own_leaf_index == previous.own_leaf_index
                && metadata.active == previous.active,
            "secure mesh MLS selected-custody group state differs from durable authority"
        );
    } else {
        return Err(anyhow!(
            "secure mesh MLS durable group authority is missing"
        ));
    }
    Ok(group)
}

fn load_group_for_journal(
    participant: &SecureMeshMlsParticipant,
    identity: &DeviceTrustPublicIdentity,
    group_id: &[u8],
) -> Result<SecureMeshMlsGroup> {
    let group = SecureMeshMlsGroup::load(participant, group_id)?;
    let metadata = current_group_metadata(&group, identity)?;
    let mut store = crate::core::secure_mesh_mls::SecureMeshMlsDurableStore::open(
        crate::domain::mobile_relay::secure_mesh_mls_state_dir()?.join("group-state.sqlite3"),
    )?;
    if store
        .read(&metadata.group_id_hash, &metadata.participant_endpoint_id)?
        .is_some()
    {
        let previous = store.reconcile_authenticated_snapshot(
            &metadata,
            OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .map_err(|_| anyhow!("secure mesh MLS metadata timestamp is invalid"))?,
        )?;
        ensure!(
            metadata.epoch >= previous.epoch,
            "secure mesh MLS selected-custody group state rollback detected"
        );
        if metadata.epoch == previous.epoch {
            ensure!(
                metadata.public_state_digest == previous.public_state_digest
                    && metadata.member_count == previous.member_count
                    && metadata.own_leaf_index == previous.own_leaf_index
                    && metadata.active == previous.active,
                "secure mesh MLS same-epoch selected-custody state diverges"
            );
        }
    }
    Ok(group)
}

fn require_group_base_current(
    base: Option<&crate::core::secure_mesh_mls::SecureMeshMlsGroupMetadata>,
    group_id_hash: &str,
    participant_scope: &str,
) -> Result<()> {
    let store = crate::core::secure_mesh_mls::SecureMeshMlsDurableStore::open(
        crate::domain::mobile_relay::secure_mesh_mls_state_dir()?.join("group-state.sqlite3"),
    )?;
    let durable = store.read(group_id_hash, participant_scope)?;
    match (base, durable) {
        (None, None) => Ok(()),
        (Some(base), Some(durable)) => {
            ensure!(
                durable.group_id_hash == base.group_id_hash
                    && durable.participant_endpoint_id == base.participant_endpoint_id
                    && durable.public_state_digest == base.public_state_digest
                    && durable.epoch == base.epoch
                    && durable.member_count == base.member_count
                    && durable.own_leaf_index == base.own_leaf_index
                    && durable.active == base.active,
                "secure mesh MLS operation base state is stale"
            );
            Ok(())
        }
        _ => Err(anyhow!(
            "secure mesh MLS operation base state diverges from durable metadata"
        )),
    }
}

fn reconcile_group_metadata(
    group: &SecureMeshMlsGroup,
    identity: &DeviceTrustPublicIdentity,
) -> Result<crate::core::secure_mesh_mls::SecureMeshMlsDurableRecord> {
    let metadata = group.public_metadata(identity.fingerprint()?)?;
    let mut store = crate::core::secure_mesh_mls::SecureMeshMlsDurableStore::open(
        crate::domain::mobile_relay::secure_mesh_mls_state_dir()?.join("group-state.sqlite3"),
    )?;
    let updated_at = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|_| anyhow!("secure mesh MLS metadata timestamp is invalid"))?;
    let previous = store.read(&metadata.group_id_hash, &metadata.participant_endpoint_id)?;
    let previous = match previous {
        Some(_) => Some(store.reconcile_authenticated_snapshot(&metadata, updated_at.clone())?),
        None => None,
    };
    match previous {
        None => store.upsert_initial(&metadata, updated_at),
        Some(previous)
            if previous.epoch == metadata.epoch
                && previous.public_state_digest == metadata.public_state_digest
                && previous.member_count == metadata.member_count
                && previous.own_leaf_index == metadata.own_leaf_index
                && previous.active == metadata.active =>
        {
            Ok(previous)
        }
        Some(previous) => store.commit_epoch(&previous, &metadata, updated_at),
    }
}

fn group_status_json(
    group: &SecureMeshMlsGroup,
    record: &crate::core::secure_mesh_mls::SecureMeshMlsDurableRecord,
) -> Value {
    json!({
        "ok": true,
        "protocolVersion": SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION,
        "groupIdHash": record.group_id_hash,
        "epoch": group.epoch(),
        "stateVersion": record.state_version,
        "memberCount": group.member_count(),
        "active": group.is_active(),
        "capabilityNegotiated": group.require_active_capability_negotiation().is_ok(),
        "participantScopeRedacted": true,
        "privateKeyMaterial": "redacted"
    })
}

fn public_local_participant(
    identity: &DeviceTrustPublicIdentity,
    participant: &SecureMeshMlsParticipant,
) -> Result<Value> {
    ensure!(
        participant.signing_public_key() == identity.signing_public_key,
        "secure mesh MLS participant signer does not match local identity"
    );
    Ok(json!({
        "identity": identity_to_json(identity),
        "credentialBound": true,
        "signingPublicKeyBase64url": encode_base64url(&participant.signing_public_key())
    }))
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GroupCreateRequest {
    group_id_base64url: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct MemberAddRequest {
    group_id_base64url: String,
    member_key_package_id: String,
    member_key_package_base64url: String,
    member_directory_version: u64,
    member_key_package_version: u64,
    member_identity: PublicIdentityInput,
    member_capability_proof: SignedCapabilityProof,
    untrusted_directory_response: UntrustedDirectoryResponse,
    #[serde(default)]
    allow_interaction: Option<bool>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct MemberRemoveRequest {
    group_id_base64url: String,
    expected_epoch: u64,
    member_identity: PublicIdentityInput,
    #[serde(default)]
    allow_interaction: Option<bool>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GroupJoinRequest {
    group_id_base64url: String,
    inviter_identity: PublicIdentityInput,
    expected_roster_endpoint_ids: Vec<String>,
    trusted_roster: Vec<TrustedIdentityInput>,
    welcome_message_base64url: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct CommitProcessRequest {
    group_id_base64url: String,
    committer_identity: PublicIdentityInput,
    added_member_identity: Option<PublicIdentityInput>,
    removed_member_identity: Option<PublicIdentityInput>,
    trusted_roster: Vec<TrustedIdentityInput>,
    commit_message_base64url: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PayloadSealRequest {
    group_id_base64url: String,
    trusted_roster: Vec<TrustedIdentityInput>,
    context: ContentContextInput,
    payload_kind: String,
    body_base64url: String,
    content_type: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PayloadOpenRequest {
    group_id_base64url: String,
    trusted_sender_identity: PublicIdentityInput,
    trusted_roster: Vec<TrustedIdentityInput>,
    context: ContentContextInput,
    expected_payload_kind: String,
    message_base64url: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublicIdentityInput {
    endpoint_id: String,
    identity_public_key_base64url: String,
    signing_public_key_base64url: String,
    rotation_epoch: u64,
}

impl PublicIdentityInput {
    fn to_identity(&self) -> Result<DeviceTrustPublicIdentity> {
        DeviceTrustPublicIdentity::new(
            self.endpoint_id.clone(),
            decode_key_32(&self.identity_public_key_base64url, "identity public key")?,
            decode_key_32(&self.signing_public_key_base64url, "signing public key")?,
            self.rotation_epoch,
        )
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct TrustedIdentityInput {
    identity: PublicIdentityInput,
    #[serde(default)]
    directory_version: Option<u64>,
    #[serde(default)]
    key_package_version: Option<u64>,
    #[serde(default)]
    key_package_digest: Option<String>,
    #[serde(default)]
    untrusted_directory_response: Option<UntrustedDirectoryResponse>,
}

struct TrustedRoster {
    identities: BTreeMap<String, DeviceTrustPublicIdentity>,
    trust_states: BTreeMap<String, DeviceTrustState>,
}

impl TrustedRoster {
    fn state_for(&self, identity: &DeviceTrustPublicIdentity) -> Result<&DeviceTrustState> {
        let trusted = self.identities.get(&identity.endpoint_id).ok_or_else(|| {
            anyhow!("secure mesh MLS local identity is missing from trusted roster")
        })?;
        ensure!(
            trusted == identity,
            "secure mesh MLS trusted roster local identity binding differs"
        );
        self.trust_states
            .get(&identity.endpoint_id)
            .ok_or_else(|| anyhow!("secure mesh MLS trusted roster state is missing"))
    }
}

fn trusted_roster(
    inputs: &[TrustedIdentityInput],
    config: &Value,
    local_identity: &DeviceTrustPublicIdentity,
) -> Result<TrustedRoster> {
    trusted_roster_with_local_policy(inputs, config, local_identity, true)
}

fn trusted_roster_with_local_policy(
    inputs: &[TrustedIdentityInput],
    config: &Value,
    local_identity: &DeviceTrustPublicIdentity,
    require_local_member: bool,
) -> Result<TrustedRoster> {
    ensure!(
        !inputs.is_empty() && inputs.len() <= 256,
        "secure mesh MLS trusted roster size is invalid"
    );
    let mut identities = BTreeMap::new();
    let mut trust_states = BTreeMap::new();
    for input in inputs {
        let identity = input.identity.to_identity()?;
        if let Some(response) = input.untrusted_directory_response.clone() {
            ensure!(
                identity != *local_identity,
                "secure mesh MLS local directory refresh must use the self-monitor route"
            );
            let directory_version = input.directory_version.ok_or_else(|| {
                anyhow!("secure mesh MLS roster directory version is required with KT evidence")
            })?;
            let key_package_version = input.key_package_version.ok_or_else(|| {
                anyhow!("secure mesh MLS roster KeyPackage version is required with KT evidence")
            })?;
            let key_package_digest = input.key_package_digest.as_deref().ok_or_else(|| {
                anyhow!("secure mesh MLS roster KeyPackage digest is required with KT evidence")
            })?;
            let now = OffsetDateTime::now_utc();
            authorize_member_directory_response(
                config,
                local_identity,
                response.clone(),
                now,
                DirectoryAuthorizationPurpose::MlsKeyPackage,
                &identity,
                directory_version,
                key_package_digest,
                key_package_version,
            )?;
            authorize_member_directory_response(
                config,
                local_identity,
                response,
                now,
                DirectoryAuthorizationPurpose::MlsMemberAdd,
                &identity,
                directory_version,
                key_package_digest,
                key_package_version,
            )?;
        } else {
            ensure!(
                input.directory_version.is_none()
                    && input.key_package_version.is_none()
                    && input.key_package_digest.is_none(),
                "secure mesh MLS roster KT commitment fields require directory evidence"
            );
        }
        let state = if identity == *local_identity {
            DeviceTrustState::Verified
        } else {
            crate::domain::mobile_relay::persisted_mobile_relay_peer_trust_state(
                config,
                local_identity,
                &identity,
            )?
        };
        ensure!(
            identities
                .insert(identity.endpoint_id.clone(), identity.clone())
                .is_none(),
            "secure mesh MLS trusted roster contains a duplicate endpoint"
        );
        trust_states.insert(identity.endpoint_id.clone(), state);
    }
    require_mls_directory_authority_with_local_policy(
        config,
        local_identity,
        &identities,
        require_local_member,
    )?;
    Ok(TrustedRoster {
        identities,
        trust_states,
    })
}

fn reject_caller_asserted_trust(params: &Value) -> Result<()> {
    for field in [
        "memberTrustState",
        "removedMemberTrustState",
        "inviterTrustState",
        "committerTrustState",
        "trustedSenderState",
    ] {
        ensure!(
            params.get(field).is_none(),
            "secure mesh MLS caller-asserted trust state is forbidden"
        );
    }
    if let Some(roster) = params.get("trustedRoster").and_then(Value::as_array) {
        ensure!(
            roster.iter().all(|entry| {
                entry
                    .as_object()
                    .is_some_and(|object| !object.contains_key("trustState"))
            }),
            "secure mesh MLS caller-asserted roster trust state is forbidden"
        );
    }
    Ok(())
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ContentContextInput {
    envelope_id: String,
    message_id: String,
    opaque_mailbox_id: String,
    sender_endpoint_id: String,
    recipient_endpoint_id: String,
    session_id: String,
    created_at: String,
    expires_at: String,
}

impl ContentContextInput {
    fn to_context(&self) -> SecureMeshContentContext {
        SecureMeshContentContext::new(
            &self.envelope_id,
            &self.message_id,
            &self.opaque_mailbox_id,
            &self.sender_endpoint_id,
            &self.recipient_endpoint_id,
            &self.session_id,
            &self.created_at,
            &self.expires_at,
        )
    }
}

fn parse_params<T: for<'de> Deserialize<'de>>(params: &Value) -> Result<T> {
    ensure!(
        params.is_object(),
        "secure mesh MLS action params must be an object"
    );
    serde_json::from_value(params.clone())
        .map_err(|_| anyhow!("secure mesh MLS action params are invalid"))
}

fn parse_payload_kind(value: &str) -> Result<SecureMeshPayloadKind> {
    match value {
        "command" => Ok(SecureMeshPayloadKind::Command),
        "result" => Ok(SecureMeshPayloadKind::ResultPayload),
        "error" => Ok(SecureMeshPayloadKind::Error),
        "file_chunk" => Ok(SecureMeshPayloadKind::FileChunk),
        "file_manifest" => Ok(SecureMeshPayloadKind::FileManifest),
        "service_action" => Ok(SecureMeshPayloadKind::ServiceAction),
        "typing_indicator" => Ok(SecureMeshPayloadKind::TypingIndicator),
        "read_receipt" => Ok(SecureMeshPayloadKind::ReadReceipt),
        _ => Err(anyhow!("secure mesh MLS payload kind is invalid")),
    }
}

fn identity_to_json(identity: &DeviceTrustPublicIdentity) -> Value {
    json!({
        "endpointId": identity.endpoint_id,
        "identityPublicKeyBase64url": encode_base64url(&identity.identity_public_key),
        "signingPublicKeyBase64url": encode_base64url(&identity.signing_public_key),
        "rotationEpoch": identity.rotation_epoch
    })
}

fn decode_key_32(value: &str, label: &str) -> Result<[u8; 32]> {
    let decoded = decode_base64url(value, label, 32)?;
    ensure!(
        decoded.len() == 32,
        "secure mesh MLS {label} length is invalid"
    );
    decoded
        .try_into()
        .map_err(|_| anyhow!("secure mesh MLS {label} length is invalid"))
}

fn decode_base64url(value: &str, label: &str, max_len: usize) -> Result<Vec<u8>> {
    ensure!(
        !value.is_empty() && !value.contains('='),
        "secure mesh {label} encoding is invalid"
    );
    let decoded = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| anyhow!("secure mesh {label} encoding is invalid"))?;
    ensure!(
        !decoded.is_empty() && decoded.len() <= max_len,
        "secure mesh {label} size is invalid"
    );
    ensure!(
        encode_base64url(&decoded) == value,
        "secure mesh {label} encoding is noncanonical"
    );
    Ok(decoded)
}

fn encode_base64url(value: &[u8]) -> String {
    general_purpose::URL_SAFE_NO_PAD.encode(value)
}

fn hex_sha256(value: &[u8]) -> String {
    Sha256::digest(value)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_directory::{
        SecureMeshDirectoryKeyMaterialCommitment, SecureMeshDirectoryLeafClaim,
    };
    use crate::core::secure_mesh_transparency::{
        SecureMeshKtLog, SecureMeshTransparencyLeafBody, directory_scope_commitment,
    };
    use crate::platform::secure_mesh_secret_store::EphemeralSecretStore;
    use rand::rngs::OsRng;

    fn test_identity(endpoint_id: &str) -> DeviceTrustPublicIdentity {
        let identity_key = SigningKey::generate(&mut OsRng);
        let signing_key = SigningKey::generate(&mut OsRng);
        DeviceTrustPublicIdentity::new(
            endpoint_id,
            identity_key.verifying_key().to_bytes(),
            signing_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap()
    }

    fn test_directory_claim(
        member: &DeviceTrustPublicIdentity,
        directory_version: u64,
        mls_key_package_version: u64,
        mls_key_package_digest: &str,
    ) -> SecureMeshDirectoryLeafClaim {
        SecureMeshDirectoryLeafClaim {
            endpoint: SecureMeshTransparencyLeafBody {
                directory_scope_commitment: directory_scope_commitment(
                    "test-tenant",
                    "test-account",
                    "test-workspace",
                ),
                endpoint_id: member.endpoint_id.clone(),
                endpoint_kind: "test".to_string(),
                identity_public_key: member
                    .identity_public_key
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect(),
                signing_public_key: member
                    .signing_public_key
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect(),
                fingerprint: member.fingerprint().unwrap(),
                rotation_epoch: member.rotation_epoch,
                directory_state: "active".to_string(),
                updated_at: "2026-07-12T00:00:00Z".to_string(),
            },
            key_material: SecureMeshDirectoryKeyMaterialCommitment {
                signed_prekey_bundle_digest: hex_sha256(b"test-signed-prekey-bundle"),
                one_time_prekey_batch_digest: hex_sha256(b"test-one-time-prekey-batch"),
                pairwise_prekey_version: 1,
                mls_key_package_digest: mls_key_package_digest.to_string(),
                mls_key_package_version,
            },
            directory_version,
        }
    }

    fn append_test_directory_response(
        log: &mut SecureMeshKtLog,
        claim: &SecureMeshDirectoryLeafClaim,
        issued_at: u64,
        previous_tree_size: Option<u64>,
    ) -> UntrustedDirectoryResponse {
        let index = log
            .append_hashed_directory_leaf(
                &claim.stable_label(),
                claim.version(),
                claim.revoked(),
                claim.leaf_hash().unwrap(),
            )
            .unwrap();
        UntrustedDirectoryResponse {
            claim: claim.clone(),
            inclusion: log.inclusion_proof_at(index, issued_at).unwrap(),
            latest_map: log.map_proof_at(&claim.stable_label(), issued_at).unwrap(),
            consistency: previous_tree_size
                .map(|size| log.consistency_proof_at(size, issued_at).unwrap()),
        }
    }

    fn test_kt_config(log: &SecureMeshKtLog) -> Value {
        let pin = log.pin();
        json!({
            "secureMeshKeyTransparency": {
                "pin": {
                    "logId": pin.log_id(),
                    "keyId": pin.key_id(),
                    "publicKeyHex": pin.public_key_hex(),
                    "provenance": pin.provenance().stable_code()
                },
                "maxSthAgeSeconds": 60,
                "maxFutureSkewSeconds": 2
            }
        })
    }

    #[test]
    fn mls_member_add_uses_explicit_local_pin_and_persisted_endpoint_checkpoint() {
        let root =
            std::env::temp_dir().join(format!("lico-mls-kt-authority-{}", uuid::Uuid::new_v4()));
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));
        let local = test_identity("desktop_gui:mls-kt-local");
        let member = test_identity("mobile:mls-kt-member");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let config = test_kt_config(&log);
        let first_claim = test_directory_claim(&member, 7, 11, &hex_sha256(b"key-package-v1"));
        let first_response = append_test_directory_response(&mut log, &first_claim, 100, None);
        let first = authorize_member_add_directory_response(
            &config,
            &local,
            first_response.clone(),
            OffsetDateTime::from_unix_timestamp(100).unwrap(),
        )
        .unwrap();
        assert_eq!(first.purpose(), DirectoryAuthorizationPurpose::MlsMemberAdd);
        assert_eq!(first.claim().version(), 7);

        let second_claim = test_directory_claim(&member, 8, 12, &hex_sha256(b"key-package-v2"));
        let second_response = append_test_directory_response(&mut log, &second_claim, 101, Some(1));
        let second = authorize_member_add_directory_response(
            &config,
            &local,
            second_response,
            OffsetDateTime::from_unix_timestamp(101).unwrap(),
        )
        .unwrap();
        assert_eq!(second.claim().version(), 8);

        let rollback = authorize_member_add_directory_response(
            &config,
            &local,
            first_response,
            OffsetDateTime::from_unix_timestamp(102).unwrap(),
        )
        .unwrap_err();
        assert!(rollback.to_string().contains("rollback"));

        crate::platform::paths::set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn mls_member_add_has_no_default_kt_pin() {
        let local = test_identity("desktop_gui:mls-kt-no-default");
        let member = test_identity("mobile:mls-kt-no-default-member");
        let mut log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let claim = test_directory_claim(&member, 1, 1, &hex_sha256(b"key-package"));
        let response = append_test_directory_response(&mut log, &claim, 100, None);
        let error = authorize_member_add_directory_response(
            &json!({}),
            &local,
            response,
            OffsetDateTime::from_unix_timestamp(100).unwrap(),
        )
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("local KT pin configuration is required")
        );
        let caller_pin = serde_json::from_value::<MemberAddRequest>(json!({
            "ktLogPin": {"publicKeyHex": "caller-controlled"}
        }))
        .err()
        .expect("caller-provided KT pin must be rejected");
        assert!(caller_pin.to_string().contains("unknown field `ktLogPin`"));
    }

    #[test]
    fn mls_member_add_rejects_response_signed_by_a_non_pinned_log() {
        let root =
            std::env::temp_dir().join(format!("lico-mls-kt-wrong-pin-{}", uuid::Uuid::new_v4()));
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));
        let local = test_identity("desktop_gui:mls-kt-wrong-pin");
        let member = test_identity("mobile:mls-kt-wrong-pin-member");
        let mut response_log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let pinned_log = SecureMeshKtLog::new(SigningKey::generate(&mut OsRng));
        let claim = test_directory_claim(&member, 1, 1, &hex_sha256(b"key-package"));
        let response = append_test_directory_response(&mut response_log, &claim, 100, None);
        let error = authorize_member_add_directory_response(
            &test_kt_config(&pinned_log),
            &local,
            response,
            OffsetDateTime::from_unix_timestamp(100).unwrap(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("signature is invalid"));

        crate::platform::paths::set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn mls_status_keeps_runtime_wiring_distinct_from_production_readiness() {
        let root = std::env::temp_dir().join(format!(
            "lico-mls-status-readiness-{}",
            uuid::Uuid::new_v4()
        ));
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));
        let status = status().unwrap();
        assert_eq!(status["cryptographicRuntimeWired"], true);
        assert_eq!(status["nativeActionPathWired"], true);
        assert_eq!(status["localPersistedPairTrustGateWired"], true);
        assert_eq!(status["authorizedDirectoryLeafKtAuthorityWired"], true);
        assert_eq!(status["currentDirectoryReceiptGateWired"], true);
        assert_eq!(status["clientProductCallSiteAvailable"], false);
        assert_eq!(status["productionPathAvailable"], false);
        assert_eq!(status["productionReady"], false);
        assert_eq!(
            status["blockers"],
            json!([
                "physical_multi_client_matrix_pending",
                "current_key_transparency_receipts_unavailable"
            ])
        );
        crate::platform::paths::set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn mls_product_requests_reject_every_caller_asserted_trust_field() {
        for field in [
            "memberTrustState",
            "removedMemberTrustState",
            "inviterTrustState",
            "committerTrustState",
            "trustedSenderState",
        ] {
            let mut params = json!({});
            params[field] = json!("verified");
            let error = reject_caller_asserted_trust(&params).unwrap_err();
            assert!(error.to_string().contains("caller-asserted trust"));
        }
        let roster_error = reject_caller_asserted_trust(&json!({
            "trustedRoster": [{"identity": {}, "trustState": "verified"}]
        }))
        .unwrap_err();
        assert!(roster_error.to_string().contains("caller-asserted roster"));
    }

    #[test]
    fn mls_join_missing_snapshot_rejects_existing_durable_authority_before_crypto() {
        let root = std::env::temp_dir().join(format!(
            "lico-mls-join-durable-authority-{}",
            uuid::Uuid::new_v4()
        ));
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));
        let identity_key = SigningKey::generate(&mut OsRng);
        let signing_key = SigningKey::generate(&mut OsRng);
        let identity = DeviceTrustPublicIdentity::new(
            "mobile:join-durable-authority",
            identity_key.verifying_key().to_bytes(),
            signing_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        let participant = participant_from_device_identity(&identity, &signing_key).unwrap();
        let group = create_product_group(
            &participant,
            &identity,
            &DeviceTrustState::Verified,
            b"join-durable-authority-group",
        )
        .unwrap();
        let metadata = current_group_metadata(&group, &identity).unwrap();
        reconcile_group_metadata(&group, &identity).unwrap();

        let error = require_group_base_current(
            None,
            &metadata.group_id_hash,
            &metadata.participant_endpoint_id,
        )
        .unwrap_err();
        assert!(error.to_string().contains("diverges from durable metadata"));

        crate::platform::paths::set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn mls_journal_failpoints_drive_reopen_recovery_for_every_mutating_action() {
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
                let root = std::env::temp_dir().join(format!(
                    "lico-mls-journal-failpoint-{}",
                    uuid::Uuid::new_v4()
                ));
                let previous =
                    crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));
                let identity_key = SigningKey::generate(&mut OsRng);
                let signing_key = SigningKey::generate(&mut OsRng);
                let identity = DeviceTrustPublicIdentity::new(
                    format!("desktop_gui:failpoint-{action}-{boundary}"),
                    identity_key.verifying_key().to_bytes(),
                    signing_key.verifying_key().to_bytes(),
                    1,
                )
                .unwrap();
                let mut participant =
                    participant_from_device_identity(&identity, &signing_key).unwrap();
                let group_id = format!("failpoint-group-{action}-{boundary}").into_bytes();
                let mut group = create_product_group(
                    &participant,
                    &identity,
                    &DeviceTrustState::Verified,
                    &group_id,
                )
                .unwrap();
                let base = current_group_metadata(&group, &identity).unwrap();
                reconcile_group_metadata(&group, &identity).unwrap();

                let selected_store: Arc<dyn SecureMeshSecretStore> =
                    Arc::new(EphemeralSecretStore::new());
                let authorization = selected_store
                    .begin_authorized_session(
                        &crate::platform::secure_mesh_secret_store::SecretStoreAuthorizationRequest::new(
                            "Secure Mesh MLS journal failpoint test",
                            4,
                        ),
                    )
                    .unwrap();
                let snapshot_handle = SecretStoreHandle::new(
                    "secure-mesh-mls-journal-failpoint",
                    hex_sha256(format!("{action}:{boundary}").as_bytes()),
                )
                .unwrap();
                participant
                    .save_secret_store_with_session(
                        selected_store.as_ref(),
                        &snapshot_handle,
                        &authorization,
                    )
                    .unwrap();
                group.self_update(&participant).unwrap();
                let expected = current_group_metadata(&group, &identity).unwrap();

                let now = OffsetDateTime::now_utc().unix_timestamp();
                let operation_id = hex_sha256(format!("{action}:{boundary}:op").as_bytes());
                let mut ledger = open_security_ledger().unwrap();
                ledger
                    .begin_operation(
                        &operation_id,
                        action,
                        &hex_sha256(format!("{action}:{boundary}:request").as_bytes()),
                        &identity,
                        now,
                    )
                    .unwrap();
                let prepared =
                    crate::core::secure_mesh_mls_product::empty_prepared_security_inputs(
                        &identity, now,
                    )
                    .unwrap();
                let staged = ledger
                    .stage_operation(
                        &operation_id,
                        &if action == "secure_mesh.mls.member.add" {
                            json!({"ok": true, "group": Value::Null})
                        } else {
                            json!({})
                        },
                        &group_id,
                        Some(&base),
                        &expected,
                        &prepared,
                        now,
                    )
                    .unwrap();
                let mut config = json!({});
                let runtime = LocalParticipantRuntime {
                    config: &mut config,
                    identity: &identity,
                    signing_key: &signing_key,
                    secret_store: &selected_store,
                    authorization: &authorization,
                    snapshot_handle: &snapshot_handle,
                    participant: &mut participant,
                };
                let failpoint_guard = set_journal_failpoint(boundary);
                assert!(
                    std::thread::spawn(move || journal_failpoint(boundary))
                        .join()
                        .unwrap()
                        .is_ok(),
                    "another test thread must not consume this operation's failpoint"
                );
                let error =
                    commit_staged_journaled_operation(&runtime, &mut ledger, staged, &group)
                        .unwrap_err();
                assert!(
                    error
                        .to_string()
                        .contains("injected journal boundary failure")
                );
                drop(failpoint_guard);
                drop(ledger);

                let recovered_participant =
                    SecureMeshMlsParticipant::load_from_secret_store_with_optional_session(
                        crate::core::secure_mesh_mls_product::mls_credential_identity_bytes(
                            &identity,
                        )
                        .unwrap(),
                        identity.signing_public_key,
                        selected_store.as_ref(),
                        &snapshot_handle,
                        Some(&authorization),
                    )
                    .unwrap();
                recover_incomplete_writer_operations(&recovered_participant, &identity).unwrap();
                let mut recovered_ledger = open_security_ledger().unwrap();
                let mut recovered_record =
                    recovered_ledger.operation(&operation_id).unwrap().unwrap();
                if recovered_record.state == SecureMeshMlsOperationState::MetadataReconciled {
                    let recovered_group =
                        SecureMeshMlsGroup::load(&recovered_participant, &group_id).unwrap();
                    resume_journaled_operation(
                        &mut recovered_ledger,
                        recovered_record.clone(),
                        Some(&recovered_group),
                        &identity,
                    )
                    .unwrap();
                    recovered_record = recovered_ledger.operation(&operation_id).unwrap().unwrap();
                }
                if boundary == "after_stage_before_snapshot" {
                    assert_eq!(
                        recovered_record.state,
                        SecureMeshMlsOperationState::Prepared
                    );
                    assert!(
                        recovered_ledger
                            .abort_empty_prepared_operation(&operation_id)
                            .unwrap()
                    );
                } else {
                    assert_eq!(
                        recovered_record.state,
                        SecureMeshMlsOperationState::Delivered
                    );
                }

                crate::platform::paths::set_portable_data_dir_override(previous);
                let _ = std::fs::remove_dir_all(root);
            }
        }
    }

    #[test]
    fn missing_mls_snapshot_purges_only_memory_custody_and_fails_closed_for_persistent_custody() {
        let root = std::env::temp_dir().join(format!(
            "lico-mls-missing-snapshot-{}",
            uuid::Uuid::new_v4()
        ));
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));
        let identity_key = SigningKey::generate(&mut OsRng);
        let signing_key = SigningKey::generate(&mut OsRng);
        let identity = DeviceTrustPublicIdentity::new(
            "mobile:missing-snapshot",
            identity_key.verifying_key().to_bytes(),
            signing_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        let participant = participant_from_device_identity(&identity, &signing_key).unwrap();
        let group = create_product_group(
            &participant,
            &identity,
            &DeviceTrustState::Verified,
            b"missing-snapshot-group",
        )
        .unwrap();
        reconcile_group_metadata(&group, &identity).unwrap();

        let member_identity_key = SigningKey::generate(&mut OsRng);
        let member_signing_key = SigningKey::generate(&mut OsRng);
        let member_identity = DeviceTrustPublicIdentity::new(
            "mobile:replay-ledger-member",
            member_identity_key.verifying_key().to_bytes(),
            member_signing_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        let member_participant =
            participant_from_device_identity(&member_identity, &member_signing_key).unwrap();
        let key_package = member_participant.generate_key_package().unwrap();
        let capability_evaluation = crate::core::secure_mesh_capability::capability_catalog()
            .unwrap()
            .evaluate(
                &crate::core::secure_mesh_capability::mandatory_protocol_facts(
                    crate::core::secure_mesh_capability::CapabilityEvidenceKind::TestFixture,
                )
                .unwrap(),
            )
            .unwrap();
        let now = OffsetDateTime::now_utc();
        let local_proof = sign_mls_keypackage_capability_proof(
            &identity,
            &signing_key,
            &capability_evaluation,
            &key_package,
            now,
        )
        .unwrap();
        let member_proof = sign_mls_keypackage_capability_proof(
            &member_identity,
            &member_signing_key,
            &capability_evaluation,
            &key_package,
            now,
        )
        .unwrap();
        let state_dir = crate::domain::mobile_relay::secure_mesh_mls_state_dir().unwrap();
        let ledger_path = state_dir.join("security-ledger.sqlite3");
        let group_id = group.group_id_bytes().unwrap();
        let base = current_group_metadata(&group, &identity).unwrap();
        let mut expected = base.clone();
        expected.epoch += 1;
        expected.member_count += 1;
        expected.public_state_digest = format!(
            "sha256:{}",
            hex_sha256(b"memory-restart-replay-ledger-expected")
        );
        let prepared = crate::core::secure_mesh_mls_product::prepare_member_add_security_inputs(
            &identity,
            "memory-restart-key-package",
            key_package.as_public_bytes(),
            &expected.group_id_hash,
            &local_proof,
            &member_proof,
            now.unix_timestamp(),
        )
        .unwrap();
        let operation_id = hex_sha256(b"memory-restart-replay-ledger-operation");
        let mut ledger = SecureMeshMlsSecurityLedger::open(&ledger_path).unwrap();
        ledger
            .begin_operation(
                &operation_id,
                "secure_mesh.mls.member.add",
                &hex_sha256(b"memory-restart-replay-ledger-request"),
                &identity,
                now.unix_timestamp(),
            )
            .unwrap();
        let staged = ledger
            .stage_operation(
                &operation_id,
                &json!({}),
                &group_id,
                Some(&base),
                &expected,
                &prepared,
                now.unix_timestamp(),
            )
            .unwrap();
        let committed = ledger
            .commit_operation_crypto(&staged.operation_id, &expected, now.unix_timestamp())
            .unwrap();
        let reconciled = ledger
            .mark_operation_metadata_reconciled(
                &committed.operation_id,
                &json!({"ok": true}),
                now.unix_timestamp(),
            )
            .unwrap();
        ledger
            .mark_operation_delivered(&reconciled.operation_id, now.unix_timestamp())
            .unwrap();
        drop(ledger);

        handle_missing_participant_snapshot(&identity, "memory-only-ephemeral").unwrap();
        let store = crate::core::secure_mesh_mls::SecureMeshMlsDurableStore::open(
            state_dir.join("group-state.sqlite3"),
        )
        .unwrap();
        assert!(
            !store
                .has_records_for_participant(&identity.fingerprint().unwrap())
                .unwrap()
        );
        let mut reopened_ledger = SecureMeshMlsSecurityLedger::open(&ledger_path).unwrap();
        let replay_operation = hex_sha256(b"memory-restart-keypackage-replay-operation");
        reopened_ledger
            .begin_operation(
                &replay_operation,
                "secure_mesh.mls.member.add",
                &hex_sha256(b"memory-restart-keypackage-replay-request"),
                &identity,
                now.unix_timestamp(),
            )
            .unwrap();
        let key_package_replay = reopened_ledger
            .stage_operation(
                &replay_operation,
                &json!({}),
                &group_id,
                Some(&base),
                &expected,
                &prepared,
                now.unix_timestamp(),
            )
            .unwrap_err();
        assert!(key_package_replay.to_string().contains("already consumed"));
        assert!(
            reopened_ledger
                .abort_empty_prepared_operation(&replay_operation)
                .unwrap()
        );
        let proof_prepared =
            crate::core::secure_mesh_mls_product::prepare_capability_security_inputs(
                &identity,
                &local_proof,
                &member_proof,
                now.unix_timestamp(),
            )
            .unwrap();
        let proof_operation = hex_sha256(b"memory-restart-proof-replay-operation");
        reopened_ledger
            .begin_operation(
                &proof_operation,
                "secure_mesh.mls.commit.process",
                &hex_sha256(b"memory-restart-proof-replay-request"),
                &identity,
                now.unix_timestamp(),
            )
            .unwrap();
        let proof_replay = reopened_ledger
            .stage_operation(
                &proof_operation,
                &json!({}),
                &group_id,
                Some(&base),
                &expected,
                &proof_prepared,
                now.unix_timestamp(),
            )
            .unwrap_err();
        assert!(proof_replay.to_string().contains("replay rejected"));
        assert!(
            reopened_ledger
                .abort_empty_prepared_operation(&proof_operation)
                .unwrap()
        );

        reconcile_group_metadata(&group, &identity).unwrap();
        let persistent_error =
            handle_missing_participant_snapshot(&identity, "android-keystore").unwrap_err();
        assert!(persistent_error.to_string().contains("snapshot is missing"));
        let store = crate::core::secure_mesh_mls::SecureMeshMlsDurableStore::open(
            state_dir.join("group-state.sqlite3"),
        )
        .unwrap();
        assert!(
            store
                .has_records_for_participant(&identity.fingerprint().unwrap())
                .unwrap()
        );

        crate::platform::paths::set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }
}
