use super::evidence::{EconomyRole, ObservationEconomy};
use super::owners::token_cost_from_owner;
use super::policy::QualificationPolicy;
use super::wilson::nearest_rank_p95;

#[derive(Clone, Debug, PartialEq)]
pub struct EconomicReport {
    pub candidate_full_cost: Option<f64>,
    pub baseline_full_cost: Option<f64>,
    pub cost_per_accepted_outcome_ratio: Option<f64>,
    pub extra_serial_latency_p95_ms: Option<f64>,
    pub candidate_corrections: u64,
    pub baseline_corrections: u64,
    pub native_success_difference: Option<f64>,
    pub paired_success_difference: Option<f64>,
    pub economically_qualified: bool,
    pub unknown_cost: bool,
}

impl EconomicReport {
    pub fn independent_unknown() -> Self {
        Self {
            candidate_full_cost: None,
            baseline_full_cost: None,
            cost_per_accepted_outcome_ratio: None,
            extra_serial_latency_p95_ms: None,
            candidate_corrections: 0,
            baseline_corrections: 0,
            native_success_difference: None,
            paired_success_difference: None,
            economically_qualified: false,
            unknown_cost: true,
        }
    }
}

pub fn evaluate_economy(
    rows: &[ObservationEconomy],
    policy: &QualificationPolicy,
) -> EconomicReport {
    if rows.is_empty() {
        return EconomicReport::independent_unknown();
    }

    let mut candidate_cost = 0.0;
    let mut baseline_cost = 0.0;
    let mut candidate_accepted = 0_u64;
    let mut baseline_accepted = 0_u64;
    let mut candidate_corrections = 0_u64;
    let mut baseline_corrections = 0_u64;
    let mut saw_candidate_cost = false;
    let mut saw_baseline_cost = false;
    let mut unknown_cost = false;
    let mut extra_latency = Vec::new();

    for row in rows {
        let cost = resolve_full_cost(row);
        match row.role {
            EconomyRole::Candidate => {
                candidate_corrections = candidate_corrections.saturating_add(row.correction_count);
                if row.accepted_outcome {
                    candidate_accepted += 1;
                }
                match cost {
                    Some(value) => {
                        candidate_cost += value;
                        saw_candidate_cost = true;
                    }
                    None => unknown_cost = true,
                }
            }
            EconomyRole::Baseline => {
                baseline_corrections = baseline_corrections.saturating_add(row.correction_count);
                if row.accepted_outcome {
                    baseline_accepted += 1;
                }
                match cost {
                    Some(value) => {
                        baseline_cost += value;
                        saw_baseline_cost = true;
                    }
                    None => unknown_cost = true,
                }
            }
            EconomyRole::NativeDirect => {}
        }
    }

    let families = pair_by_equivalent_identity(rows);
    for (candidate, baseline) in &families {
        if let (Some(left), Some(right)) = (candidate.serial_latency_ms, baseline.serial_latency_ms)
        {
            extra_latency.push(left.saturating_sub(right));
        }
    }

    let candidate_cpao = (saw_candidate_cost && candidate_accepted > 0)
        .then(|| candidate_cost / candidate_accepted as f64);
    let baseline_cpao = (saw_baseline_cost && baseline_accepted > 0)
        .then(|| baseline_cost / baseline_accepted as f64);
    let ratio = match (candidate_cpao, baseline_cpao) {
        (Some(candidate), Some(baseline)) if baseline > 0.0 => Some(candidate / baseline),
        _ => None,
    };

    let candidate_success = families
        .iter()
        .filter(|(candidate, _)| candidate.accepted_outcome)
        .count();
    let baseline_success = families
        .iter()
        .filter(|(_, baseline)| baseline.accepted_outcome)
        .count();
    let paired_success_difference = (!families.is_empty()).then(|| {
        candidate_success as f64 / families.len() as f64
            - baseline_success as f64 / families.len() as f64
    });
    let native_pairs: Vec<_> = rows
        .iter()
        .filter(|row| row.role == EconomyRole::Candidate && row.native_success.is_some())
        .collect();
    let native_success_difference = if native_pairs.is_empty() {
        None
    } else {
        let candidate = native_pairs
            .iter()
            .filter(|row| row.accepted_outcome)
            .count() as f64;
        let native = native_pairs
            .iter()
            .filter(|row| row.native_success == Some(true))
            .count() as f64;
        Some(candidate / native_pairs.len() as f64 - native / native_pairs.len() as f64)
    };

    let extra_serial_latency_p95_ms = nearest_rank_p95(&extra_latency);
    let success_ok = paired_success_difference
        .is_some_and(|diff| diff + policy.success_noninferiority_margin >= 0.0);
    let cost_ok = ratio.is_some_and(|value| value <= policy.cost_per_accepted_outcome_ratio_max);
    let latency_ok = extra_serial_latency_p95_ms
        .is_some_and(|value| value <= policy.foreground_added_latency_p95_ms_max);

    EconomicReport {
        candidate_full_cost: saw_candidate_cost.then_some(candidate_cost),
        baseline_full_cost: saw_baseline_cost.then_some(baseline_cost),
        cost_per_accepted_outcome_ratio: ratio,
        extra_serial_latency_p95_ms,
        candidate_corrections,
        baseline_corrections,
        native_success_difference,
        paired_success_difference,
        economically_qualified: !unknown_cost && success_ok && cost_ok && latency_ok,
        unknown_cost,
    }
}

pub fn resolve_full_cost(row: &ObservationEconomy) -> Option<f64> {
    if let Some(measured) = row.measured_full_cost {
        return Some(measured);
    }
    let components = [
        row.classification_cost,
        row.retrieval_cost,
        row.escalation_cost,
        row.execution_cost,
        row.retry_cost,
        row.rework_cost,
    ];
    if components.iter().all(Option::is_some) {
        return Some(components.into_iter().flatten().sum());
    }
    match (row.input_tokens, row.output_tokens) {
        (Some(input), Some(output)) => token_cost_from_owner(
            row.model_id.as_deref(),
            row.agent_id.as_deref(),
            row.thinking.as_deref(),
            input,
            output,
        ),
        _ => None,
    }
}

fn pair_by_equivalent_identity(
    rows: &[ObservationEconomy],
) -> Vec<(&ObservationEconomy, &ObservationEconomy)> {
    let candidates: Vec<_> = rows
        .iter()
        .filter(|row| row.role == EconomyRole::Candidate)
        .collect();
    let mut baselines: Vec<_> = rows
        .iter()
        .filter(|row| row.role == EconomyRole::Baseline)
        .collect();
    let mut pairs = Vec::new();
    for candidate in candidates {
        let Some(identity) = economy_identity(candidate) else {
            continue;
        };
        if let Some(index) = baselines
            .iter()
            .position(|baseline| economy_identity(baseline).as_ref() == Some(&identity))
        {
            let baseline = baselines.remove(index);
            pairs.push((candidate, baseline));
        }
    }
    pairs
}

fn economy_identity(row: &ObservationEconomy) -> Option<(String, String, String)> {
    let task = row
        .task_identity
        .as_deref()
        .filter(|value| !value.trim().is_empty())?;
    let version = row
        .version_identity
        .as_deref()
        .filter(|value| !value.trim().is_empty())?;
    let resource = row
        .resource_identity
        .as_deref()
        .filter(|value| !value.trim().is_empty())?;
    Some((task.to_owned(), version.to_owned(), resource.to_owned()))
}
