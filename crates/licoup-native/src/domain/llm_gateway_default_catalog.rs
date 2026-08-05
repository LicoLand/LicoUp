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

/// One closed default route: client-requested id, credential provider, upstream id.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DefaultGatewayModel {
    pub requested_model: &'static str,
    pub provider_id: &'static str,
    pub upstream_model: &'static str,
    pub display_name: &'static str,
}

/// Catalog projection for providers that currently have a usable saved key.
pub fn models_for_provider_ids<'a>(
    provider_ids: &'a BTreeSet<&'a str>,
) -> impl Iterator<Item = &'static DefaultGatewayModel> + 'a {
    DEFAULT_GATEWAY_MODELS
        .iter()
        .filter(move |model| provider_ids.contains(model.provider_id))
}

/// Current default inventory for Kimi, DeepSeek, and a curated Kilo set.
///
/// Requested ids are Gateway aliases (`kimi:…`, `deepseek:…`, `kilo:…`).
/// Upstream ids stay the vendor/Kilo API values. Retired preview aliases are
/// not retained.
pub const DEFAULT_GATEWAY_MODELS: &[DefaultGatewayModel] = &[
    // Kimi / Moonshot — alias drops the redundant `kimi-` prefix after `kimi:`
    DefaultGatewayModel {
        requested_model: "kimi:k3",
        provider_id: "kimi",
        upstream_model: "kimi-k3",
        display_name: "Kimi K3",
    },
    DefaultGatewayModel {
        requested_model: "kimi:k2.7-code",
        provider_id: "kimi",
        upstream_model: "kimi-k2.7-code",
        display_name: "Kimi K2.7 Code",
    },
    DefaultGatewayModel {
        requested_model: "kimi:k2.7-code-highspeed",
        provider_id: "kimi",
        upstream_model: "kimi-k2.7-code-highspeed",
        display_name: "Kimi K2.7 Code HighSpeed",
    },
    DefaultGatewayModel {
        requested_model: "kimi:k2.6",
        provider_id: "kimi",
        upstream_model: "kimi-k2.6",
        display_name: "Kimi K2.6",
    },
    DefaultGatewayModel {
        requested_model: "kimi:k2.5",
        provider_id: "kimi",
        upstream_model: "kimi-k2.5",
        display_name: "Kimi K2.5",
    },
    // DeepSeek
    DefaultGatewayModel {
        requested_model: "deepseek:deepseek-v4-flash",
        provider_id: "deepseek",
        upstream_model: "deepseek-v4-flash",
        display_name: "DeepSeek V4 Flash",
    },
    DefaultGatewayModel {
        requested_model: "deepseek:deepseek-v4-pro",
        provider_id: "deepseek",
        upstream_model: "deepseek-v4-pro",
        display_name: "DeepSeek V4 Pro",
    },
    // Kilo Gateway — auto tiers (stable virtual ids; upstream routing is server-side)
    DefaultGatewayModel {
        requested_model: "kilo:kilo-auto/frontier",
        provider_id: "kilo",
        upstream_model: "kilo-auto/frontier",
        display_name: "Kilo Auto Frontier",
    },
    DefaultGatewayModel {
        requested_model: "kilo:kilo-auto/balanced",
        provider_id: "kilo",
        upstream_model: "kilo-auto/balanced",
        display_name: "Kilo Auto Balanced",
    },
    DefaultGatewayModel {
        requested_model: "kilo:kilo-auto/efficient",
        provider_id: "kilo",
        upstream_model: "kilo-auto/efficient",
        display_name: "Kilo Auto Efficient",
    },
    DefaultGatewayModel {
        requested_model: "kilo:kilo-auto/free",
        provider_id: "kilo",
        upstream_model: "kilo-auto/free",
        display_name: "Kilo Auto Free",
    },
    DefaultGatewayModel {
        requested_model: "kilo:kilo-auto/small",
        provider_id: "kilo",
        upstream_model: "kilo-auto/small",
        display_name: "Kilo Auto Small",
    },
    // Kilo Gateway — curated latest named models (full catalog is hundreds of ids)
    DefaultGatewayModel {
        requested_model: "kilo:anthropic/claude-opus-5",
        provider_id: "kilo",
        upstream_model: "anthropic/claude-opus-5",
        display_name: "Claude Opus 5",
    },
    DefaultGatewayModel {
        requested_model: "kilo:anthropic/claude-sonnet-5",
        provider_id: "kilo",
        upstream_model: "anthropic/claude-sonnet-5",
        display_name: "Claude Sonnet 5",
    },
    DefaultGatewayModel {
        requested_model: "kilo:anthropic/claude-fable-5",
        provider_id: "kilo",
        upstream_model: "anthropic/claude-fable-5",
        display_name: "Claude Fable 5",
    },
    DefaultGatewayModel {
        requested_model: "kilo:anthropic/claude-opus-4.8",
        provider_id: "kilo",
        upstream_model: "anthropic/claude-opus-4.8",
        display_name: "Claude Opus 4.8",
    },
    DefaultGatewayModel {
        requested_model: "kilo:anthropic/claude-haiku-4.5",
        provider_id: "kilo",
        upstream_model: "anthropic/claude-haiku-4.5",
        display_name: "Claude Haiku 4.5",
    },
    // Kilo Gateway — floating "latest" aliases (server-side pointer; ids include ~)
    DefaultGatewayModel {
        requested_model: "kilo:~anthropic/claude-opus-latest",
        provider_id: "kilo",
        upstream_model: "~anthropic/claude-opus-latest",
        display_name: "Claude Opus Latest",
    },
    DefaultGatewayModel {
        requested_model: "kilo:~anthropic/claude-sonnet-latest",
        provider_id: "kilo",
        upstream_model: "~anthropic/claude-sonnet-latest",
        display_name: "Claude Sonnet Latest",
    },
    DefaultGatewayModel {
        requested_model: "kilo:~anthropic/claude-fable-latest",
        provider_id: "kilo",
        upstream_model: "~anthropic/claude-fable-latest",
        display_name: "Claude Fable Latest",
    },
    DefaultGatewayModel {
        requested_model: "kilo:~anthropic/claude-haiku-latest",
        provider_id: "kilo",
        upstream_model: "~anthropic/claude-haiku-latest",
        display_name: "Claude Haiku Latest",
    },
    DefaultGatewayModel {
        requested_model: "kilo:~openai/gpt-latest",
        provider_id: "kilo",
        upstream_model: "~openai/gpt-latest",
        display_name: "GPT Latest",
    },
    DefaultGatewayModel {
        requested_model: "kilo:~openai/gpt-mini-latest",
        provider_id: "kilo",
        upstream_model: "~openai/gpt-mini-latest",
        display_name: "GPT Mini Latest",
    },
    DefaultGatewayModel {
        requested_model: "kilo:~google/gemini-pro-latest",
        provider_id: "kilo",
        upstream_model: "~google/gemini-pro-latest",
        display_name: "Gemini Pro Latest",
    },
    DefaultGatewayModel {
        requested_model: "kilo:~google/gemini-flash-latest",
        provider_id: "kilo",
        upstream_model: "~google/gemini-flash-latest",
        display_name: "Gemini Flash Latest",
    },
    DefaultGatewayModel {
        requested_model: "kilo:~x-ai/grok-latest",
        provider_id: "kilo",
        upstream_model: "~x-ai/grok-latest",
        display_name: "Grok Latest",
    },
    DefaultGatewayModel {
        requested_model: "kilo:openai/gpt-5.6-luna",
        provider_id: "kilo",
        upstream_model: "openai/gpt-5.6-luna",
        display_name: "GPT-5.6 Luna",
    },
    DefaultGatewayModel {
        requested_model: "kilo:openai/gpt-5.6-sol",
        provider_id: "kilo",
        upstream_model: "openai/gpt-5.6-sol",
        display_name: "GPT-5.6 Sol",
    },
    DefaultGatewayModel {
        requested_model: "kilo:openai/gpt-5.6-terra",
        provider_id: "kilo",
        upstream_model: "openai/gpt-5.6-terra",
        display_name: "GPT-5.6 Terra",
    },
    DefaultGatewayModel {
        requested_model: "kilo:openai/gpt-5.5",
        provider_id: "kilo",
        upstream_model: "openai/gpt-5.5",
        display_name: "GPT-5.5",
    },
    DefaultGatewayModel {
        requested_model: "kilo:google/gemini-3.6-flash",
        provider_id: "kilo",
        upstream_model: "google/gemini-3.6-flash",
        display_name: "Gemini 3.6 Flash",
    },
    DefaultGatewayModel {
        requested_model: "kilo:google/gemini-3.1-pro-preview",
        provider_id: "kilo",
        upstream_model: "google/gemini-3.1-pro-preview",
        display_name: "Gemini 3.1 Pro Preview",
    },
    DefaultGatewayModel {
        requested_model: "kilo:x-ai/grok-4.5",
        provider_id: "kilo",
        upstream_model: "x-ai/grok-4.5",
        display_name: "Grok 4.5",
    },
    DefaultGatewayModel {
        requested_model: "kilo:x-ai/grok-build-0.1",
        provider_id: "kilo",
        upstream_model: "x-ai/grok-build-0.1",
        display_name: "Grok Build",
    },
    DefaultGatewayModel {
        requested_model: "kilo:minimax/minimax-m3",
        provider_id: "kilo",
        upstream_model: "minimax/minimax-m3",
        display_name: "MiniMax M3",
    },
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn default_catalog_ids_are_unique_and_nonempty() {
        let mut seen = HashSet::new();
        for model in DEFAULT_GATEWAY_MODELS {
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
