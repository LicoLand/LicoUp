//! Current, network-free model intelligence facts owned by LicoUp.

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

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct AgentModelBenchmark {
    pub intelligence: i64,
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
    last_updated: String,
    source_url: String,
    model_count: usize,
    models: Vec<IntelligenceModel>,
}

#[derive(Clone, Debug, Deserialize)]
struct CodingSnapshot {
    last_updated: String,
    source_url: String,
    methodology_version: String,
    variant_count: usize,
    variants: Vec<CodingAgentVariant>,
}

#[derive(Clone, Debug, Deserialize)]
struct FrontendSnapshot {
    last_updated: String,
    source_url: String,
    #[serde(alias = "ranking_count")]
    model_count: usize,
    #[serde(alias = "rankings")]
    models: Vec<FrontendArenaModel>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CatalogMetadata {
    pub last_updated: String,
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

/// Return the Artificial Analysis Intelligence Index for one Model + Thinking
/// planning option.
pub fn model_intelligence(model_id: &str, thinking: &str) -> Option<i64> {
    AgentIntelligenceCatalog::embedded()
        .ok()?
        .intelligence_model(model_id, thinking)?
        .intelligence_index
}

/// Return the Artificial Analysis Coding Agents score for one exact
/// Agent + Model + Thinking planning option.
pub fn agent_model_intelligence(agent_id: &str, model_id: &str, thinking: &str) -> Option<i64> {
    agent_model_benchmark(agent_id, model_id, thinking).map(|benchmark| benchmark.intelligence)
}

/// Highest measured Coding Agent score for one exact local Agent harness and
/// Model. A Membership Profile has no selected reasoning effort yet, so
/// routing projects the best measured variant and leaves the exact effort to
/// the later binding.
pub fn agent_model_max_intelligence(agent_id: &str, model_id: &str) -> Option<i64> {
    let harness = coding_harness_id(agent_id);
    let model = coding_model_key(model_id);
    AgentIntelligenceCatalog::embedded()
        .ok()?
        .coding_variants()
        .iter()
        .filter(|variant| variant.harness == harness && variant.model == model)
        .map(|variant| variant.index_score)
        .max()
}

pub(crate) fn agent_model_benchmark(
    agent_id: &str,
    model_id: &str,
    thinking: &str,
) -> Option<AgentModelBenchmark> {
    let variant = AgentIntelligenceCatalog::embedded()
        .ok()?
        .coding_variant_exact(agent_id, model_id, thinking)?;
    Some(AgentModelBenchmark {
        intelligence: variant.index_score,
        cost_per_task_usd: variant.cost_per_task_usd,
    })
}

/// Return Intelligence Index points per measured US dollar of task cost.
/// A measured zero-dollar task produces positive infinity, which correctly
/// sorts above every finite ratio while preserving the direct division rule.
pub fn model_intelligence_per_usd(model_id: &str, thinking: &str) -> Option<f64> {
    let model = AgentIntelligenceCatalog::embedded()
        .ok()?
        .intelligence_model(model_id, thinking)?;
    Some(model.intelligence_index? as f64 / model.cost_per_task_usd?)
}

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

    fn intelligence_model(&self, model_id: &str, thinking: &str) -> Option<&IntelligenceModel> {
        let key = intelligence_model_key(model_id, thinking)?;
        self.intelligence.iter().find(|model| model.model_id == key)
    }

    fn coding_variant_exact(
        &self,
        agent_id: &str,
        model_id: &str,
        thinking: &str,
    ) -> Option<&CodingAgentVariant> {
        let harness = coding_harness_id(agent_id);
        let model_id = coding_model_key(model_id);
        let thinking = coding_reasoning_effort(thinking)?;
        self.coding.iter().find(|variant| {
            variant.harness == harness
                && variant.model == model_id
                && variant.reasoning_effort == thinking
        })
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

fn intelligence_model_key(model_id: &str, thinking: &str) -> Option<String> {
    let model_id = intelligence_model_alias(model_id.trim());
    let thinking = thinking.trim().to_ascii_lowercase();
    if model_id.is_empty() || thinking.is_empty() {
        return None;
    }
    Some(match thinking.as_str() {
        "max" | "max-with-fallback" => model_id.to_owned(),
        "none" | "non-reasoning" => format!("{model_id}-non-reasoning"),
        _ => format!("{model_id}-{thinking}"),
    })
}

fn intelligence_model_alias(model_id: &str) -> &str {
    match model_id {
        "gpt-5.6-sol" => "gpt-5-6-sol",
        "gpt-5.6-terra" => "gpt-5-6-terra",
        "gpt-5.6-luna" => "gpt-5-6-luna",
        "gpt-5.5" => "gpt-5-5",
        "gpt-5.4" => "gpt-5-4",
        "opus-5" => "claude-opus-5",
        "fable-5" => "claude-fable-5",
        "opus-4-8" | "claude-opus-4.8" => "claude-opus-4-8",
        "opus-4-7" | "claude-opus-4.7" => "claude-opus-4-7",
        "opus-4-6" | "claude-opus-4.6" => "claude-opus-4-6",
        "sonnet-4-6" | "claude-sonnet-4.6" => "claude-sonnet-4-6",
        "k3" => "kimi-k3",
        "kimi-k2.7-code" => "kimi-k2-7-code",
        "kimi-k2.6" => "kimi-k2-6",
        "gemini-3.6-flash" => "gemini-3-6-flash",
        "gemini-3.1-pro" => "gemini-3-1-pro",
        "muse-spark-1.1" => "muse-spark-1-1",
        "grok-4.5" => "grok-4-5",
        "glm-5.2" => "glm-5-2",
        "glm-5.1" => "glm-5-1",
        "qwen3.7-plus" => "qwen3-7-plus",
        _ => model_id,
    }
}

fn coding_model_key(model_id: &str) -> &str {
    match model_id.trim() {
        "gpt-5.6-sol" => "gpt-5-6-sol",
        "gpt-5.6-terra" => "gpt-5-6-terra",
        "gpt-5.6-luna" => "gpt-5-6-luna",
        "gpt-5.5" => "gpt-5-5",
        "gpt-5.4" => "gpt-5-4",
        "gemini-3.6-flash" => "gemini-3-6-flash",
        "gemini-3.1-pro" => "gemini-3-1-pro",
        "muse-spark-1.1" => "muse-spark-1-1",
        "composer-2.5" => "composer-2-5",
        "composer-2.5-fast" => "composer-2-5-fast",
        "claude-fable-5" => "fable-5",
        "claude-opus-5" => "opus-5",
        "claude-opus-4-8" | "claude-opus-4.8" => "opus-4-8",
        "claude-opus-4-7" | "claude-opus-4.7" => "opus-4-7",
        "claude-opus-4-6" | "claude-opus-4.6" => "opus-4-6",
        "claude-sonnet-4-6" | "claude-sonnet-4.6" => "sonnet-4-6",
        "kimi-k2.6" => "kimi-k2-6",
        "grok-4.5" => "grok-4-5",
        "glm-5.2" => "glm-5-2",
        "glm-5.1" => "glm-5-1",
        "qwen3.7-plus" => "qwen3-7-plus",
        value => value,
    }
}

pub fn coding_harness_id(agent_id: &str) -> &str {
    match agent_id {
        "cursor" => "cursor-cli",
        "kimi-code" => "kimi-code-cli",
        "antigravity" => "gemini-cli",
        value => value,
    }
}

fn coding_reasoning_effort(thinking: &str) -> Option<&str> {
    match thinking.trim().to_ascii_lowercase().as_str() {
        "none" | "non-reasoning" => Some("none"),
        "low" => Some("low"),
        "medium" => Some("medium"),
        "high" => Some("high"),
        "xhigh" => Some("xhigh"),
        "max" => Some("max"),
        "max-with-fallback" => Some("max-with-fallback"),
        "thinking" => Some("thinking"),
        _ => None,
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
    if !valid_date(&intelligence.last_updated)
        || !valid_date(&coding.last_updated)
        || !valid_date(&frontend.last_updated)
        || coding.methodology_version.trim().is_empty()
    {
        return Err(CatalogError::InvalidSnapshot);
    }
    Ok(AgentIntelligenceCatalog {
        intelligence_metadata: metadata(
            intelligence.last_updated,
            intelligence.source_url,
            intelligence.model_count,
        ),
        coding_metadata: metadata(coding.last_updated, coding.source_url, coding.variant_count),
        frontend_metadata: metadata(
            frontend.last_updated,
            frontend.source_url,
            frontend.model_count,
        ),
        intelligence: intelligence.models,
        coding: coding.variants,
        frontend: frontend.models,
    })
}

fn metadata(last_updated: String, source_url: String, row_count: usize) -> CatalogMetadata {
    CatalogMetadata {
        last_updated,
        source_url,
        row_count,
    }
}

fn valid_date(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return false;
    }
    if !bytes
        .iter()
        .enumerate()
        .all(|(index, byte)| index == 4 || index == 7 || byte.is_ascii_digit())
    {
        return false;
    }
    let year = value[0..4].parse::<u32>().ok();
    let month = value[5..7].parse::<u32>().ok();
    let day = value[8..10].parse::<u32>().ok();
    let (Some(year), Some(month), Some(day)) = (year, month, day) else {
        return false;
    };
    if year == 0 || !(1..=12).contains(&month) {
        return false;
    }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days = match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    (1..=days).contains(&day)
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
    fn model_intelligence_matches_model_and_thinking() {
        let catalog = AgentIntelligenceCatalog::embedded().unwrap();
        let max = catalog
            .intelligence_models()
            .iter()
            .find(|model| model.model_id == "gpt-5-6-luna")
            .unwrap();
        let medium = catalog
            .intelligence_models()
            .iter()
            .find(|model| model.model_id == "gpt-5-6-luna-medium")
            .unwrap();
        assert_eq!(
            model_intelligence("gpt-5-6-luna", "max"),
            max.intelligence_index
        );
        assert_eq!(
            model_intelligence("gpt-5-6-luna", "medium"),
            medium.intelligence_index
        );
        assert_eq!(
            model_intelligence("gpt-5.6-luna", "medium"),
            medium.intelligence_index
        );
        assert_eq!(model_intelligence("gpt-5-6-luna", "unknown"), None);
    }

    #[test]
    fn agent_model_intelligence_matches_the_exact_coding_variant() {
        let catalog = AgentIntelligenceCatalog::embedded().unwrap();
        let codex_variant = catalog
            .coding_variants()
            .iter()
            .find(|variant| {
                variant.harness == "codex"
                    && variant.model == "gpt-5-6-luna"
                    && variant.reasoning_effort == "medium"
            })
            .unwrap();
        assert_eq!(
            agent_model_intelligence("codex", "gpt-5-6-luna", "medium"),
            Some(codex_variant.index_score)
        );
        let cursor_variant = catalog
            .coding_variants()
            .iter()
            .find(|variant| {
                variant.harness == "cursor-cli"
                    && variant.model == "composer-2-5"
                    && variant.reasoning_effort == "none"
            })
            .unwrap();
        assert_eq!(
            agent_model_intelligence("cursor", "composer-2-5", "none"),
            Some(cursor_variant.index_score)
        );
        assert_eq!(
            agent_model_intelligence("cursor-cli", "composer-2.5", "none"),
            Some(cursor_variant.index_score)
        );
        assert_eq!(
            agent_model_intelligence("codex", "gpt-5-6-luna", "non-reasoning"),
            agent_model_intelligence("codex", "gpt-5-6-luna", "none")
        );
        assert_eq!(
            agent_model_intelligence("codex", "gpt-5-6-luna", "unknown"),
            None
        );
        assert_eq!(
            agent_model_max_intelligence("codex", "gpt-5.6-luna"),
            catalog
                .coding_variants()
                .iter()
                .filter(|variant| { variant.harness == "codex" && variant.model == "gpt-5-6-luna" })
                .map(|variant| variant.index_score)
                .max()
        );
        assert_eq!(
            agent_model_max_intelligence("codex", "unmeasured-model"),
            None
        );
    }

    #[test]
    fn model_intelligence_per_usd_divides_the_same_leaderboard_row() {
        let catalog = AgentIntelligenceCatalog::embedded().unwrap();
        let medium = catalog
            .intelligence_models()
            .iter()
            .find(|model| model.model_id == "gpt-5-6-luna-medium")
            .unwrap();
        let expected =
            medium.intelligence_index.unwrap() as f64 / medium.cost_per_task_usd.unwrap();
        let actual = model_intelligence_per_usd("gpt-5-6-luna", "medium").unwrap();
        assert!((actual - expected).abs() < f64::EPSILON);
        assert!(model_intelligence_per_usd("gemma-4-31b", "max").is_some_and(f64::is_infinite));
        assert_eq!(model_intelligence_per_usd("not-measured", "max"), None);
    }

    #[test]
    fn all_three_embedded_snapshots_are_valid_and_counted() {
        let catalog = AgentIntelligenceCatalog::embedded().unwrap();
        assert_eq!(catalog.metadata().len(), 3);
        assert!(
            catalog
                .metadata()
                .iter()
                .all(|metadata| metadata.row_count > 0
                    && !metadata.last_updated.is_empty()
                    && metadata.source_url.starts_with("https://"))
        );
        assert_eq!(
            catalog.metadata()[0].row_count,
            catalog.intelligence_models().len()
        );
        assert_eq!(
            catalog.metadata()[1].row_count,
            catalog.coding_variants().len()
        );
        assert_eq!(
            catalog.metadata()[2].row_count,
            catalog.frontend_rankings().len()
        );
        assert!(
            catalog
                .intelligence_models()
                .iter()
                .all(|model| !model.model_id.is_empty())
        );
        assert!(
            catalog
                .coding_variants()
                .iter()
                .all(|variant| !variant.variant_id.is_empty())
        );
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
