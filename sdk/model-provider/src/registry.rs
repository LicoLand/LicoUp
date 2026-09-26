//! The provider registry: configuration generations and atomic snapshots.
//!
//! A provider configuration is not a mutable row. Every accepted configuration
//! becomes a *generation*: an immutable record with a monotonic number, kept in
//! history forever so a stream that was admitted against it can still be
//! observed, cancelled and settled after the provider has moved on.
//!
//! Two admission classes exist. A **preinstalled** configuration is a seed the
//! host ships; it is never mutated by a user configuration, and it is never
//! restored by a removal. A **user** configuration replaces the preinstalled one
//! with the same id for future admissions and receives the next generation.
//! Removing a provider leaves the other providers alone and leaves the catalog
//! without that provider — the seed it shadowed does not reappear, because a
//! removal that silently resurrected an older definition would change future
//! selection behind the user's back.

use licoup_extension_contracts::provider::{ModelCatalogKey, ProviderConfig};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use crate::refusal;

const STAGE: &str = "model-provider/registry";

/// Where a configuration came from.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProviderOrigin {
    /// Shipped with the host as a seed definition.
    Preinstalled,
    /// Installed or edited by the user at runtime.
    UserConfigured,
}

/// One admitted configuration and the generation it belongs to.
#[derive(Debug)]
pub struct RegisteredProvider {
    config: ProviderConfig,
    generation: u64,
    origin: ProviderOrigin,
}

impl RegisteredProvider {
    pub fn config(&self) -> &ProviderConfig {
        &self.config
    }

    pub fn id(&self) -> &str {
        &self.config.id
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn origin(&self) -> ProviderOrigin {
        self.origin
    }

    /// The catalog key a model of this generation is addressed by.
    pub fn catalog_key(&self, vendor_model_id: impl Into<String>) -> ModelCatalogKey {
        self.config.catalog_key(self.generation, vendor_model_id)
    }

    /// A record for another module's unit tests.
    #[cfg(test)]
    pub(crate) fn for_tests(
        config: ProviderConfig,
        generation: u64,
        origin: ProviderOrigin,
    ) -> Self {
        Self {
            config,
            generation,
            origin,
        }
    }
}

/// An immutable view of the providers available for *new* admission.
///
/// A snapshot is taken once and cloned cheaply; a reader that holds one never
/// observes a partially applied update, and two providers in one snapshot are
/// always at their own single current generation.
#[derive(Clone, Debug, Default)]
pub struct RegistrySnapshot {
    epoch: u64,
    providers: BTreeMap<String, Arc<RegisteredProvider>>,
}

impl RegistrySnapshot {
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    pub fn get(&self, provider_id: &str) -> Option<&Arc<RegisteredProvider>> {
        self.providers.get(provider_id)
    }

    pub fn providers(&self) -> impl Iterator<Item = &Arc<RegisteredProvider>> {
        self.providers.values()
    }

    pub fn generation_of(&self, provider_id: &str) -> Option<u64> {
        self.providers.get(provider_id).map(|p| p.generation)
    }

    pub fn len(&self) -> usize {
        self.providers.len()
    }

    pub fn is_empty(&self) -> bool {
        self.providers.is_empty()
    }
}

/// What an accepted installation did.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstallReceipt {
    pub provider_id: String,
    pub generation: u64,
    pub origin: ProviderOrigin,
    pub epoch: u64,
}

/// What a removal did.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoveReceipt {
    pub provider_id: String,
    /// The generation that stopped being current, when the provider was present.
    pub removed_generation: Option<u64>,
    pub epoch: u64,
    /// Always `false`: a removal never restores the seed a user config replaced.
    pub default_restored: bool,
}

