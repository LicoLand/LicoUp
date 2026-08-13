//! Versioned, network-free model intelligence snapshots owned by LicoUp.

use serde::Deserialize;
use std::{cmp::Ordering, collections::HashSet, sync::OnceLock};

const AA_INTELLIGENCE_JSON: &str =
    include_str!("agent_intelligence_catalog/aa_intelligence_index.json");
const AA_CODING_AGENT_JSON: &str = include_str!("agent_intelligence_catalog/aa_coding_agent.json");
const ARENA_FRONTEND_JSON: &str = include_str!("agent_intelligence_catalog/arena_frontend.json");

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CatalogError {
    InvalidSnapshot,
    CountMismatch,
    DuplicateIdentifier,
}

#[derive(Clone, Debug, Deserialize)]
pub struct IntelligenceModel {
    pub model_id: String,
    pub model: String,
    pub creator: String,
    pub intelligence_index: Option<i64>,
    pub cost_per_task_usd: Option<f64>,
    pub input_price_per_million_usd: Option<f64>,
    pub output_price_per_million_usd: Option<f64>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CodingAgentVariant {
    pub variant_id: String,
    pub harness: String,
    pub model: String,
    pub reasoning_effort: String,
    pub index_score: i64,
    pub cost_per_task_usd: f64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct FrontendArenaModel {
    pub entry_id: String,
    pub model_id: String,
    pub model: String,
    #[serde(default)]
    pub creator: String,
    pub rank: u64,
    #[serde(alias = "score")]
    pub arena_score: f64,
    pub votes: u64,
}

#[derive(Clone, Debug, Deserialize)]
struct IntelligenceSnapshot {
    schema_version: u64,
    catalog_version: String,
    as_of: String,
    source_url: String,
    model_count: usize,
    models: Vec<IntelligenceModel>,
}

#[derive(Clone, Debug, Deserialize)]
struct CodingSnapshot {
    schema_version: u64,
    catalog_version: String,
    as_of: String,
    source_url: String,
    variant_count: usize,
    variants: Vec<CodingAgentVariant>,
}

#[derive(Clone, Debug, Deserialize)]
struct FrontendSnapshot {
    schema_version: u64,
    catalog_version: String,
    #[serde(alias = "captured_at")]
    as_of: String,
    source_url: String,
    #[serde(alias = "ranking_count")]
    model_count: usize,
    #[serde(alias = "rankings")]
    models: Vec<FrontendArenaModel>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CatalogMetadata {
    pub schema_version: u64,
    pub catalog_version: String,
    pub snapshot_date: String,
    pub source_url: String,
    pub row_count: usize,
}

#[derive(Clone, Debug)]
pub struct AgentIntelligenceCatalog {
    intelligence_metadata: CatalogMetadata,
    coding_metadata: CatalogMetadata,
    frontend_metadata: CatalogMetadata,
    intelligence: Vec<IntelligenceModel>,
    coding: Vec<CodingAgentVariant>,
    frontend: Vec<FrontendArenaModel>,
}

static CATALOG: OnceLock<Result<AgentIntelligenceCatalog, CatalogError>> = OnceLock::new();

impl AgentIntelligenceCatalog {
    pub fn embedded() -> Result<&'static Self, CatalogError> {
        CATALOG
            .get_or_init(load_catalog)
            .as_ref()
            .map_err(|error| *error)
    }

    pub fn metadata(&self) -> [&CatalogMetadata; 3] {
        [
            &self.intelligence_metadata,
            &self.coding_metadata,
            &self.frontend_metadata,
        ]
    }

    pub fn intelligence_models(&self) -> &[IntelligenceModel] {
        &self.intelligence
    }

    pub fn coding_variants(&self) -> &[CodingAgentVariant] {
        &self.coding
    }

    pub fn frontend_rankings(&self) -> &[FrontendArenaModel] {
        &self.frontend
    }

    /// Highest Intelligence Index among models actually available locally.
    /// Equal scores prefer lower observed task cost, then stable model id.
    pub fn strongest_available<'a, I>(&self, available: I) -> Option<&IntelligenceModel>
    where
        I: IntoIterator<Item = &'a str>,
    {
        let available = available.into_iter().collect::<HashSet<_>>();
        self.intelligence
            .iter()
            .filter(|model| {
                available.contains(model.model_id.as_str()) && model.intelligence_index.is_some()
            })
            .max_by(|left, right| {
                left.intelligence_index
                    .cmp(&right.intelligence_index)
                    .then_with(|| {
                        compare_optional_cost(right.cost_per_task_usd, left.cost_per_task_usd)
                    })
                    .then_with(|| right.model_id.cmp(&left.model_id))
            })
    }

    /// Lowest-cost measured model+harness combination meeting the requested
    /// score. Equal costs prefer higher score, then stable variant id.
    pub fn coding_variant<'a, I>(
        &self,
        harness: &str,
        available_models: I,
        minimum_score: i64,
    ) -> Option<&CodingAgentVariant>
    where
        I: IntoIterator<Item = &'a str>,
    {
        let available = available_models.into_iter().collect::<HashSet<_>>();
        self.coding
            .iter()
            .filter(|variant| {
                variant.harness == harness
                    && available.contains(variant.model.as_str())
                    && variant.index_score >= minimum_score
            })
            .min_by(|left, right| {
                left.cost_per_task_usd
                    .total_cmp(&right.cost_per_task_usd)
                    .then_with(|| right.index_score.cmp(&left.index_score))
                    .then_with(|| left.variant_id.cmp(&right.variant_id))
            })
    }

    /// Highest WebDev Arena score among models actually available locally.
    pub fn frontend_model<'a, I>(&self, available: I) -> Option<&FrontendArenaModel>
    where
        I: IntoIterator<Item = &'a str>,
    {
        let available = available.into_iter().collect::<HashSet<_>>();
        self.frontend
            .iter()
            .filter(|model| available.contains(model.model_id.as_str()))
            .max_by(|left, right| {
                left.arena_score
                    .total_cmp(&right.arena_score)
                    .then_with(|| left.votes.cmp(&right.votes))
                    .then_with(|| right.model_id.cmp(&left.model_id))
            })
    }
}

fn load_catalog() -> Result<AgentIntelligenceCatalog, CatalogError> {
    let intelligence: IntelligenceSnapshot =
        serde_json::from_str(AA_INTELLIGENCE_JSON).map_err(|_| CatalogError::InvalidSnapshot)?;
    let coding: CodingSnapshot =
        serde_json::from_str(AA_CODING_AGENT_JSON).map_err(|_| CatalogError::InvalidSnapshot)?;
    let frontend: FrontendSnapshot =
        serde_json::from_str(ARENA_FRONTEND_JSON).map_err(|_| CatalogError::InvalidSnapshot)?;
    validate_count(intelligence.model_count, intelligence.models.len())?;
    validate_count(coding.variant_count, coding.variants.len())?;
    validate_count(frontend.model_count, frontend.models.len())?;
    validate_unique(intelligence.models.iter().map(|row| row.model_id.as_str()))?;
    validate_unique(coding.variants.iter().map(|row| row.variant_id.as_str()))?;
    validate_unique(frontend.models.iter().map(|row| row.entry_id.as_str()))?;
    if intelligence
        .models
        .iter()
        .any(|row| row.intelligence_index.is_some_and(|score| score < 0))
        || coding
            .variants
            .iter()
            .any(|row| row.index_score < 0 || !row.cost_per_task_usd.is_finite())
        || frontend
            .models
            .iter()
            .any(|row| row.rank == 0 || !row.arena_score.is_finite() || row.arena_score <= 0.0)
    {
        return Err(CatalogError::InvalidSnapshot);
    }
    Ok(AgentIntelligenceCatalog {
        intelligence_metadata: metadata(
            intelligence.schema_version,
            intelligence.catalog_version,
            intelligence.as_of,
            intelligence.source_url,
            intelligence.model_count,
        ),
        coding_metadata: metadata(
            coding.schema_version,
            coding.catalog_version,
            coding.as_of,
            coding.source_url,
            coding.variant_count,
        ),
        frontend_metadata: metadata(
            frontend.schema_version,
            frontend.catalog_version,
            frontend.as_of,
            frontend.source_url,
            frontend.model_count,
        ),
        intelligence: intelligence.models,
        coding: coding.variants,
        frontend: frontend.models,
    })
}

fn metadata(
    schema_version: u64,
    catalog_version: String,
    snapshot_date: String,
    source_url: String,
    row_count: usize,
) -> CatalogMetadata {
    CatalogMetadata {
        schema_version,
        catalog_version,
        snapshot_date,
        source_url,
        row_count,
    }
}

fn validate_count(expected: usize, actual: usize) -> Result<(), CatalogError> {
    (expected == actual)
        .then_some(())
        .ok_or(CatalogError::CountMismatch)
}

fn validate_unique<'a>(ids: impl Iterator<Item = &'a str>) -> Result<(), CatalogError> {
    let mut seen = HashSet::new();
    for id in ids {
        if id.is_empty() || !seen.insert(id) {
            return Err(CatalogError::DuplicateIdentifier);
        }
    }
    Ok(())
}

