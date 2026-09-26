//! The model catalog a reader sees, and the two ways a model is selected.
//!
//! Every entry is addressed by the published tuple — `(providerId,
//! providerGeneration, vendorModelId)` — and carries the `source` its
//! configuration declared (`static` for a list in the configuration,
//! `discovered` for a provider that answers `modelProvider.models`). A human
//! alias is a separate mapping onto one of those tuples, so two providers may
//! both publish a model called `mini` without either taking the other's name.
//!
//! A catalog is built from exactly one [`RegistrySnapshot`], so no reader sees a
//! mixture of generations. An alias that points at a generation that is no
//! longer current is refused for new admission with an actionable refusal —
//! replacing the alias explicitly is what changes future selection.

use licoup_application::{ApplicationFailure, RecoveryAction, is_namespaced};
use licoup_extension_contracts::provider::{
    AliasTable, CatalogSource, ModelCatalogKey, ProviderModel,
};
use std::collections::BTreeMap;
use std::sync::Arc;

use crate::refusal;
use crate::registry::{ProviderOrigin, RegisteredProvider, RegistrySnapshot};

const STAGE: &str = "model-provider/catalog";

/// One selectable model.
#[derive(Clone, Debug, PartialEq)]
pub struct CatalogEntry {
    pub key: ModelCatalogKey,
    pub source: CatalogSource,
    pub model: ProviderModel,
    pub provider_display_name: String,
    pub origin: ProviderOrigin,
}

/// A resolved selection.
#[derive(Clone, Debug, PartialEq)]
pub enum Selection {
    /// A human alias, which resolved to a catalog key.
    Alias { name: String, key: ModelCatalogKey },
    /// A namespaced reference, `providerId/vendorModelId`.
    Namespaced { key: ModelCatalogKey },
}

impl Selection {
    pub fn key(&self) -> &ModelCatalogKey {
        match self {
            Self::Alias { key, .. } | Self::Namespaced { key } => key,
        }
    }

    pub fn alias(&self) -> Option<&str> {
        match self {
            Self::Alias { name, .. } => Some(name),
            Self::Namespaced { .. } => None,
        }
    }
}

/// An immutable catalog view.
#[derive(Clone, Debug)]
pub struct ModelCatalog {
    epoch: u64,
    entries: Vec<CatalogEntry>,
    index: BTreeMap<ModelCatalogKey, usize>,
    providers: BTreeMap<String, Arc<RegisteredProvider>>,
    aliases: AliasTable,
}

impl ModelCatalog {
    /// Build the catalog of one snapshot.
    ///
    /// `discovered` holds the models a provider answered with, keyed by
    /// `(providerId, providerGeneration)` so a new generation never inherits a
    /// previous discovery.
    pub fn build(
        snapshot: &RegistrySnapshot,
        discovered: &BTreeMap<(String, u64), Vec<ProviderModel>>,
        aliases: AliasTable,
    ) -> Self {
        let mut entries: Vec<CatalogEntry> = Vec::new();
        let mut index: BTreeMap<ModelCatalogKey, usize> = BTreeMap::new();
        let mut providers = BTreeMap::new();
        for provider in snapshot.providers() {
            providers.insert(provider.id().to_owned(), Arc::clone(provider));
            let config = provider.config();
            let (source, models): (CatalogSource, &[ProviderModel]) = match config.catalog_source {
                CatalogSource::Static => (CatalogSource::Static, config.models.as_slice()),
                CatalogSource::Discovered => (
                    CatalogSource::Discovered,
                    discovered
                        .get(&(provider.id().to_owned(), provider.generation()))
                        .map(Vec::as_slice)
                        .unwrap_or(&[]),
                ),
            };
            for model in models {
                let entry = CatalogEntry {
                    key: provider.catalog_key(model.id.clone()),
                    source,
                    model: model.clone(),
                    provider_display_name: config.display_name.clone(),
                    origin: provider.origin(),
                };
                match index.get(&entry.key) {
                    Some(position) => entries[*position] = entry,
                    None => {
                        index.insert(entry.key.clone(), entries.len());
                        entries.push(entry);
                    }
                }
            }
        }
        Self {
            epoch: snapshot.epoch(),
            entries,
            index,
            providers,
            aliases,
        }
    }

    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    pub fn entries(&self) -> &[CatalogEntry] {
        &self.entries
    }