#[derive(Debug, Default)]
pub struct ProviderRegistry {
    defaults: BTreeMap<String, Arc<RegisteredProvider>>,
    current: BTreeMap<String, Arc<RegisteredProvider>>,
    history: BTreeMap<(String, u64), Arc<RegisteredProvider>>,
    removed: BTreeSet<String>,
    epoch: u64,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Admit a preinstalled seed configuration.
    ///
    /// A seed never takes the place of a user configuration, and a seed whose id
    /// the user already removed is held back: registration on a later start is
    /// the host's decision to make, not a silent resurrection here. A seed that
    /// arrives after the id already has a generation is recorded at the next
    /// generation, so it can never overwrite another generation's history.
    pub fn install_default(
        &mut self,
        config: ProviderConfig,
    ) -> Result<InstallReceipt, licoup_application::ApplicationFailure> {
        config.validate()?;
        if self.defaults.contains_key(&config.id) {
            return Err(refusal::new("provider_default_conflict", STAGE).with_field("id"));
        }
        let id = config.id.clone();
        let generation = self.next_generation(&id);
        let registered = Arc::new(RegisteredProvider {
            config,
            generation,
            origin: ProviderOrigin::Preinstalled,
        });
        self.defaults.insert(id.clone(), Arc::clone(&registered));
        self.history
            .insert((id.clone(), generation), Arc::clone(&registered));
        if !self.removed.contains(&id) && !self.current.contains_key(&id) {
            self.current.insert(id.clone(), registered);
        }
        self.epoch += 1;
        Ok(InstallReceipt {
            provider_id: id,
            generation,
            origin: ProviderOrigin::Preinstalled,
            epoch: self.epoch,
        })
    }

    /// Admit a user configuration, replacing the current one for its id.
    ///
    /// Validation happens before anything is inserted, so a refused update
    /// leaves the registry exactly as it was and the previous generation keeps
    /// serving new admissions.
    pub fn install_user(
        &mut self,
        config: ProviderConfig,
    ) -> Result<InstallReceipt, licoup_application::ApplicationFailure> {
        config.validate()?;
        let id = config.id.clone();
        let generation = self.next_generation(&id);
        let registered = Arc::new(RegisteredProvider {
            config,
            generation,
            origin: ProviderOrigin::UserConfigured,
        });
        self.history
            .insert((id.clone(), generation), Arc::clone(&registered));
        self.current.insert(id.clone(), registered);
        self.removed.remove(&id);
        self.epoch += 1;
        Ok(InstallReceipt {
            provider_id: id,
            generation,
            origin: ProviderOrigin::UserConfigured,
            epoch: self.epoch,
        })
    }

    /// Remove a provider from new admission.
    ///
    /// History is kept: a stream admitted against a removed provider can still
    /// be observed and settled. The removal is recorded even when no seed exists
    /// for the id, so a later re-registration of seeds by the host cannot
    /// resurrect it inside this registry.
    pub fn remove(&mut self, provider_id: &str) -> RemoveReceipt {
        let removed_generation = self.current.remove(provider_id).map(|p| p.generation);
        self.removed.insert(provider_id.to_owned());
        self.epoch += 1;
        RemoveReceipt {
            provider_id: provider_id.to_owned(),
            removed_generation,
            epoch: self.epoch,
            default_restored: false,
        }
    }

    /// The immutable view new admissions bind to.
    pub fn snapshot(&self) -> RegistrySnapshot {
        RegistrySnapshot {
            epoch: self.epoch,
            providers: self.current.clone(),
        }
    }

    /// One generation from history, whether or not it is current.
    pub fn history_get(
        &self,
        provider_id: &str,
        generation: u64,
    ) -> Option<Arc<RegisteredProvider>> {
        self.history
            .get(&(provider_id.to_owned(), generation))
            .cloned()
    }

    /// Every generation ever admitted, oldest first.
    pub fn generations(&self, provider_id: &str) -> impl Iterator<Item = &Arc<RegisteredProvider>> {
        let id = provider_id.to_owned();
        self.history
            .range((id.clone(), 0)..=(id, u64::MAX))
            .map(|(_, provider)| provider)
    }

