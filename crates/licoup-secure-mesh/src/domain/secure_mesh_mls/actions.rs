use std::collections::BTreeMap;

use anyhow::{Result, anyhow, ensure};
use serde_json::{Value, json};

use crate::core::secure_mesh_capability::CapabilityEvaluation;
use licoup_foundation::core::secure_mesh::{
    SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION, SECURE_MESH_MLS_CIPHER_SUITE,
};
use crate::core::secure_mesh_mls_product::SECURE_MESH_MLS_PRODUCT_POLICY_STATUS;

use super::commit_process::commit_process;
use super::directory_authorization::require_mls_directory_authority;
use super::group_create::group_create;
use super::group_join::group_join;
use super::member_mutation::{member_add, member_remove};
use super::participant_key_package::{key_package_create, participant_ensure};
use super::participant_runtime::SecureMeshMlsCustody;
use super::payload::{payload_open, payload_seal};
use super::state::public_directory_context;

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

/// What the status projection reads from the endpoint it reports on: the
/// evaluation of the custody the endpoint actually selected, and the persisted
/// endpoint configuration document.
///
/// The status projection is deliberately non-interactive. It begins no
/// authorization session and reads no key material, so the caller supplies the
/// values rather than opening custody for it.
pub struct SecureMeshMlsStatusContext<'a> {
    pub capability_evaluation: &'a CapabilityEvaluation,
    pub config: &'a Value,
}

/// The endpoint context one native MLS action runs under.
///
/// `secure_mesh.mls.status` reads [`SecureMeshMlsStatusContext`]; every other
/// action runs inside the [`SecureMeshMlsCustody`] the composition above this
/// crate opened.
pub enum SecureMeshMlsActionContext<'a> {
    Status(SecureMeshMlsStatusContext<'a>),
    Participant(SecureMeshMlsCustody<'a>),
}

/// Pure wiring probe for process-startup and mobile FFI health checks.
///
/// Product readiness belongs to [`status`], which intentionally evaluates the
/// persisted relay and transparency state. Runtime loading probes must remain
/// side-effect free so they cannot create client state beside an executable or
/// mutate an installed application bundle.
pub fn runtime_binding_wired() -> bool {
    licoup_foundation::core::secure_mesh::SECURE_MESH_MLS_STATUS
        .contains("mlkem1024_epoch_hybrid_payload")
        && crate::core::secure_mesh_mls::runtime_crypto_self_test()
        && SECURE_MESH_MLS_PRODUCT_POLICY_STATUS.contains("cryptographic_native_path_wired")
        && SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION.starts_with("licomesh.secure-mesh.group-mls.")
        && SECURE_MESH_MLS_CIPHER_SUITE.starts_with("MLS_")
        && SECURE_MESH_MLS_NATIVE_ACTIONS.len() >= 10
}

/// Runs one native MLS action under the endpoint context the caller supplies.
pub fn dispatch(
    action: &str,
    params: &Value,
    context: SecureMeshMlsActionContext<'_>,
) -> Result<Value> {
    if action != "secure_mesh.mls.status" {
        crate::core::secure_mesh_transparency::ensure_secure_mesh_protected_operation_allowed()?;
    }
    match context {
        SecureMeshMlsActionContext::Status(status_context) => {
            ensure!(
                action == "secure_mesh.mls.status",
                "secure mesh MLS participant action requires endpoint custody"
            );
            status(status_context)
        }
        SecureMeshMlsActionContext::Participant(custody) => match action {
            "secure_mesh.mls.participant.ensure" => participant_ensure(params, custody),
            "secure_mesh.mls.keyPackage.create" => key_package_create(params, custody),
            "secure_mesh.mls.group.create" => group_create(params, custody),
            "secure_mesh.mls.member.add" => member_add(params, custody),
            "secure_mesh.mls.member.remove" => member_remove(params, custody),
            "secure_mesh.mls.group.join" => group_join(params, custody),
            "secure_mesh.mls.commit.process" => commit_process(params, custody),
            "secure_mesh.mls.payload.seal" => payload_seal(params, custody),
            "secure_mesh.mls.payload.open" => payload_open(params, custody),
            "secure_mesh.mls.status" => Err(anyhow!(
                "secure mesh MLS status projection requires the endpoint status context"
            )),
            _ => Err(anyhow!("secure mesh MLS native action is unsupported")),
        },
    }
}

pub fn status(context: SecureMeshMlsStatusContext<'_>) -> Result<Value> {
    let evaluation = context.capability_evaluation;
    let directory_readiness = (|| {
        let identity = public_directory_context(context.config)?;
        let roster = BTreeMap::from([(identity.endpoint_id.clone(), identity.clone())]);
        require_mls_directory_authority(context.config, &identity, &roster)
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
        "rawProoflessApiExposed": false
    }))
}
