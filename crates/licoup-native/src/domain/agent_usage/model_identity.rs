//! Canonical catalog identities and actual historical execution variants.
//! Raw selectors remain lossless; only stable model evidence classifies history.

use super::contract::{ModelTokenUsageSummary, UNATTRIBUTED_MODEL, UsageVariant};
use super::variant::model_selection;
use crate::domain::model_registry::{RegistrySnapshot, model_display_name};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Default)]
struct ModelProjection {
    display_name: String,
    is_canonical: bool,
    total: ModelTokenUsageSummary,
    variants: BTreeMap<String, ModelTokenUsageSummary>,
    unattributed: ModelTokenUsageSummary,
}

impl ModelProjection {
    fn from_published(value: &Value) -> Self {
        let total = ModelTokenUsageSummary::from_json(value);
        let variants = value
            .get("variants")
            .and_then(Value::as_object)
            .map(|variants| {
                variants
                    .iter()
                    .map(|(label, usage)| (label.clone(), ModelTokenUsageSummary::from_json(usage)))
                    .collect::<BTreeMap<_, _>>()
            })
            .unwrap_or_default();
        let mut represented = ModelTokenUsageSummary::default();
        for usage in variants.values() {
            represented.merge(*usage);
        }
        Self {
            display_name: value
                .get("displayName")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            is_canonical: value
                .get("isCanonical")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            total,
            variants,
            unattributed: value
                .get("unattributedVariantUsage")
                .map(ModelTokenUsageSummary::from_json)
                .unwrap_or_else(|| total.saturating_sub(represented)),
        }
    }

    fn merge(&mut self, other: Self) {
        self.display_name = other.display_name;
        self.is_canonical |= other.is_canonical;
        self.total.merge(other.total);
        self.unattributed.merge(other.unattributed);
        for (label, usage) in other.variants {
            self.variants.entry(label).or_default().merge(usage);
        }
    }

    fn to_json(&self) -> Value {
        let mut value = self.total.to_json();
        value["displayName"] = json!(self.display_name);
        value["isCanonical"] = json!(self.is_canonical);
        value["variants"] = json!(
            self.variants
                .iter()
                .map(|(label, usage)| (label.clone(), usage.to_json()))
                .collect::<BTreeMap<_, _>>()
        );
        value["unattributedVariantUsage"] = self.unattributed.to_json();
        value
    }
}

pub(super) type RawModelUsage = BTreeMap<(String, UsageVariant), ModelTokenUsageSummary>;

pub(super) fn project_model_usage(
    raw: &RawModelUsage,
    source_agent: Option<&str>,
    registry: &RegistrySnapshot,
) -> BTreeMap<String, Value> {
    let mut models = BTreeMap::<String, ModelProjection>::new();
    for ((raw_model, observed_variant), usage) in raw {
        let selection = model_selection(raw_model);
        let resolved = registry.resolve_historical(
            &selection.id,
            selection.provider_id.as_deref(),
            source_agent,
        );
        let (id, display_name) = match resolved {
            Some(model) => (model.id.clone(), model.display_name.clone()),
            None if selection.id.trim().is_empty()
                || selection.id == UNATTRIBUTED_MODEL
                || (selection.provider_id.is_none()
                    && (registry.is_provider_label(&selection.id)
                        || source_agent
                            .is_some_and(|agent| selection.id.eq_ignore_ascii_case(agent)))) =>
            {
                (UNATTRIBUTED_MODEL.to_owned(), UNATTRIBUTED_MODEL.to_owned())
            }
            None => (
                selection.unresolved_identity(),
                model_display_name(&selection.id),
            ),
        };
        // Only a unique catalog match admits model suffixes as execution
        // variants. Unknown `research-high` remains a separate model.
        let (stem, candidate_variant) = terminal_variant(&selection.id);
        let suffix_variant = if resolved.is_some_and(|model| {
            registry
                .resolve_historical(&stem, selection.provider_id.as_deref(), source_agent)
                .is_some_and(|base| base.id == model.id)
        }) {
            candidate_variant
        } else {
            UsageVariant::default()
        };
        let variant = observed_variant
            .with_fallback(&selection.variant)
            .with_fallback(&suffix_variant);
        let model = models.entry(id).or_default();
        model.display_name = display_name;
        model.is_canonical |= resolved.is_some();
        model.total.merge(*usage);
        if let Some(label) = variant.label() {
            model.variants.entry(label).or_default().merge(*usage);
        } else {
            model.unattributed.merge(*usage);
        }
    }
    models
        .into_iter()
        .map(|(id, model)| (id, model.to_json()))
        .collect()
}

