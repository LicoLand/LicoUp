//! Comparable rankings for Agent + Model + Thinking planning options.

use super::{
    agent_intelligence_catalog::{agent_model_benchmark, model_intelligence},
    provider_model_pricing::{
        PlanningModelPrice, agent_model_planning_price, model_planning_price,
    },
};
use std::{cmp::Ordering, collections::HashSet};

const INPUT_SHARE: f64 = 0.75;
const OUTPUT_SHARE: f64 = 0.25;
const CACHE_HIT_RATE: f64 = 0.90;
const CACHE_CREATE_RATE: f64 = 1.0 - CACHE_HIT_RATE;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct AgentModelOption {
    pub agent_id: String,
    pub model_id: String,
    pub thinking: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RankingBasis {
    ArtificialAnalysisCodingAgents,
    ModelIntelligenceAndRoutePrice,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RankingPriceSource {
    ArtificialAnalysisCodingAgents,
    Agent,
    ModelApi,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RankedAgentModel {
    pub rank: usize,
    pub option: AgentModelOption,
    pub price_source: RankingPriceSource,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentModelRanking {
    pub basis: RankingBasis,
    pub entries: Vec<RankedAgentModel>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RankingError {
    EmptyInput,
    DuplicateOption { index: usize },
    MissingModelIntelligence { index: usize },
    MissingPrice { index: usize },
    InvalidCost { index: usize },
    IncomparablePriceUnits,
}

struct RankCandidate {
    option: AgentModelOption,
    intelligence: i64,
    cost: f64,
    ratio: f64,
    price_source: RankingPriceSource,
}

/// Rank one candidate set without returning the internal value ratio.
///
/// The Artificial Analysis Coding Agents path is used only when it covers the
/// complete input set. Otherwise every option uses Model Intelligence plus its
/// Agent price, falling back to the model's raw API price. The fallback cost
/// models one million planning tokens: 75% input, 25% output, and a 90% cache
/// hit rate within the input share.
pub fn rank_agent_models(options: &[AgentModelOption]) -> Result<AgentModelRanking, RankingError> {
    validate_options(options)?;

    let benchmarks = options
        .iter()
        .map(|option| agent_model_benchmark(&option.agent_id, &option.model_id, &option.thinking))
        .collect::<Option<Vec<_>>>();

    if let Some(benchmarks) = benchmarks {
        let candidates = options
            .iter()
            .cloned()
            .zip(benchmarks)
            .enumerate()
            .map(|(index, (option, benchmark))| {
                candidate(
                    index,
                    option,
                    benchmark.intelligence,
                    benchmark.cost_per_task_usd,
                    RankingPriceSource::ArtificialAnalysisCodingAgents,
                )
            })
            .collect::<Result<Vec<_>, _>>()?;
        return Ok(build_ranking(
            RankingBasis::ArtificialAnalysisCodingAgents,
            candidates,
        ));
    }

    rank_with_model_intelligence(options)
}

fn validate_options(options: &[AgentModelOption]) -> Result<(), RankingError> {
    if options.is_empty() {
        return Err(RankingError::EmptyInput);
    }
    let mut seen = HashSet::with_capacity(options.len());
    for (index, option) in options.iter().enumerate() {
        if !seen.insert(option) {
            return Err(RankingError::DuplicateOption { index });
        }
    }
    Ok(())
}

fn rank_with_model_intelligence(
    options: &[AgentModelOption],
) -> Result<AgentModelRanking, RankingError> {
    let mut candidates = Vec::with_capacity(options.len());
    let mut comparable_unit: Option<String> = None;

    for (index, option) in options.iter().cloned().enumerate() {
        let intelligence = model_intelligence(&option.model_id, &option.thinking)
            .ok_or(RankingError::MissingModelIntelligence { index })?;
        let (price, price_source) =
            agent_model_planning_price(&option.agent_id, &option.model_id, &option.thinking)
                .map(|price| (price, RankingPriceSource::Agent))
                .or_else(|| {
                    model_planning_price(&option.model_id)
                        .map(|price| (price, RankingPriceSource::ModelApi))
                })
                .ok_or(RankingError::MissingPrice { index })?;
        let cost = fallback_cost(&price);
        if cost > 0.0 {
            if let Some(unit) = comparable_unit.as_deref() {
                if unit != price.unit {
                    return Err(RankingError::IncomparablePriceUnits);
                }
            } else {
                comparable_unit = Some(price.unit.clone());
            }
        }
        candidates.push(candidate(index, option, intelligence, cost, price_source)?);
    }

    Ok(build_ranking(
        RankingBasis::ModelIntelligenceAndRoutePrice,
        candidates,
    ))
}

fn fallback_cost(price: &PlanningModelPrice) -> f64 {
    INPUT_SHARE * (CACHE_HIT_RATE * price.cached_input + CACHE_CREATE_RATE * price.input)
        + OUTPUT_SHARE * price.output
}

fn candidate(
    index: usize,
    option: AgentModelOption,
    intelligence: i64,
    cost: f64,
    price_source: RankingPriceSource,
) -> Result<RankCandidate, RankingError> {
    if intelligence < 0 || !cost.is_finite() || cost < 0.0 {
        return Err(RankingError::InvalidCost { index });
    }
    Ok(RankCandidate {
        option,
        intelligence,
        cost,
        ratio: intelligence as f64 / cost,
        price_source,
    })
}

fn build_ranking(basis: RankingBasis, mut candidates: Vec<RankCandidate>) -> AgentModelRanking {
    candidates.sort_by(compare_candidates);
    let mut previous_ratio: Option<f64> = None;
    let mut previous_rank = 0;
    let entries = candidates
        .into_iter()
        .enumerate()
        .map(|(index, candidate)| {
            let rank = if previous_ratio
                .is_some_and(|ratio| ratio.total_cmp(&candidate.ratio) == Ordering::Equal)
            {
                previous_rank
            } else {
                index + 1
            };
            previous_ratio = Some(candidate.ratio);
            previous_rank = rank;
            RankedAgentModel {
                rank,
                option: candidate.option,
                price_source: candidate.price_source,
            }
        })
        .collect();
    AgentModelRanking { basis, entries }
}

fn compare_candidates(left: &RankCandidate, right: &RankCandidate) -> Ordering {
    right
        .ratio
        .total_cmp(&left.ratio)
        .then_with(|| right.intelligence.cmp(&left.intelligence))
        .then_with(|| left.cost.total_cmp(&right.cost))
        .then_with(|| left.option.agent_id.cmp(&right.option.agent_id))
        .then_with(|| left.option.model_id.cmp(&right.option.model_id))
        .then_with(|| left.option.thinking.cmp(&right.option.thinking))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn option(agent_id: &str, model_id: &str, thinking: &str) -> AgentModelOption {
        AgentModelOption {
            agent_id: agent_id.into(),
            model_id: model_id.into(),
            thinking: thinking.into(),
        }
    }

    #[test]
    fn complete_coding_agent_coverage_uses_one_benchmark_path() {
        let ranking = rank_agent_models(&[
            option("codex", "gpt-5-6-sol", "high"),
            option("codex", "gpt-5-6-luna", "medium"),
        ])
        .unwrap();

        assert_eq!(ranking.basis, RankingBasis::ArtificialAnalysisCodingAgents);
        assert_eq!(ranking.entries[0].option.model_id, "gpt-5-6-luna");
        assert!(ranking.entries.iter().all(|entry| {
            entry.price_source == RankingPriceSource::ArtificialAnalysisCodingAgents
        }));
    }

    #[test]
    fn one_missing_coding_variant_downgrades_the_complete_set() {
        let ranking = rank_agent_models(&[
            option("codex", "gpt-5.6-terra", "max-with-fallback"),
            option("codex", "gpt-5.6-luna", "medium"),
        ])
        .unwrap();

        assert_eq!(ranking.basis, RankingBasis::ModelIntelligenceAndRoutePrice);
        assert_eq!(ranking.entries[0].option.model_id, "gpt-5.6-luna");
        assert!(
            ranking
                .entries
                .iter()
                .all(|entry| entry.price_source == RankingPriceSource::Agent)
        );
    }

    #[test]
    fn missing_agent_price_falls_back_to_the_model_api_price() {
        let ranking = rank_agent_models(&[
            option("hermes", "deepseek-v4-pro", "max"),
            option("openclaw", "deepseek-v4-flash", "max"),
        ])
        .unwrap();

        assert_eq!(ranking.entries[0].option.model_id, "deepseek-v4-flash");
        assert!(
            ranking
                .entries
                .iter()
                .all(|entry| entry.price_source == RankingPriceSource::ModelApi)
        );
    }

    #[test]
    fn fallback_cost_uses_input_output_and_cache_planning_shares() {
        let cost = fallback_cost(&PlanningModelPrice {
            input: 10.0,
            cached_input: 1.0,
            output: 20.0,
            unit: "usd_per_million_tokens".into(),
        });
        assert!((cost - 6.425).abs() < f64::EPSILON);
    }

    #[test]
    fn fallback_rejects_incomparable_non_zero_price_units() {
        assert_eq!(
            rank_agent_models(&[
                option("codex", "gpt-5-6-luna", "max-with-fallback"),
                option("hermes", "deepseek-v4-flash", "max"),
            ]),
            Err(RankingError::IncomparablePriceUnits)
        );
    }

    #[test]
    fn duplicate_options_are_not_ranked_twice() {
        let duplicate = option("codex", "gpt-5-6-luna", "medium");
        assert_eq!(
            rank_agent_models(&[duplicate.clone(), duplicate]),
            Err(RankingError::DuplicateOption { index: 1 })
        );
    }
}
