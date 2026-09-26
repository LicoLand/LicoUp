//! The runtime facade: configuration, catalog, credentials and streams in one
//! place.
//!
//! A host holds one [`ProviderRuntime`] and treats every mutation as a small,
//! atomic step: install or remove a configuration, adopt the models a provider
//! discovered, point an alias. Reads take a snapshot; a stream takes the
//! instance it was admitted against and never looks at the registry again.

use licoup_application::{ApplicationFailure, RecoveryAction};
use licoup_extension_contracts::provider::{
    AliasTable, CatalogSource, Dialect, ModelCatalogKey, ProviderConfig, ProviderModel,
};
use serde_json::Value;
use std::collections::BTreeMap;
use std::time::Duration;

use crate::catalog::ModelCatalog;
use crate::credentials::CredentialVault;
use crate::instance::ProviderInstance;
use crate::plugin::{AdapterFactory, AdapterRegistry};
use crate::refusal;
use crate::registry::{InstallReceipt, ProviderRegistry, RegistrySnapshot, RemoveReceipt};
use crate::stream::{DEFAULT_STREAM_TIMEOUT, StreamBinding, StreamRequest, StreamSession};

const STAGE: &str = "model-provider/runtime";

/// Providers, credentials, adapters and the catalogs they produce.
pub struct ProviderRuntime {
    registry: ProviderRegistry,
    credentials: CredentialVault,
    adapters: AdapterRegistry,
    discovered: BTreeMap<(String, u64), Vec<ProviderModel>>,
    aliases: AliasTable,
    invocation: u64,
    stream_timeout: Duration,
}

impl Default for ProviderRuntime {
    fn default() -> Self {
        Self::new()
    }
}

impl ProviderRuntime {
    pub fn new() -> Self {
        Self {
            registry: ProviderRegistry::new(),
            credentials: CredentialVault::new(),
            adapters: AdapterRegistry::default(),
            discovered: BTreeMap::new(),
            aliases: AliasTable::new(),
            invocation: 0,
            stream_timeout: DEFAULT_STREAM_TIMEOUT,
        }
    }

    pub fn registry(&self) -> &ProviderRegistry {
        &self.registry
    }

    pub fn credentials(&self) -> &CredentialVault {
        &self.credentials
    }

    pub fn credentials_mut(&mut self) -> &mut CredentialVault {
        &mut self.credentials
    }

    pub fn set_stream_timeout(&mut self, timeout: Duration) {
        self.stream_timeout = timeout;
    }

    /// Admit a preinstalled seed configuration. The seed list itself is never
    /// mutated by user configurations.
    pub fn install_default(
        &mut self,
        config: ProviderConfig,
    ) -> Result<InstallReceipt, ApplicationFailure> {
        self.registry.install_default(config)
    }

    /// Admit a user configuration, replacing the current generation for its id.
    pub fn install_user(
        &mut self,
        config: ProviderConfig,
    ) -> Result<InstallReceipt, ApplicationFailure> {
        self.registry.install_user(config)
    }

    /// Admit one configuration from its wire form. Key material pasted into the
    /// configuration is refused by the contract before anything is stored.
    pub fn install_from_value(
        &mut self,
        value: Value,
    ) -> Result<InstallReceipt, ApplicationFailure> {
        self.install_user(ProviderConfig::from_value(value)?)
    }

    /// Remove a provider from new admission and drop the aliases that pointed at
    /// it. History and in-flight bindings are untouched, and no seed reappears.
    pub fn remove_provider(&mut self, provider_id: &str) -> RemoveReceipt {
        self.aliases.remove_provider(provider_id);
        self.registry.remove(provider_id)
    }

    /// Record the models a provider discovered, for the generation that is
    /// current now. A later generation starts with no discovered models.
    pub fn adopt_discovered_models(
        &mut self,
        provider_id: &str,
        models: Vec<ProviderModel>,
    ) -> Result<u64, ApplicationFailure> {
        let snapshot = self.registry.snapshot();
        let provider = snapshot.get(provider_id).ok_or_else(|| {
            refusal::actionable(
                "provider_not_configured",
                STAGE,
                "providerId",
                RecoveryAction::InstallOrRetryRuntime,
            )
            .with_presentation_arg("providerId", provider_id)
        })?;
        if provider.config().catalog_source != CatalogSource::Discovered {
            return Err(refusal::actionable(
                "provider_catalog_source_mismatch",
                STAGE,
                "catalogSource",
                RecoveryAction::CorrectRequest,
            )
            .with_presentation_arg("providerId", provider_id));
        }
        for model in &models {
            model.validate()?;
        }
        self.discovered
            .insert((provider_id.to_owned(), provider.generation()), models);
        Ok(provider.generation())
    }

    /// Point an alias at a model that exists in the current catalog.
    ///
    /// This is the only way an alias changes what it selects: replacing it is an
    /// explicit act, and nothing rebinds it when a provider updates.
    pub fn set_alias(
        &mut self,
        name: &str,
        reference: &str,
    ) -> Result<ModelCatalogKey, ApplicationFailure> {
        if name.is_empty() {
            return Err(refusal::new("provider_alias_invalid", STAGE).with_field("alias"));
        }
        let key = self.catalog().resolve(reference)?.key().clone();
        self.aliases.set(name, key.clone());
        Ok(key)
    }