fn terminal_variant(raw: &str) -> (String, UsageVariant) {
    let normalized = raw.to_ascii_lowercase().replace(['-', '_'], " ");
    let mut words = normalized.split_whitespace().collect::<Vec<_>>();
    let mut variant = UsageVariant::default();
    loop {
        if words.last() == Some(&"fast") {
            words.pop();
            variant.fast = Some(true);
        } else if words.len() >= 2 && words[words.len() - 2..] == ["extra", "high"] {
            words.truncate(words.len() - 2);
            variant.effort = Some("xhigh".to_owned());
        } else if let Some(effort) = words.last().filter(|word| {
            matches!(
                **word,
                "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra"
            )
        }) {
            variant.effort = Some((*effort).to_owned());
            words.pop();
        } else {
            break;
        }
    }
    (words.join(" "), variant)
}

pub(super) fn raw_model_usage(source: &Value) -> RawModelUsage {
    let mut raw = RawModelUsage::new();
    if let Some(rows) = source.get("rawModelUsage").and_then(Value::as_array) {
        for row in rows {
            if let Some(model) = row.get("model").and_then(Value::as_str) {
                raw.entry((model.to_owned(), UsageVariant::from_metadata(row)))
                    .or_default()
                    .merge(ModelTokenUsageSummary::from_json(row));
            }
        }
        return raw;
    }
    if let Some(models) = source.get("modelTokenUsage").and_then(Value::as_object) {
        for (model, value) in models {
            let mut represented = ModelTokenUsageSummary::default();
            if let Some(variants) = value.get("variants").and_then(Value::as_object) {
                for (label, counters) in variants {
                    let totals = ModelTokenUsageSummary::from_json(counters);
                    represented.merge(totals);
                    raw.entry((model.clone(), UsageVariant::from_label(label)))
                        .or_default()
                        .merge(totals);
                }
            }
            let residual = ModelTokenUsageSummary::from_json(value).saturating_sub(represented);
            if residual.has_usage() {
                raw.entry((model.clone(), UsageVariant::default()))
                    .or_default()
                    .merge(residual);
            }
        }
    } else if let Some(models) = source.get("modelUsage").and_then(Value::as_object) {
        for (model, total) in models {
            raw.entry((model.clone(), UsageVariant::default()))
                .or_default()
                .merge(ModelTokenUsageSummary {
                    total_tokens: total.as_u64().unwrap_or(0),
                    ..Default::default()
                });
        }
    }
    raw
}

pub(super) fn raw_usage_json(raw: &RawModelUsage) -> Value {
    json!(
        raw.iter()
            .map(|((model, variant), totals)| {
                let mut value = totals.to_json();
                value["model"] = json!(model);
                value["effort"] = json!(variant.effort);
                value["fast"] = json!(variant.fast);
                value
            })
            .collect::<Vec<_>>()
    )
}

