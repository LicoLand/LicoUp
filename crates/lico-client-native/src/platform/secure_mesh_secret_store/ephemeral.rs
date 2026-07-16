use std::collections::HashMap;
use std::sync::Mutex;

use anyhow::{Result, anyhow, ensure};
use zeroize::Zeroizing;

use crate::core::secure_mesh_capability::{CapabilityFact, CapabilityFactState};
use crate::core::secure_mesh_secret_store::{
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession, SecretStoreHandle,
    SecureMeshSecretStore, is_persistable_secret,
};

pub struct EphemeralSecretStore {
    secrets: Mutex<HashMap<String, Zeroizing<String>>>,
    capability_facts: Mutex<Vec<CapabilityFact>>,
    #[cfg(test)]
    authorization_sessions: Mutex<Vec<SecretStoreAuthorizationSession>>,
}

impl Default for EphemeralSecretStore {
    fn default() -> Self {
        Self {
            secrets: Mutex::new(HashMap::new()),
            capability_facts: Mutex::new(Vec::new()),
            #[cfg(test)]
            authorization_sessions: Mutex::new(Vec::new()),
        }
    }
}

impl EphemeralSecretStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_unavailable_platform_facts(capability_facts: Vec<CapabilityFact>) -> Result<Self> {
        ensure!(
            capability_facts
                .iter()
                .all(|fact| fact.state != CapabilityFactState::Supported),
            "ephemeral custody cannot claim a supported persistent-store capability"
        );
        Ok(Self {
            capability_facts: Mutex::new(capability_facts),
            ..Self::default()
        })
    }

    pub fn set_unavailable_platform_facts(
        &self,
        capability_facts: Vec<CapabilityFact>,
    ) -> Result<()> {
        ensure!(
            capability_facts
                .iter()
                .all(|fact| fact.state != CapabilityFactState::Supported),
            "ephemeral custody cannot claim a supported persistent-store capability"
        );
        *self
            .capability_facts
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral capability state is unavailable"))? =
            capability_facts;
        Ok(())
    }

    #[cfg(test)]
    pub fn authorization_session_count(&self) -> usize {
        self.authorization_sessions
            .lock()
            .map(|sessions| sessions.len())
            .unwrap_or_default()
    }

    #[cfg(test)]
    pub fn authorization_session_reasons(&self) -> Vec<String> {
        self.authorization_sessions
            .lock()
            .map(|sessions| {
                sessions
                    .iter()
                    .map(|session| session.reason().to_string())
                    .collect()
            })
            .unwrap_or_default()
    }

    #[cfg(test)]
    pub fn authorization_session_operation_counts(&self) -> Vec<usize> {
        self.authorization_sessions
            .lock()
            .map(|sessions| {
                sessions
                    .iter()
                    .map(SecretStoreAuthorizationSession::operation_count)
                    .collect()
            })
            .unwrap_or_default()
    }

    #[cfg(test)]
    pub fn authorization_session_allow_interactions(&self) -> Vec<bool> {
        self.authorization_sessions
            .lock()
            .map(|sessions| {
                sessions
                    .iter()
                    .map(SecretStoreAuthorizationSession::allow_interaction)
                    .collect()
            })
            .unwrap_or_default()
    }

    #[cfg(test)]
    pub fn authorization_session_consumed_operation_counts(&self) -> Vec<usize> {
        self.authorization_sessions
            .lock()
            .map(|sessions| {
                sessions
                    .iter()
                    .map(SecretStoreAuthorizationSession::consumed_operation_count)
                    .collect()
            })
            .unwrap_or_default()
    }
}

impl SecureMeshSecretStore for EphemeralSecretStore {
    fn backend(&self) -> &'static str {
        "memory-only-ephemeral"
    }

    fn supported(&self) -> bool {
        true
    }

    fn capability_facts(&self) -> Result<Vec<CapabilityFact>> {
        Ok(self
            .capability_facts
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral capability state is unavailable"))?
            .clone())
    }

    fn begin_authorized_session(
        &self,
        request: &SecretStoreAuthorizationRequest,
    ) -> Result<SecretStoreAuthorizationSession> {
        let session = SecretStoreAuthorizationSession::new(self.backend(), request, false, false)
            .with_capability_report(self.capability_evaluation()?.report());
        #[cfg(test)]
        self.authorization_sessions
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral secret store state is unavailable"))?
            .push(session.clone());
        Ok(session)
    }

    fn set_secret(&self, handle: &SecretStoreHandle, secret: &str) -> Result<()> {
        ensure!(
            is_persistable_secret(secret),
            "secure mesh ephemeral secret value is invalid"
        );
        self.secrets
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral secret store state is unavailable"))?
            .insert(handle.account(), Zeroizing::new(secret.to_string()));
        Ok(())
    }

    fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<String>> {
        Ok(self
            .secrets
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral secret store state is unavailable"))?
            .get(&handle.account())
            .map(|secret| secret.to_string()))
    }

    fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()> {
        self.secrets
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral secret store state is unavailable"))?
            .remove(&handle.account());
        Ok(())
    }
}
