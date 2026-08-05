//! Product-owned default Gateway model routes.
//!
//! Agent-config adapters (OpenCode, Pi, …) must derive their visible model lists
//! from this catalog so clients never advertise an unknown Gateway route.
//!
//! Client-facing ids use `{provider}:{alias}` so agents can tell which credential
//! lane a model belongs to. `upstream_model` remains the provider API model id.
//!
//! Callers that project the catalog into a Gateway config or agent sidecar must
//! omit every model whose provider has no usable saved API key on this machine.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use serde::Deserialize;

/// One closed default route: client-requested id, credential provider, upstream id.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
pub struct DefaultGatewayModel {
    #[serde(deserialize_with = "leased_str")]
    pub requested_model: &'static str,
    #[serde(deserialize_with = "leased_str")]
    pub provider_id: &'static str,
    #[serde(deserialize_with = "leased_str")]
    pub upstream_model: &'static str,
    #[serde(deserialize_with = "leased_str")]
    pub display_name: &'static str,
}

fn leased_str<'de, D>(deserializer: D) -> Result<&'static str, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    Ok(Box::leak(value.into_boxed_str()))
}

/// Catalog projection for providers that currently have a usable saved key.
pub fn models_for_provider_ids<'a>(
    provider_ids: &'a BTreeSet<&'a str>,
) -> impl Iterator<Item = &'static DefaultGatewayModel> + 'a {
    DEFAULT_GATEWAY_MODELS
        .iter()
        .filter(move |model| provider_ids.contains(model.provider_id))
}

/// Versioned catalog document: the single source consumed by the gateway and
/// agent projections. Catalog changes edit the JSON, not this module.
const DEFAULT_GATEWAY_MODELS_JSON: &str =
    include_str!("llm_gateway_default_catalog.json");

/// Current default inventory for Kimi, DeepSeek, and a curated Kilo set.
///
/// Requested ids are Gateway aliases (`kimi:…`, `deepseek:…`, `kilo:…`).
/// Upstream ids stay the vendor/Kilo API values. Retired preview aliases are
/// not retained.
pub static DEFAULT_GATEWAY_MODELS: LazyLock<Vec<DefaultGatewayModel>> = LazyLock::new(|| {
    serde_json::from_str(DEFAULT_GATEWAY_MODELS_JSON)
        .expect("default gateway catalog document must parse")
});

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn default_catalog_ids_are_unique_and_nonempty() {
        let mut seen = HashSet::new();
        for model in DEFAULT_GATEWAY_MODELS.iter() {
            assert!(!model.requested_model.is_empty());
            assert!(!model.display_name.is_empty());
            assert!(matches!(
                model.provider_id,
                "kimi" | "deepseek" | "kilo"
            ));
            assert!(
                model.requested_model.starts_with(&format!("{}:", model.provider_id)),
                "{}",
                model.requested_model
            );
            assert!(seen.insert(model.requested_model));
        }
        assert!(DEFAULT_GATEWAY_MODELS.len() >= 20);
        assert!(DEFAULT_GATEWAY_MODELS
            .iter()
            .any(|model| model.requested_model == "kimi:k3"));
        assert!(DEFAULT_GATEWAY_MODELS
            .iter()
            .any(|model| model.requested_model == "deepseek:deepseek-v4-flash"));
        assert!(DEFAULT_GATEWAY_MODELS
            .iter()
            .any(|model| model.requested_model == "kilo:kilo-auto/free"));
        assert!(DEFAULT_GATEWAY_MODELS
            .iter()
            .any(|model| model.requested_model == "kilo:anthropic/claude-opus-5"));
        assert!(DEFAULT_GATEWAY_MODELS.iter().any(|model| {
            model.requested_model == "kilo:~anthropic/claude-opus-latest"
                && model.upstream_model == "~anthropic/claude-opus-latest"
        }));
        assert!(!DEFAULT_GATEWAY_MODELS
            .iter()
            .any(|model| model.requested_model == "anthropic/claude-sonnet-4.6"));
    }

    #[test]
    fn models_for_provider_ids_omits_providers_without_keys() {
        let only_kilo = BTreeSet::from(["kilo"]);
        let models: Vec<_> = models_for_provider_ids(&only_kilo).collect();
        assert!(!models.is_empty());
        assert!(models.iter().all(|model| model.provider_id == "kilo"));
        assert!(models.iter().any(|model| model.requested_model == "kilo:kilo-auto/free"));

        let empty = BTreeSet::new();
        assert_eq!(models_for_provider_ids(&empty).count(), 0);
    }
}
