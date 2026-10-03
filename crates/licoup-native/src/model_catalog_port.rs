//! The composition point for the model catalogue port.
//!
//! `licoup-model-catalog` owns the selection facts — declared canonical
//! identity, observed availability, recorded prices and the planning inputs
//! built on them — and declares [`ModelCatalogPort`] for every fact it reads
//! from a module composed above it. This module is where this host answers that
//! port: each member names the owner that actually holds the fact, so the
//! catalogue never refers to the Agent inventory, the driver engines or the
//! local state roots, and no reference points upward.
//!
//! It sits at the crate root, above the domain and platform layers, exactly
//! like the Agent inventory's port: answering a port is composition, not a
//! domain concern, and a domain module that reached into `crate::platform`
//! would be the coupling the layering exists to prevent.
//!
//! Two members are deliberately answered with less than a caller might wish,
//! and the difference is the point of the port:
//!
//! - **credentials.** No owner publishes a mapping from a catalogue provider id
//!   to the credential records it holds, and inventing one — matching a model
//!   or provider name against a credential label — would fabricate access. The
//!   honest answer is [`CredentialState::Unknown`] for every provider.
//! - **the source generation.** It is the revision of the canonical registry
//!   snapshot an observation was taken against. A host with no catalog
//!   publishes no revision, and then no observation is reused.

use licoup_model_catalog::availability::ObservedModel;
use licoup_model_catalog::port::{CredentialState, ModelCatalogPort};
use serde_json::Value;

/// The port this host composes: every catalogue fact answered by its owner.
pub fn model_catalog_port() -> ModelCatalogPort {
    ModelCatalogPort {
        agent_wrapper_labels: agent_wrapper_labels,
        observe_target_models: observe_target_models,
        provider_credential: provider_credential,
        source_generation: source_generation,
    }
}

/// The Agent inventory's declaration labels. The inventory owns which Agents
/// exist on this machine; a label that names a source rather than a model is
/// stripped before canonical resolution matches.
fn agent_wrapper_labels() -> Vec<String> {
    crate::domain::agent_catalog::entries()
        .into_iter()
        .flat_map(|agent| [agent.id, agent.label])
        .collect()
}

/// Probe one Agent's live model catalog through the target owner.
///
/// The inventory owns the probe: which binary or app server to ask, which
/// config, cache and history paths to read, and which of them this call is
/// allowed to touch. The catalogue only records what came back and when.
fn observe_target_models(target: &str, params: &Value) -> anyhow::Result<Vec<ObservedModel>> {
    let mut request = params.clone();
    let object = request
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("model_catalog_probe_params_invalid"))?;
    object.insert("target".to_owned(), Value::String(target.to_owned()));
    let inspected = crate::domain::targets::inspect_target_with_params(
        &crate::target_port::agent_target_port(),
        &request,
    )?;
    Ok(observed_models(target, &inspected))
}

/// Project one inspection response into the observation the catalogue records.
///
/// The projection copies the facts the observing source declared and completes
/// none of them: a row that names no provider keeps no provider, and a row that
/// names no model is not a model. A response for another target is not this
/// observation at all.
fn observed_models(target: &str, inspected: &Value) -> Vec<ObservedModel> {
    let Some(candidate) = inspected.get("target") else {
        return Vec::new();
    };
    let answered = candidate
        .get("target")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if answered != crate::domain::targets::normalize_target(target) {
        return Vec::new();
    }
    let Some(models) = candidate
        .get("modelCatalog")
        .and_then(|catalog| catalog.get("models"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    models
        .iter()
        .filter_map(|model| {
            let name = model
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())?;
            Some(ObservedModel {
                name: name.to_owned(),
                provider_id: non_empty_string(model.get("providerId")),
                provider: non_empty_string(model.get("provider")),
                sources: model
                    .get("sources")
                    .and_then(Value::as_array)
                    .map(|sources| {
                        sources
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect()
                    })
                    .unwrap_or_default(),
            })
        })
        .collect()
}

fn non_empty_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

/// No owner publishes a catalogue provider to credential mapping, and inferring
/// one from a name would fabricate access. Every provider stays unknown until an
/// owner states otherwise.
fn provider_credential(_provider_id: &str) -> CredentialState {
    CredentialState::Unknown
}

/// The revision of the canonical registry snapshot this host holds. An empty
/// catalog has no revision, and a generation that does not exist is `None`
/// rather than an empty string that would cache an attachment to nothing.
fn source_generation() -> Option<String> {
    let revision = crate::domain::model_registry::refresh_cached_snapshot()
        .revision()
        .to_owned();
    (!revision.is_empty()).then_some(revision)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_composition_answers_every_port_member_from_its_owner() {
        let port = model_catalog_port();

        // The inventory's declarations, not a copied list.
        let labels = (port.agent_wrapper_labels)();
        for agent in ["codex", "cursor", "claude-code", "kilo-code"] {
            assert!(labels.iter().any(|label| label == agent), "{agent}");
        }

        // No owner publishes a credential mapping, so no access is claimed.
        assert_eq!(
            (port.provider_credential)("openai-chatgpt"),
            CredentialState::Unknown
        );
        assert_eq!(
            (port.provider_credential)("not-a-provider"),
            CredentialState::Unknown
        );

        // A test build holds no catalog revision, so this host publishes no
        // generation and nothing it observes may be reused.
        assert_eq!((port.source_generation)(), None);
    }

    #[test]
    fn an_undeclared_target_reports_no_observation_instead_of_an_empty_catalog() {
        let port = model_catalog_port();
        assert!(
            (port.observe_target_models)("not-a-declared-agent", &json!({})).is_err(),
            "a probe that cannot run is not an empty model list"
        );
    }

    #[test]
    fn the_projection_copies_declared_facts_and_invents_no_provider() {
        let inspected = json!({
            "ok": true,
            "target": {
                "target": "codex",
                "modelCatalog": {
                    "status": "available",
                    "models": [
                        {
                            "name": "gpt-5.6-sol",
                            "providerId": "openai-chatgpt",
                            "provider": "ChatGPT",
                            "sources": ["codex-app-server", "config"]
                        },
                        { "name": "  " },
                        { "providerId": "openai-chatgpt" },
                        { "name": "mystery-preview", "sources": [] }
                    ]
                }
            }
        });
        let models = observed_models("codex", &inspected);
        assert_eq!(
            models,
            vec![
                ObservedModel {
                    name: "gpt-5.6-sol".to_owned(),
                    provider_id: Some("openai-chatgpt".to_owned()),
                    provider: Some("ChatGPT".to_owned()),
                    sources: vec!["codex-app-server".to_owned(), "config".to_owned()],
                },
                ObservedModel {
                    name: "mystery-preview".to_owned(),
                    provider_id: None,
                    provider: None,
                    sources: Vec::new(),
                },
            ]
        );
    }

    #[test]
    fn a_catalog_that_could_not_be_read_projects_no_observation() {
        assert!(observed_models("codex", &json!({ "target": { "target": "codex" } })).is_empty());
        assert!(observed_models("codex", &json!({})).is_empty());
        assert!(
            observed_models(
                "codex",
                &json!({ "target": { "target": "cursor", "modelCatalog": { "models": [{ "name": "gpt-5.6-sol" }] } } })
            )
            .is_empty(),
            "a response for another target is not this observation"
        );
        assert_eq!(
            observed_models(
                "CODEX",
                &json!({ "target": { "target": "codex", "modelCatalog": { "models": [{ "name": "gpt-5.6-sol" }] } } })
            )
            .len(),
            1,
            "the caller's spelling is normalized before it is compared"
        );
    }
}