    /// The seed configurations as they were registered, never mutated by user
    /// configurations.
    pub fn defaults(&self) -> impl Iterator<Item = &Arc<RegisteredProvider>> {
        self.defaults.values()
    }

    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    fn next_generation(&self, provider_id: &str) -> u64 {
        self.history
            .range((provider_id.to_owned(), 0)..=(provider_id.to_owned(), u64::MAX))
            .next_back()
            .map(|((_, generation), _)| generation + 1)
            .unwrap_or(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use licoup_extension_contracts::provider::{CatalogSource, ProviderModel};

    fn config(id: &str, revision: u32, model: &str) -> ProviderConfig {
        ProviderConfig {
            schema: licoup_extension_contracts::wire::PROVIDER.to_owned(),
            id: id.to_owned(),
            display_name: "Synthetic".to_owned(),
            base_url: "http://127.0.0.1:8098/v1".to_owned(),
            api_dialect: "openai-chat-compatible".to_owned(),
            credential_ref: None,
            config_revision: revision,
            catalog_source: CatalogSource::Static,
            models: vec![ProviderModel {
                id: model.to_owned(),
                display_name: model.to_owned(),
                input_modalities: vec!["text".to_owned()],
                output_modalities: vec!["text".to_owned()],
                tools: None,
                reasoning: None,
                context_tokens: None,
                pricing_source: None,
            }],
            compat: BTreeMap::new(),
            stream_adapter: None,
        }
    }

    #[test]
    fn a_user_config_replaces_the_seed_and_removal_restores_nothing() {
        let mut registry = ProviderRegistry::new();
        registry
            .install_default(config("synthetic.example.seed", 1, "seed-model"))
            .expect("seed");
        let receipt = registry
            .install_user(config("synthetic.example.seed", 2, "user-model"))
            .expect("user config");
        assert_eq!(receipt.generation, 2);
        let snapshot = registry.snapshot();
        assert_eq!(snapshot.generation_of("synthetic.example.seed"), Some(2));
        assert_eq!(
            snapshot.get("synthetic.example.seed").unwrap().origin(),
            ProviderOrigin::UserConfigured
        );

        let removal = registry.remove("synthetic.example.seed");
        assert_eq!(removal.removed_generation, Some(2));
        assert!(!removal.default_restored);
        assert!(registry.snapshot().get("synthetic.example.seed").is_none());
        assert!(registry.snapshot().is_empty());
        // The seed definition itself was never rewritten, and its history remains
        // addressable for settlement.
        assert_eq!(registry.defaults().count(), 1);
        assert!(registry.history_get("synthetic.example.seed", 1).is_some());
        assert!(registry.history_get("synthetic.example.seed", 2).is_some());
    }

    #[test]
    fn generations_are_monotonic_and_never_reused() {
        let mut registry = ProviderRegistry::new();
        assert_eq!(
            registry
                .install_user(config("synthetic.example.a", 1, "one"))
                .unwrap()
                .generation,
            1
        );
        assert_eq!(
            registry
                .install_user(config("synthetic.example.a", 2, "two"))
                .unwrap()
                .generation,
            2
        );
        registry.remove("synthetic.example.a");
        assert_eq!(
            registry
                .install_user(config("synthetic.example.a", 3, "three"))
                .unwrap()
                .generation,
            3
        );
    }

    #[test]
    fn a_refused_update_leaves_the_previous_generation_serving() {
        let mut registry = ProviderRegistry::new();
        registry
            .install_user(config("synthetic.example.a", 1, "one"))
            .unwrap();
        let mut invalid = config("synthetic.example.a", 2, "two");
        invalid.api_dialect = "synthetic.example/native".to_owned();
        let failure = registry.install_user(invalid).expect_err("no adapter");
        assert_eq!(failure.code, "provider_custom_dialect_requires_adapter");
        assert_eq!(registry.epoch(), 1, "a refused update changes nothing");
        let snapshot = registry.snapshot();
        assert_eq!(snapshot.generation_of("synthetic.example.a"), Some(1));
    }

    #[test]
    fn one_providers_removal_leaves_others_untouched() {
        let mut registry = ProviderRegistry::new();
        registry
            .install_user(config("synthetic.example.a", 1, "a-model"))
            .unwrap();
        registry
            .install_user(config("synthetic.example.b", 1, "b-model"))
            .unwrap();
        registry.remove("synthetic.example.a");
        let snapshot = registry.snapshot();
        assert!(snapshot.get("synthetic.example.a").is_none());
        assert_eq!(snapshot.generation_of("synthetic.example.b"), Some(1));
    }

    #[test]
    fn a_late_seed_cannot_overwrite_another_generations_history() {
        let mut registry = ProviderRegistry::new();
        registry
            .install_user(config("synthetic.example.a", 1, "user-model"))
            .expect("user configuration first");
        let receipt = registry
            .install_default(config("synthetic.example.a", 1, "seed-model"))
            .expect("a seed registered later");
        assert_eq!(receipt.generation, 2, "generation 1 is taken");

        let snapshot = registry.snapshot();
        let current = snapshot.get("synthetic.example.a").expect("current");
        assert_eq!(current.origin(), ProviderOrigin::UserConfigured);
        assert_eq!(current.config().models[0].id, "user-model");

        let generation_one = registry
            .history_get("synthetic.example.a", 1)
            .expect("generation 1");
        assert_eq!(generation_one.origin(), ProviderOrigin::UserConfigured);
        assert_eq!(generation_one.config().models[0].id, "user-model");
        let generation_two = registry
            .history_get("synthetic.example.a", 2)
            .expect("generation 2");
        assert_eq!(generation_two.origin(), ProviderOrigin::Preinstalled);
    }
}