pub(super) fn normalize_retained_report(report: &mut Value, registry: &RegistrySnapshot) {
    let preserve_attribution = report
        .get("modelRegistryRevision")
        .and_then(Value::as_str)
        .is_some_and(|revision| !revision.is_empty());
    if let Some(agents) = report.get_mut("agents").and_then(Value::as_array_mut) {
        for agent in agents {
            let source_agent = agent
                .get("agentId")
                .and_then(Value::as_str)
                .map(str::to_owned);
            if let Some(history) = agent.get_mut("history") {
                normalize_bucket(
                    history,
                    source_agent.as_deref(),
                    registry,
                    preserve_attribution,
                );
                if let Some(days) = history.get_mut("dailyUsage").and_then(Value::as_array_mut) {
                    for day in days {
                        normalize_bucket(
                            day,
                            source_agent.as_deref(),
                            registry,
                            preserve_attribution,
                        );
                    }
                }
            }
        }
    }
    report["modelRegistryRevision"] = json!(registry.revision());
}

fn normalize_bucket(
    bucket: &mut Value,
    source_agent: Option<&str>,
    registry: &RegistrySnapshot,
    preserve_attribution: bool,
) {
    let raw = raw_model_usage(bucket);
    if raw.is_empty() {
        return;
    }
    let models = if preserve_attribution {
        preserve_published_models(bucket, &raw, source_agent, registry)
            .unwrap_or_else(|| project_model_usage(&raw, source_agent, registry))
    } else {
        project_model_usage(&raw, source_agent, registry)
    };
    bucket["modelUsage"] = json!(
        models
            .iter()
            .map(|(name, usage)| (name.clone(), usage["totalTokens"].clone()))
            .collect::<BTreeMap<_, _>>()
    );
    bucket["modelTokenUsage"] = json!(models);
    if bucket.get("rawModelUsage").is_none() {
        bucket["rawModelUsage"] = raw_usage_json(&raw);
    }
}

