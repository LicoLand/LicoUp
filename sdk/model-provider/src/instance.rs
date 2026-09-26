//! A provider instance: one configuration generation with the credential
//! resolution it had when it was bound.
//!
//! An instance is created at admission time and never mutated afterwards. That
//! is what makes "a provider update does not change an in-flight request" true
//! by construction: the stream holds this value, not a pointer to the registry,
//! so installing a newer generation cannot retarget it, and revoking a credential
//! cannot strip a handle a running stream was already admitted with.

use licoup_extension_contracts::provider::{ModelCatalogKey, ProviderConfig, ProviderModel};
use std::sync::Arc;

use crate::credentials::{CredentialHandle, CredentialResolution};
use crate::registry::RegisteredProvider;

/// One bound configuration generation.
#[derive(Clone, Debug)]
pub struct ProviderInstance {
    provider: Arc<RegisteredProvider>,
    credential: CredentialResolution,
}

impl ProviderInstance {
    pub(crate) fn new(provider: Arc<RegisteredProvider>, credential: CredentialResolution) -> Self {
        Self {
            provider,
            credential,
        }
    }

    pub fn provider(&self) -> &RegisteredProvider {
        &self.provider
    }

    pub fn config(&self) -> &ProviderConfig {
        self.provider.config()
    }

    pub fn provider_id(&self) -> &str {
        self.provider.id()
    }

    pub fn generation(&self) -> u64 {
        self.provider.generation()
    }

    /// The catalog key of a model of this instance's generation.
    pub fn catalog_key(&self, vendor_model_id: impl Into<String>) -> ModelCatalogKey {
        self.provider.catalog_key(vendor_model_id)
    }

    /// The credential resolution taken at bind time.
    pub fn credential(&self) -> &CredentialResolution {
        &self.credential
    }

    /// The handle a transport bound to this instance may use, when one resolved.
    pub fn credential_handle(&self) -> Option<&CredentialHandle> {
        self.credential.handle()
    }

    /// The models this instance offers from its own configuration.
    pub fn configured_models(&self) -> &[ProviderModel] {
        &self.config().models
    }
}