    pub fn get(&self, key: &ModelCatalogKey) -> Option<&CatalogEntry> {
        self.index.get(key).map(|position| &self.entries[*position])
    }

    pub fn aliases(&self) -> &AliasTable {
        &self.aliases
    }

    pub fn provider(&self, provider_id: &str) -> Option<&Arc<RegisteredProvider>> {
        self.providers.get(provider_id)
    }

    pub fn generation_of(&self, provider_id: &str) -> Option<u64> {
        self.providers.get(provider_id).map(|p| p.generation())
    }

    /// Resolve a user-facing reference: a namespaced `providerId/vendorModelId`,
    /// or an alias name.
    pub fn resolve(&self, reference: &str) -> Result<Selection, ApplicationFailure> {
        if reference.is_empty() {
            return Err(refusal::new("provider_selection_invalid", STAGE).with_field("selection"));
        }
        if let Some((provider_part, model_part)) = reference.split_once('/') {
            if !is_namespaced(provider_part) || model_part.is_empty() {
                return Err(
                    refusal::new("provider_selection_invalid", STAGE).with_field("selection")
                );
            }
            let provider = self.providers.get(provider_part).ok_or_else(|| {
                refusal::actionable(
                    "provider_not_configured",
                    STAGE,
                    "selection",
                    RecoveryAction::InstallOrRetryRuntime,
                )
                .with_presentation_arg("providerId", provider_part)
            })?;
            let key = provider.catalog_key(model_part);
            if self.index.contains_key(&key) {
                return Ok(Selection::Namespaced { key });
            }
            return Err(refusal::actionable(
                "model_not_in_catalog",
                STAGE,
                "selection",
                RecoveryAction::CorrectRequest,
            )
            .with_presentation_arg("vendorModelId", model_part)
            .with_presentation_arg("providerId", provider_part));
        }

        let Some(target) = self.aliases.resolve(reference) else {
            return Err(refusal::actionable(
                "provider_alias_unknown",
                STAGE,
                "selection",
                RecoveryAction::CorrectRequest,
            )
            .with_presentation_arg("alias", reference));
        };
        if self.index.contains_key(target) {
            return Ok(Selection::Alias {
                name: reference.to_owned(),
                key: target.clone(),
            });
        }
        match self.providers.get(&target.provider_id) {
            Some(provider) if provider.generation() == target.provider_generation => {
                Err(refusal::actionable(
                    "model_not_in_catalog",
                    STAGE,
                    "selection",
                    RecoveryAction::CorrectRequest,
                )
                .with_presentation_arg("alias", reference)
                .with_presentation_arg("vendorModelId", &target.vendor_model_id))
            }
            Some(provider) => Err(refusal::actionable(
                "provider_alias_stale",
                STAGE,
                "selection",
                RecoveryAction::CorrectRequest,
            )
            .with_presentation_arg("alias", reference)
            .with_presentation_arg("targetGeneration", &target.provider_generation.to_string())
            .with_presentation_arg("currentGeneration", &provider.generation().to_string())),
            None => Err(refusal::actionable(
                "provider_alias_target_missing",
                STAGE,
                "selection",
                RecoveryAction::CorrectRequest,
            )
            .with_presentation_arg("alias", reference)
            .with_presentation_arg("providerId", &target.provider_id)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::ProviderRegistry;
    use licoup_extension_contracts::provider::{CatalogSource, ProviderConfig, ProviderModel};

    fn model(id: &str) -> ProviderModel {
        ProviderModel {
            id: id.to_owned(),
            display_name: id.to_owned(),
            input_modalities: vec!["text".to_owned()],
            output_modalities: vec!["text".to_owned()],
            tools: None,
            reasoning: None,
            context_tokens: None,
            pricing_source: None,
        }
    }

    fn config(id: &str, revision: u32, models: &[&str]) -> ProviderConfig {
        ProviderConfig {
            schema: licoup_extension_contracts::wire::PROVIDER.to_owned(),
            id: id.to_owned(),
            display_name: id.to_owned(),
            base_url: "http://127.0.0.1:8098/v1".to_owned(),
            api_dialect: "openai-chat-compatible".to_owned(),
            credential_ref: None,
            config_revision: revision,
            catalog_source: CatalogSource::Static,
            models: models.iter().map(|id| model(id)).collect(),
            compat: BTreeMap::new(),
            stream_adapter: None,
        }
    }

    #[test]
    fn an_alias_is_separate_from_the_provider_namespace() {
        let mut registry = ProviderRegistry::new();
        registry
            .install_user(config("synthetic.example.a", 1, &["mini"]))
            .unwrap();
        registry
            .install_user(config("synthetic.example.b", 1, &["mini"]))
            .unwrap();
        let catalog =
            ModelCatalog::build(&registry.snapshot(), &BTreeMap::new(), AliasTable::new());

        let via_namespace = catalog.resolve("synthetic.example.b/mini").unwrap();
        assert_eq!(via_namespace.key().provider_id, "synthetic.example.b");

        let mut aliases = AliasTable::new();
        aliases.set("fast", via_namespace.key().clone());
        let catalog = ModelCatalog::build(&registry.snapshot(), &BTreeMap::new(), aliases);
        let via_alias = catalog.resolve("fast").unwrap();
        assert_eq!(via_alias.key(), via_namespace.key());
        assert_eq!(via_alias.alias(), Some("fast"));
    }

    #[test]
    fn an_alias_that_targets_a_superseded_generation_is_refused() {
        let mut registry = ProviderRegistry::new();
        registry
            .install_user(config("synthetic.example.a", 1, &["mini"]))
            .unwrap();
        let mut aliases = AliasTable::new();
        aliases.set(
            "fast",
            ModelCatalogKey {
                provider_id: "synthetic.example.a".to_owned(),
                provider_generation: 1,
                vendor_model_id: "mini".to_owned(),
            },
        );
        // A configuration update moves the provider to generation 2. The alias
        // still names generation 1 and is not silently rebound.
        registry
            .install_user(config("synthetic.example.a", 2, &["small"]))
            .unwrap();
        let catalog = ModelCatalog::build(&registry.snapshot(), &BTreeMap::new(), aliases);
        let failure = catalog.resolve("fast").expect_err("stale alias");
        assert_eq!(failure.code, "provider_alias_stale");

        // An explicit replacement re-points it, and the namespaced form always
        // selects the current generation.
        assert!(catalog.resolve("synthetic.example.a/small").is_ok());
        assert_eq!(
            catalog
                .resolve("synthetic.example.a/mini")
                .unwrap_err()
                .code,
            "model_not_in_catalog"
        );
    }

    #[test]
    fn a_discovered_catalog_is_bound_to_its_generation() {
        let mut registry = ProviderRegistry::new();
        let mut cfg = config("synthetic.example.a", 1, &[]);
        cfg.catalog_source = CatalogSource::Discovered;
        registry.install_user(cfg).unwrap();

        let mut discovered = BTreeMap::new();
        discovered.insert(
            ("synthetic.example.a".to_owned(), 1u64),
            vec![model("discovered-one")],
        );
        let catalog = ModelCatalog::build(&registry.snapshot(), &discovered, AliasTable::new());
        assert_eq!(catalog.entries().len(), 1);
        assert_eq!(catalog.entries()[0].source, CatalogSource::Discovered);
        assert_eq!(catalog.entries()[0].key.provider_generation, 1);
    }

    #[test]
    fn unpublished_model_facts_stay_none_through_the_catalog() {
        let mut registry = ProviderRegistry::new();
        registry
            .install_user(config("synthetic.example.a", 1, &["mystery"]))
            .unwrap();
        let catalog =
            ModelCatalog::build(&registry.snapshot(), &BTreeMap::new(), AliasTable::new());
        let entry = &catalog.entries()[0];
        assert_eq!(entry.model.context_tokens, None);
        assert_eq!(entry.model.tools, None);
        assert_eq!(entry.model.reasoning, None);
        assert_eq!(entry.model.pricing_source, None);
    }
}