fn preserve_published_models(
    bucket: &Value,
    raw: &RawModelUsage,
    source_agent: Option<&str>,
    registry: &RegistrySnapshot,
) -> Option<BTreeMap<String, Value>> {
    let existing = bucket.get("modelTokenUsage")?.as_object()?;
    if existing.is_empty() {
        return None;
    }
    let has_raw = bucket.get("rawModelUsage").is_some();
    let mut raw_by_identity = BTreeMap::<String, RawModelUsage>::new();
    let mut observed_identities = BTreeSet::new();
    for (key, usage) in raw {
        let selection = model_selection(&key.0);
        let identity = selection.unresolved_identity();
        observed_identities.insert(identity.clone());
        // The previous serializer omitted the serving provider when a raw ID
        // already contained '/'. That old unknown label is not proof of a
        // canonical assignment merely because the corrected key is qualified.
        if selection.id.contains('/') {
            observed_identities.insert(selection.id);
        }
        raw_by_identity
            .entry(identity)
            .or_default()
            .insert(key.clone(), *usage);
    }
    let mut models = BTreeMap::<String, ModelProjection>::new();
    for (id, value) in existing {
        let current = registry
            .resolve_historical(id, None, None)
            .filter(|model| model.id == *id);
        // Before the explicit marker existed, a published key different from
        // every recorded selector is evidence that an earlier registry had
        // already assigned a canonical identity. A removed catalog entry must
        // not turn that historical assignment back into a floating selector.
        let canonical = value
            .get("isCanonical")
            .and_then(Value::as_bool)
            .unwrap_or_else(|| {
                id != UNATTRIBUTED_MODEL
                    && (current.is_some() || (has_raw && !observed_identities.contains(id)))
            });
        if canonical || id == UNATTRIBUTED_MODEL {
            let mut model = ModelProjection::from_published(value);
            model.is_canonical = canonical;
            model.display_name = current
                .map(|model| model.display_name.clone())
                .unwrap_or_else(|| {
                    if model.display_name.is_empty() {
                        model_display_name(id)
                    } else {
                        model_display_name(&model.display_name)
                    }
                });
            models.entry(id.clone()).or_default().merge(model);
            continue;
        }
        let selected = raw_by_identity
            .remove(id)
            .filter(|selected| {
                let mut total = ModelTokenUsageSummary::default();
                for usage in selected.values() {
                    total.merge(*usage);
                }
                total == ModelTokenUsageSummary::from_json(value)
            })
            .unwrap_or_else(|| raw_model_usage(&json!({"modelTokenUsage": {id: value}})));
        for (resolved_id, projection) in project_model_usage(&selected, source_agent, registry) {
            models
                .entry(resolved_id)
                .or_default()
                .merge(ModelProjection::from_published(&projection));
        }
    }
    Some(
        models
            .into_iter()
            .map(|(id, model)| (id, model.to_json()))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn catalog() -> RegistrySnapshot {
        RegistrySnapshot::from_catalog(json!({
            "models": {
                "moonshotai/kimi-k3":{"name":"Kimi K3"},
                "moonshotai/kimi-k2.7-code":{"name":"Kimi K2.7 Code"},
                "xai/grok-4.6":{"name":"Grok 4.6"},
                "xai/grok-4.7":{"name":"Grok 4.7"},
                "deepseek/flash":{"name":"DeepSeek Flash"},
                "deepseek/flash-vision":{"name":"DeepSeek Flash Vision"}
            },
            "providers":{"kimi-for-coding":{"name":"Kimi Code","models":{
                "k3":{"base_model":"moonshotai/kimi-k3"},
                "k3-256k":{"name":"Kimi Code K3 256K", "base_model":"moonshotai/kimi-k3"},
                "kimi-for-coding":{"base_model":"moonshotai/kimi-k2.7-code"}
            }}}
        }))
        .unwrap()
    }
    fn count(total: u64) -> ModelTokenUsageSummary {
        ModelTokenUsageSummary {
            total_tokens: total,
            prompt_tokens: total,
            request_count: 1,
            ..Default::default()
        }
    }
    #[test]
    fn registry_merges_only_admitted_aliases_and_preserves_actual_request_options() {
        let rows = [
            ("k3", UsageVariant::default(), 10),
            (
                "kimi-code-k3-256k",
                UsageVariant {
                    effort: Some("high".into()),
                    fast: None,
                },
                20,
            ),
            (
                r#"{"id":"k3","providerID":"kimi-for-coding","variant":"max"}"#,
                UsageVariant::default(),
                30,
            ),
            (
                "kimi-for-coding/kimi-for-coding",
                UsageVariant::default(),
                40,
            ),
            ("research-high", UsageVariant::default(), 50),
        ]
        .into_iter()
        .map(|(model, variant, total)| ((model.to_owned(), variant), count(total)))
        .collect();
        let models = project_model_usage(&rows, Some("kimi-code"), &catalog());
        assert_eq!(models["moonshotai/kimi-k3"]["totalTokens"], 60);
        assert_eq!(
            models["moonshotai/kimi-k3"]["variants"]["High"]["totalTokens"],
            20
        );
        assert_eq!(
            models["moonshotai/kimi-k3"]["variants"]["Max"]["totalTokens"],
            30
        );
        assert_eq!(
            models["moonshotai/kimi-k3"]["unattributedVariantUsage"]["totalTokens"],
            10
        );
        assert_eq!(models["kimi-for-coding/kimi-for-coding"]["totalTokens"], 40);
        assert_eq!(
            models["kimi-for-coding/kimi-for-coding"]["isCanonical"],
            false
        );
        assert!(
            models["research-high"]["variants"]
                .as_object()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            models
                .values()
                .map(|value| value["totalTokens"].as_u64().unwrap())
                .sum::<u64>(),
            150
        );
    }
    #[test]
    fn source_wrappers_merge_efforts_but_versions_and_vision_remain_distinct() {
        let rows = [
            ("Cursor Grok 4.6 High", 10),
            ("Cursor Grok 4.6 Extra High", 20),
            ("Cursor Grok 4.6 Extra High Fast", 30),
            ("Cursor", 40),
            ("grok-4.7", 50),
            ("deepseek/flash", 60),
            ("deepseek/flash-vision", 70),
        ]
        .into_iter()
        .map(|(model, total)| ((model.to_owned(), UsageVariant::default()), count(total)))
        .collect();
        let models = project_model_usage(&rows, Some("cursor"), &catalog());
        assert_eq!(models["xai/grok-4.6"]["totalTokens"], 60);
        assert_eq!(
            models["xai/grok-4.6"]["variants"]["Extra High Fast"]["totalTokens"],
            30
        );
        assert_eq!(models["Others"]["totalTokens"], 40);
        assert_eq!(models["xai/grok-4.7"]["totalTokens"], 50);
        assert_eq!(models["deepseek/flash"]["totalTokens"], 60);
        assert_eq!(models["deepseek/flash-vision"]["totalTokens"], 70);
    }
    #[test]
    fn retained_raw_identity_can_reproject_after_registry_refresh_without_losing_residual() {
        let mut report = json!({"usageParserRevision":"old-parser", "agents":[{"agentId":"kimi-code","history":{"dailyUsage":[{
            "date":"2026-07-01", "modelTokenUsage":{"k3":{"totalTokens":100,"requestCount":4,"variants":{"High":{"totalTokens":30,"requestCount":1},"Unspecified":{"totalTokens":20,"requestCount":1}}}}
        }]}}]});
        normalize_retained_report(&mut report, &catalog());
        let usage = &report["agents"][0]["history"]["dailyUsage"][0];
        assert_eq!(
            usage["modelTokenUsage"]["moonshotai/kimi-k3"]["unattributedVariantUsage"]["totalTokens"],
            70
        );
        assert_eq!(
            usage["modelTokenUsage"]["moonshotai/kimi-k3"]["variants"]["High"]["totalTokens"],
            30
        );
        assert!(
            usage["modelTokenUsage"]["moonshotai/kimi-k3"]["variants"]
                .get("Unspecified")
                .is_none()
        );
        assert_eq!(report["usageParserRevision"], "old-parser");
        assert_eq!(
            raw_model_usage(usage)
                .values()
                .map(|usage| usage.total_tokens)
                .sum::<u64>(),
            100
        );
    }

    #[test]
    fn opaque_provider_selectors_keep_slash_ids_without_guessing_historical_routes() {
        let registry = RegistrySnapshot::from_catalog(json!({
            "models": {
                "lab/model-1":{"name":"First Model"},
                "lab/model-2":{"name":"Second Model"}
            },
            "providers": {
                "relay-a":{"models":{"lab/flash-latest":{"base_model":"lab/model-1"}}},
                "relay-b":{"models":{"lab/flash-latest":{"base_model":"lab/model-2"}}}
            }
        }))
        .unwrap();
        let raw = [
            (
                json!({"id":"lab/flash-latest","providerID":"relay-a","variant":"high"})
                    .to_string(),
                10,
            ),
            (
                json!({"id":"lab/flash-latest","providerID":"relay-b","variant":"max"}).to_string(),
                20,
            ),
            (
                json!({"id":"private/custom-model-v2","providerID":"relay-a"}).to_string(),
                30,
            ),
            (
                json!({"id":"private/custom-model-v2","providerID":"relay-b"}).to_string(),
                40,
            ),
        ]
        .into_iter()
        .map(|(model, total)| ((model, UsageVariant::default()), count(total)))
        .collect();
        let mut report = json!({"agents":[{"agentId":"opencode","history":{"rawModelUsage":raw_usage_json(&raw)}}]});
        normalize_retained_report(&mut report, &registry);
        let history = &report["agents"][0]["history"];
        let models = history["modelTokenUsage"].as_object().unwrap();
        assert_eq!(
            models["relay-a/lab/flash-latest"]["variants"]["High"]["totalTokens"],
            10
        );
        assert_eq!(
            models["relay-b/lab/flash-latest"]["variants"]["Max"]["totalTokens"],
            20
        );
        assert!(!models.contains_key("lab/model-1"));
        assert!(!models.contains_key("lab/model-2"));
        assert_eq!(
            registry
                .resolve_with_provider("lab/flash-latest", Some("relay-a"), Some("opencode"))
                .unwrap()
                .id,
            "lab/model-1"
        );
        assert_eq!(models["relay-a/private/custom-model-v2"]["totalTokens"], 30);
        assert_eq!(models["relay-b/private/custom-model-v2"]["totalTokens"], 40);
        assert_eq!(
            models["relay-a/private/custom-model-v2"]["displayName"],
            model_display_name("private/custom-model-v2")
        );
        assert_eq!(
            raw_usage_json(&raw_model_usage(history)),
            raw_usage_json(&raw)
        );
        assert_eq!(
            models
                .values()
                .map(|model| model["totalTokens"].as_u64().unwrap())
                .sum::<u64>(),
            100
        );
    }

    #[test]
    fn published_canonical_assignments_survive_catalog_reroutes_and_removal() {
        for keep_original_model in [true, false] {
            for marker in [Some(true), None] {
                let mut catalog = json!({
                    "models": {
                        "lab/model-v2":{"name":"Second Model"},
                        "lab/model-v3":{"name":"Newly Known Model"}
                    },
                    "providers":{"relay":{"models":{"private-slot":{"base_model":"lab/model-v2"}}}}
                });
                if keep_original_model {
                    catalog["models"]["lab/model-v1"] = json!({"name":"First Model Refreshed"});
                }
                let registry = RegistrySnapshot::from_catalog(catalog).unwrap();
                let selector = json!({"id":"private-slot","providerID":"relay"}).to_string();
                let raw = BTreeMap::from([
                    (
                        (
                            selector,
                            UsageVariant {
                                effort: Some("high".into()),
                                fast: Some(true),
                            },
                        ),
                        count(30),
                    ),
                    (("model-v3".to_owned(), UsageVariant::default()), count(20)),
                ]);
                let mut assigned = count(30).to_json();
                assigned["displayName"] = json!("lab/first-model");
                assigned["variants"] = json!({"High Fast":count(30).to_json()});
                assigned["unattributedVariantUsage"] = ModelTokenUsageSummary::default().to_json();
                if let Some(marker) = marker {
                    assigned["isCanonical"] = json!(marker);
                }
                let mut unknown = count(20).to_json();
                unknown["displayName"] = json!("Model V3");
                unknown["isCanonical"] = json!(false);
                let original_raw = raw_usage_json(&raw);
                let mut report = json!({"modelRegistryRevision":"earlier-catalog", "agents":[{"agentId":"opencode","history":{
                    "rawModelUsage":original_raw,
                    "modelTokenUsage":{"lab/model-v1":assigned,"model-v3":unknown}
                }}]});
                normalize_retained_report(&mut report, &registry);
                let history = &report["agents"][0]["history"];
                assert_eq!(history["rawModelUsage"], original_raw);
                assert_eq!(
                    history["modelTokenUsage"]["lab/model-v1"]["totalTokens"],
                    30
                );
                assert_eq!(
                    history["modelTokenUsage"]["lab/model-v1"]["variants"]["High Fast"]["totalTokens"],
                    30
                );
                assert_eq!(
                    history["modelTokenUsage"]["lab/model-v1"]["isCanonical"],
                    true
                );
                assert_eq!(
                    history["modelTokenUsage"]["lab/model-v1"]["displayName"],
                    if keep_original_model {
                        "First Model Refreshed"
                    } else {
                        "First Model"
                    }
                );
                assert_eq!(
                    history["modelTokenUsage"]["lab/model-v3"]["totalTokens"],
                    20
                );
                assert!(history["modelTokenUsage"].get("lab/model-v2").is_none());
                let normalized = report.clone();
                normalize_retained_report(&mut report, &registry);
                assert_eq!(report, normalized);
            }
        }
    }
}