    /// The catalog of the current generation, with aliases as they stand now.
    pub fn catalog(&self) -> ModelCatalog {
        ModelCatalog::build(
            &self.registry.snapshot(),
            &self.discovered,
            self.aliases.clone(),
        )
    }

    /// The current snapshot, for callers that need provider facts without a
    /// catalog.
    pub fn snapshot(&self) -> RegistrySnapshot {
        self.registry.snapshot()
    }

    /// Bind one generation of a provider, by exact catalog key.
    ///
    /// This is the settlement path: it resolves a generation that may no longer
    /// be current, together with the credential scope that generation resolves
    /// today, so an in-flight or late-settling invocation never loses its
    /// identity.
    pub fn instance_for_key(
        &self,
        key: &ModelCatalogKey,
    ) -> Result<ProviderInstance, ApplicationFailure> {
        let provider = self
            .registry
            .history_get(&key.provider_id, key.provider_generation)
            .ok_or_else(|| {
                refusal::actionable(
                    "provider_generation_unknown",
                    STAGE,
                    "providerGeneration",
                    RecoveryAction::CorrectRequest,
                )
                .with_presentation_arg("providerId", &key.provider_id)
                .with_presentation_arg("providerGeneration", &key.provider_generation.to_string())
            })?;
        let credential = self.credentials.resolve(provider.config());
        Ok(ProviderInstance::new(provider, credential))
    }

    /// Admit one stream.
    ///
    /// The selection is resolved against the current catalog, the instance is
    /// bound once with its credential scope, and the adapter is chosen by the
    /// dialect: a registered compatible transport for a published compatible
    /// dialect, or the adapter registered under the configuration's own
    /// `streamAdapter` id for anything else.
    pub fn open_stream(
        &mut self,
        selection: &str,
        principal: &str,
        effect_ref: &str,
        input: Value,
    ) -> Result<StreamSession, ApplicationFailure> {
        if principal.is_empty() || effect_ref.is_empty() {
            return Err(refusal::actionable(
                "provider_stream_request_invalid",
                STAGE,
                "request",
                RecoveryAction::CorrectRequest,
            ));
        }
        let catalog = self.catalog();
        let resolved = catalog.resolve(selection)?.key().clone();
        let provider = catalog
            .provider(&resolved.provider_id)
            .cloned()
            .ok_or_else(|| {
                refusal::actionable(
                    "provider_not_configured",
                    STAGE,
                    "selection",
                    RecoveryAction::InstallOrRetryRuntime,
                )
                .with_presentation_arg("providerId", &resolved.provider_id)
            })?;
        let credential = self.credentials.resolve(provider.config());
        let instance = ProviderInstance::new(provider, credential);

        let factory = match instance.config().dialect() {
            Dialect::Compatible => {
                let dialect = instance.config().api_dialect.clone();
                self.adapters.compatible(&dialect).ok_or_else(|| {
                    refusal::actionable(
                        "provider_compatible_transport_unavailable",
                        STAGE,
                        "apiDialect",
                        RecoveryAction::InstallOrRetryRuntime,
                    )
                    .with_presentation_arg("apiDialect", &dialect)
                })?
            }
            Dialect::Custom => {
                let adapter = instance.config().stream_adapter.clone().unwrap_or_default();
                self.adapters.custom(&adapter).ok_or_else(|| {
                    refusal::actionable(
                        "provider_stream_adapter_unavailable",
                        STAGE,
                        "streamAdapter",
                        RecoveryAction::InstallOrRetryRuntime,
                    )
                    .with_presentation_arg("streamAdapter", &adapter)
                })?
            }
        };

        self.invocation += 1;
        let request = StreamRequest {
            invocation_ref: format!("stream-{}", self.invocation),
            effect_ref: effect_ref.to_owned(),
            principal: principal.to_owned(),
            key: resolved,
            input,
        };
        let binding = StreamBinding::new(request, instance);
        let adapter = factory()?;
        StreamSession::start(binding, adapter, self.stream_timeout)
    }

    /// Register the transport for a published compatible dialect.
    pub fn register_compatible_adapter(
        &mut self,
        dialect: impl Into<String>,
        factory: AdapterFactory,
    ) -> Option<AdapterFactory> {
        self.adapters.register_compatible(dialect, factory)
    }

    /// Register the adapter a custom dialect's configuration names.
    pub fn register_custom_adapter(
        &mut self,
        adapter: impl Into<String>,
        factory: AdapterFactory,
    ) -> Option<AdapterFactory> {
        self.adapters.register_custom(adapter, factory)
    }

    pub fn compatible_dialects(&self) -> impl Iterator<Item = &str> {
        self.adapters.compatible_dialects()
    }

    pub fn custom_adapters(&self) -> impl Iterator<Item = &str> {
        self.adapters.custom_adapters()
    }
}
