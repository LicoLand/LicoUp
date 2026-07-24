use super::*;

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuiltinCatalog {
    #[serde(default)]
    agents: BTreeMap<String, BuiltinAgentRows>,
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuiltinAgentRows {
    #[serde(default)]
    models: Vec<BuiltinModelRow>,
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuiltinModelRow {
    name: String,
    #[serde(default)]
    aliases: Vec<String>,
    #[serde(default)]
    reasoning_efforts: Vec<String>,
}

fn builtin_catalog() -> &'static BuiltinCatalog {
    static CATALOG: std::sync::OnceLock<BuiltinCatalog> = std::sync::OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(include_str!("builtin_catalog.json")).unwrap_or(BuiltinCatalog {
            agents: BTreeMap::new(),
        })
    })
}

impl BuiltinModelRow {
    fn matches(&self, model_name: &str) -> bool {
        let normalized = model_name.trim().to_ascii_lowercase();
        if normalized.is_empty() {
            return false;
        }
        let tail = normalized.rsplit('/').next().unwrap_or(normalized.as_str());
        self.name.trim().eq_ignore_ascii_case(&normalized)
            || self.name.trim().eq_ignore_ascii_case(tail)
            || self
                .aliases
                .iter()
                .any(|alias| alias.trim().eq_ignore_ascii_case(&normalized))
    }
}

/// Overrides scanned reasoning efforts with the reviewed built-in table for
/// known models. Models missing from the table keep their scanned data and
/// table rows for models absent from the scan are never injected.
pub(super) fn apply_builtin_model_catalog_overlay(
    target: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    sources: &mut BTreeSet<String>,
) {
    let Some(agent_rows) = builtin_catalog().agents.get(target) else {
        return;
    };
    if agent_rows.models.is_empty() {
        return;
    }
    let mut applied = false;
    for entry in entries.values_mut() {
        let Some(row) = agent_rows
            .models
            .iter()
            .find(|row| row.matches(&entry.name))
        else {
            continue;
        };
        entry.reasoning_efforts = row.reasoning_efforts.clone();
        entry.sources.insert("builtin".to_string());
        applied = true;
    }
    if applied {
        sources.insert("builtin".to_string());
    }
}
