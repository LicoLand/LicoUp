use licoup_secure_mesh::core::secure_mesh_capability::{
    CapabilityEvaluation, CapabilityEvaluationReport, CustodyRestartSemantics,
    SecretCustodyStrategy, SecurityCapability,
};
use licoup_secure_mesh::core::secure_mesh_transparency::KT_JSON_SAFE_INTEGER_MAX;
use licoup_secure_mesh::core::secure_mesh_trust::DeviceTrustPublicIdentity;
use licoup_client_state::ClientStateStore;
use licoup_secure_mesh::platform::secure_mesh_secret_store::{
    EphemeralSecretStore, PlatformSecretStore, SecretClassPersistenceProof,
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession, SecretStoreHandle,
    SecureMeshSecretStore, platform_linux_secret_service_probe_snapshot,
    platform_native_secret_store_supported,
};
use anyhow::{Context, Result, anyhow, ensure};
use ed25519_dalek::SigningKey;
use serde_json::{Map, Value, json};
use std::cell::RefCell;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

use super::config::{default_config, normalize_config, prepare_station_fields_for_persistence};
use super::endpoint_trust::{
    ensure_mobile_relay_endpoint_descriptor, ensure_mobile_relay_endpoint_material,
    local_endpoint_state, sha256_hex,
};
// The durable MLS state directory is secure-mesh state and lives in
// `licoup-secure-mesh`; the relay reaches it at that crate's path.
use licoup_secure_mesh::domain::secure_mesh_mls::state_dir as secure_mesh_mls_state_dir;
use super::pairwise_session::{mobile_relay_pairwise_store, mobile_relay_pairwise_store_path};
use super::support::{bool_param, text_param};

mod cleanup;
mod config_store;
mod persistence;
mod presentation;
mod reset_guard;
mod runtime;
mod runtime_secret_material;
mod secret_material;
mod self_test;

#[cfg(test)]
mod tests;

pub(in crate::domain::mobile_relay) use cleanup::*;
pub(in crate::domain::mobile_relay) use config_store::*;
pub(in crate::domain::mobile_relay) use persistence::*;
pub(in crate::domain::mobile_relay) use presentation::*;
pub(in crate::domain::mobile_relay) use reset_guard::*;
pub(in crate::domain::mobile_relay) use runtime::*;
#[cfg(any(test, feature = "test-support"))]
pub use runtime_secret_material::test_runtime_secret_material;
pub(in crate::domain::mobile_relay) use runtime_secret_material::*;
pub(in crate::domain::mobile_relay) use secret_material::*;

pub fn with_pairwise_secret_store_override<T>(
    store: Arc<dyn SecureMeshSecretStore>,
    operation: impl FnOnce() -> Result<T>,
) -> Result<T> {
    runtime::with_pairwise_secret_store_override_in(store, operation)
}

pub fn with_mobile_relay_secret_store_override<T>(
    store: Arc<dyn SecureMeshSecretStore>,
    operation: impl FnOnce() -> Result<T>,
) -> Result<T> {
    runtime::with_mobile_relay_secret_store_override_in(store, operation)
}

pub fn selected_mobile_relay_capability_evaluation() -> Result<CapabilityEvaluation> {
    runtime::selected_mobile_relay_capability_evaluation_in()
}

use licoup_secure_mesh::domain::secure_mesh_mls::{
    SECURE_MESH_MLS_PARTICIPANT_SECRET_STORE_OPERATIONS, SecureMeshMlsActionContext,
    SecureMeshMlsCustody, SecureMeshMlsStatusContext,
};

/// Runs one native MLS action against this endpoint's selected custody.
///
/// The status projection is non-interactive and reads only what the endpoint
/// already selected and persisted; every other action runs inside an authorized
/// custody session this composition opens, because only it knows the endpoint
/// configuration, the local identity and the selected secret store. The action
/// surface itself belongs to `licoup-secure-mesh`, which is why each variant is
/// handed the context rather than reaching for it.
pub fn dispatch_secure_mesh_mls_action(action: &str, params: &Value) -> Result<Value> {
    if action == "secure_mesh.mls.status" {
        let capability_evaluation = runtime::selected_mobile_relay_capability_evaluation_in()?;
        let config = config_store::load_config_without_persistence()?;
        return licoup_secure_mesh::domain::secure_mesh_mls::dispatch(
            action,
            params,
            SecureMeshMlsActionContext::Status(SecureMeshMlsStatusContext {
                capability_evaluation: &capability_evaluation,
                config: &config,
            }),
        );
    }

    with_secure_mesh_mls_participant(
        params,
        SECURE_MESH_MLS_PARTICIPANT_SECRET_STORE_OPERATIONS,
        |config, identity, signing_key, secret_store, authorization, namespace| {
            let response = licoup_secure_mesh::domain::secure_mesh_mls::dispatch(
                action,
                params,
                SecureMeshMlsActionContext::Participant(SecureMeshMlsCustody {
                    config,
                    identity,
                    signing_key,
                    secret_store,
                    authorization,
                    namespace,
                }),
            )?;
            // A new KeyPackage republishes this endpoint's directory leaf, and
            // the authority that publishes it is this relay's, so the refresh
            // runs here, before the configuration the closure just wrote is
            // persisted. `cfg(test)` is false for a dependency, so the consumer
            // that drives this path from its own test build carries the seam as
            // this crate's `test-support` feature — the same configuration that
            // exposes the refresh. The refresh itself is a no-op unless the
            // endpoint's KT pin is the local acceptance mock, so a build that
            // carries the feature without the mock authority changes nothing.
            #[cfg(any(test, feature = "test-support"))]
            if action == "secure_mesh.mls.keyPackage.create" {
                crate::domain::mobile_relay::refresh_secure_mesh_mls_test_directory_authority(
                    config,
                )?;
            }
            Ok(response)
        },
    )
}

pub(crate) fn with_secure_mesh_mls_participant<T>(
    params: &Value,
    additional_secret_store_operations: usize,
    operation: impl FnOnce(
        &mut Value,
        &DeviceTrustPublicIdentity,
        &SigningKey,
        &Arc<dyn SecureMeshSecretStore>,
        &SecretStoreAuthorizationSession,
        &str,
    ) -> Result<T>,
) -> Result<T> {
    runtime::with_secure_mesh_mls_participant_in(
        params,
        additional_secret_store_operations,
        operation,
    )
}


pub fn e2ee_secret_store_cleanup(params: &Value) -> Result<Value> {
    cleanup::e2ee_secret_store_cleanup_in(params)
}

pub fn e2ee_secret_store_self_test(params: &Value) -> Result<Value> {
    self_test::e2ee_secret_store_self_test_in(params)
}