fn compare_optional_cost(left: Option<f64>, right: Option<f64>) -> Ordering {
    left.unwrap_or(f64::INFINITY)
        .total_cmp(&right.unwrap_or(f64::INFINITY))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_three_embedded_snapshots_are_valid_and_counted() {
        let catalog = AgentIntelligenceCatalog::embedded().unwrap();
        assert_eq!(catalog.metadata().len(), 3);
        assert_eq!(catalog.intelligence_models().len(), 260);
        assert_eq!(catalog.coding_variants().len(), 52);
        assert_eq!(catalog.frontend_rankings().len(), 107);
    }

    #[test]
    fn selectors_never_choose_an_unavailable_model() {
        let catalog = AgentIntelligenceCatalog::embedded().unwrap();
        let intelligence = catalog
            .strongest_available(["gpt-5-6-luna", "gpt-5-6-terra"])
            .unwrap();
        assert!(matches!(
            intelligence.model_id.as_str(),
            "gpt-5-6-luna" | "gpt-5-6-terra"
        ));
        assert!(catalog.strongest_available(["not-measured"]).is_none());
    }

    #[test]
    fn coding_selection_prefers_the_cheapest_qualifying_local_variant() {
        let catalog = AgentIntelligenceCatalog::embedded().unwrap();
        let selected = catalog
            .coding_variant("codex", ["gpt-5-6-sol", "gpt-5-6-luna"], 42)
            .unwrap();
        assert_eq!(selected.variant_id, "codex-gpt-5-6-luna-medium");
        assert!(
            catalog
                .coding_variant("codex", ["gpt-5-6-luna"], 64)
                .is_none()
        );
    }

    #[test]
    fn frontend_selection_uses_arena_score_after_local_filtering() {
        let catalog = AgentIntelligenceCatalog::embedded().unwrap();
        let selected = catalog
            .frontend_model(["gpt-5-6-sol-xhigh", "kimi-k3"])
            .unwrap();
        assert_eq!(selected.model_id, "kimi-k3");
    }
}
