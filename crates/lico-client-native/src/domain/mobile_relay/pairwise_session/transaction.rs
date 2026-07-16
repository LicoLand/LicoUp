use super::store::mobile_relay_pairwise_store;
use crate::core::secure_mesh_pairwise::{
    SecureMeshPairwiseDurableRecord, SecureMeshPairwiseDurableStore, SecureMeshPairwiseSession,
};
use crate::domain::mobile_relay::endpoint_trust::{local_endpoint_state, now_iso, session_id};
use crate::domain::mobile_relay::secret_custody::{
    RuntimeSecretContext, ensure_secure_mesh_protected_operation_allowed,
};
use crate::platform::secure_mesh_secret_store::{
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession,
};
use anyhow::{Result, anyhow};
use serde_json::Value;

pub(in crate::domain::mobile_relay) struct MobileRelayPairwiseOperation {
    pub(super) store: SecureMeshPairwiseDurableStore,
    pub(super) record: SecureMeshPairwiseDurableRecord,
    pub(super) session: SecureMeshPairwiseSession,
    secret_store_session: SecretStoreAuthorizationSession,
}

impl MobileRelayPairwiseOperation {
    pub(super) fn commit(&mut self) -> Result<()> {
        self.record = self.store.commit_session_with_authorized_session(
            &self.record,
            &self.session,
            now_iso(),
            &self.secret_store_session,
        )?;
        Ok(())
    }
}

#[cfg(test)]
pub(in crate::domain::mobile_relay) fn mobile_relay_pairwise_operation(
    config: &Value,
    reason: &'static str,
    operation_count: usize,
) -> Result<MobileRelayPairwiseOperation> {
    mobile_relay_pairwise_operation_with_authorized_session(config, reason, operation_count, None)
}

pub(in crate::domain::mobile_relay) fn mobile_relay_pairwise_operation_with_runtime_secret_context(
    config: &Value,
    reason: &'static str,
    operation_count: usize,
    secret_context: &mut RuntimeSecretContext,
) -> Result<MobileRelayPairwiseOperation> {
    let shared_session = secret_context.shared_authorization_session()?;
    mobile_relay_pairwise_operation_with_authorized_session(
        config,
        reason,
        operation_count,
        shared_session.as_ref(),
    )
}

pub(in crate::domain::mobile_relay) fn mobile_relay_pairwise_operation_with_authorized_session(
    config: &Value,
    reason: &'static str,
    operation_count: usize,
    authorized_session: Option<&SecretStoreAuthorizationSession>,
) -> Result<MobileRelayPairwiseOperation> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let store = mobile_relay_pairwise_store()?;
    let endpoint = local_endpoint_state(config)?;
    let session_id = session_id(config)?;
    if let Some(record) = store.read_record(&session_id, &endpoint.endpoint_id)? {
        let secret_store_session = authorized_session
            .filter(|session| session.backend() == store.secret_store_backend())
            .cloned()
            .map(Ok)
            .unwrap_or_else(|| {
                store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                    reason,
                    operation_count,
                ))
            })?;
        let session = store
            .load_session_with_authorized_session(
                &session_id,
                &endpoint.endpoint_id,
                &secret_store_session,
            )?
            .ok_or_else(|| anyhow!("mobile relay pairwise session record is missing"))?;
        return Ok(MobileRelayPairwiseOperation {
            store,
            record,
            session,
            secret_store_session,
        });
    }
    Err(anyhow!(
        "mobile relay pairwise session is not initialized; re-pairing is required"
    ))
}
