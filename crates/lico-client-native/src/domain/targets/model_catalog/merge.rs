use super::*;

pub(super) fn model_catalog_fixture_for_target(target: &str, params: &Value) -> Option<Value> {
    params
        .get("modelCatalogFixture")
        .and_then(|value| value.get(target))
        .cloned()
        .or_else(|| {
            let requested = params.get("target").and_then(Value::as_str)?;
            if requested == target {
                params.get("modelCatalog").cloned()
            } else {
                None
            }
        })
}

pub(super) fn merge_model_catalog_value_into(
    value: &Value,
    fallback_source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    sources: &mut BTreeSet<String>,
    diagnostics: &mut Vec<Value>,
) {
    let source = value
        .get("source")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(fallback_source);
    sources.insert(source.to_string());
    if let Some(extra_sources) = value.get("sources").and_then(Value::as_array) {
        for item in extra_sources {
            if let Some(source) = item.as_str().filter(|value| !value.trim().is_empty()) {
                sources.insert(source.to_string());
            }
        }
    }
    if let Some(items) = value.get("diagnostics").and_then(Value::as_array) {
        diagnostics.extend(items.iter().cloned());
    }
    let Some(models) = value.get("models").and_then(Value::as_array) else {
        return;
    };
    for model in models {
        let name = model_name_from_value(model);
        if name.trim().is_empty() {
            continue;
        }
        let efforts = reasoning_efforts_from_value(model);
        let display_name = model_display_name_from_value(model, &name);
        add_model_catalog_entry_with_provider(
            entries,
            &name,
            display_name.as_deref(),
            provider_id_from_model_value(model).as_deref(),
            provider_name_from_model_value(model).as_deref(),
            source,
            efforts,
        );
    }
}

pub(super) fn add_model_catalog_entry(
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    name: &str,
    source: &str,
    reasoning_efforts: BTreeSet<String>,
) {
    add_model_catalog_entry_with_provider(
        entries,
        name,
        None,
        None,
        None,
        source,
        reasoning_efforts,
    );
}

pub(super) fn add_model_catalog_entry_with_provider(
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    name: &str,
    display_name: Option<&str>,
    provider_id: Option<&str>,
    provider_name: Option<&str>,
    source: &str,
    reasoning_efforts: BTreeSet<String>,
) {
    let Some(name) = sanitize_model_name(name) else {
        return;
    };
    let provider_id = provider_id.and_then(sanitize_option_name);
    let provider_name = provider_name.and_then(sanitize_option_name);
    let provider_key = provider_id
        .as_ref()
        .or(provider_name.as_ref())
        .map(|value| value.to_ascii_lowercase());
    let key = match provider_key {
        Some(provider_key) => format!("{}\u{1f}{}", provider_key, name.to_ascii_lowercase()),
        None => name.to_ascii_lowercase(),
    };
    let display_name = display_name
        .and_then(sanitize_model_name)
        .map(|value| canonical_model_display_name(&value))
        .unwrap_or_else(|| canonical_model_display_name(&name));
    let provider = provider_name.clone().or_else(|| {
        provider_id
            .as_deref()
            .and_then(provider_label_from_provider_id)
    });
    let entry_name = name.clone();
    let entry = entries.entry(key).or_insert_with(|| ModelCatalogEntry {
        provider,
        provider_id: provider_id.clone(),
        provider_inferred: false,
        name: entry_name,
        display_name: display_name.clone(),
        sources: BTreeSet::new(),
        reasoning_efforts: BTreeSet::new(),
    });
    if prefer_model_display_name(&entry.name, &entry.display_name, &display_name) {
        entry.display_name = display_name;
    }
    if entry.provider_id.is_none() {
        entry.provider_id = provider_id;
    }
    if let Some(provider_name) = provider_name {
        entry.provider = Some(provider_name);
        entry.provider_inferred = false;
    } else if let Some(provider_id) = entry.provider_id.as_deref() {
        if entry.provider.is_none() || entry.provider_inferred {
            entry.provider = provider_label_from_provider_id(provider_id);
        }
        entry.provider_inferred = false;
    }
    entry.sources.insert(source.to_string());
    entry.reasoning_efforts.extend(reasoning_efforts);
}

pub(super) fn build_model_catalog(
    entries: BTreeMap<String, ModelCatalogEntry>,
    sources: BTreeSet<String>,
    diagnostics: Vec<Value>,
) -> Value {
    let models = entries
        .into_values()
        .map(model_catalog_entry_json)
        .collect::<Vec<_>>();
    let status = if !models.is_empty() {
        "available"
    } else if sources.is_empty() {
        "unavailable"
    } else {
        "empty"
    };
    json!({
        "schemaVersion": 1,
        "status": status,
        "sources": sources.into_iter().collect::<Vec<_>>(),
        "models": models,
        "diagnostics": diagnostics,
    })
}

pub(super) fn model_catalog_entry_json(entry: ModelCatalogEntry) -> Value {
    json!({
        "name": entry.name,
        "displayName": entry.display_name,
        "providerId": entry.provider_id.unwrap_or_default(),
        "provider": entry.provider.unwrap_or_default(),
        "providerInferred": entry.provider_inferred,
        "sources": entry.sources.into_iter().collect::<Vec<_>>(),
        "reasoningEfforts": entry.reasoning_efforts.into_iter().collect::<Vec<_>>(),
    })
}
