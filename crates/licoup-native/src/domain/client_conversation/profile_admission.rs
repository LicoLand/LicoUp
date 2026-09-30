//! Membership Profile admission over projected capability facts.
//!
//! One Profile plus the live facts yields either one resolved participant with
//! the model and reasoning it was admitted with and the reason it was chosen,
//! or a typed refusal that names the requirement no declared fact satisfied and
//! the participants whose answer is unknown. Candidate filters, eligibility,
//! ranking and admission live together because they all read the same
//! projected facts; the fact join itself stays in `profile_snapshot`.

use super::{CapabilityFact, CapabilityFactState, MembershipProfileSnapshot};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

/// Hard constraints applied before any ordering. Every required fact must be
/// declared by the candidate; a missing membership binding is a hard failure,
/// never a silent drop.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CandidateFilters {
    #[serde(default)]
    pub required_authority: Vec<String>,
    #[serde(default)]
    pub required_skills: Vec<String>,
    #[serde(default)]
    pub required_capabilities: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_environment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_readiness: Option<String>,
    #[serde(default)]
    pub membership_ids: Vec<String>,
    #[serde(default)]
    pub pinned_membership_ids: Vec<String>,
    #[serde(default)]
    pub preferred_skills: Vec<String>,
    #[serde(default)]
    pub preferred_capabilities: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_environment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_task: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_task: Option<String>,
}

/// Apply hard filters, then order by the stable lexicographic tuple frozen by
/// Decision 0004: explicit pin, preference match, verified reliability,
/// coding score, known expected price, observed latency and Membership id.
/// Unknown optional facts remain unknown and sort after known facts. Only a
/// declared capability fact satisfies a capability requirement, so an unknown
/// answer never becomes a silent false and never becomes an unearned true.
pub fn rank_candidates(
    snapshots: Vec<MembershipProfileSnapshot>,
    filters: &CandidateFilters,
) -> Result<Vec<MembershipProfileSnapshot>, String> {
    let required_ids = filters.membership_ids.iter().collect::<BTreeSet<_>>();
    let available = snapshots
        .iter()
        .map(|snapshot| &snapshot.membership_id)
        .collect::<BTreeSet<_>>();
    if !required_ids.is_subset(&available) {
        return Err("profile_candidate_rejected".to_owned());
    }
    let mut eligible = snapshots
        .into_iter()
        .filter(|snapshot| {
            (required_ids.is_empty() || required_ids.contains(&snapshot.membership_id))
                && candidate_eligible(snapshot, filters)
        })
        .collect::<Vec<_>>();
    let remaining = eligible
        .iter()
        .map(|snapshot| &snapshot.membership_id)
        .collect::<BTreeSet<_>>();
    if !required_ids.is_subset(&remaining) {
        return Err("profile_candidate_rejected".to_owned());
    }
    let pin_order = filters
        .pinned_membership_ids
        .iter()
        .chain(filters.membership_ids.iter())
        .enumerate()
        .fold(BTreeMap::new(), |mut result, (ordinal, membership_id)| {
            result.entry(membership_id.as_str()).or_insert(ordinal);
            result
        });
    eligible.sort_by(|left, right| {
        pin_order
            .get(left.membership_id.as_str())
            .copied()
            .unwrap_or(usize::MAX)
            .cmp(
                &pin_order
                    .get(right.membership_id.as_str())
                    .copied()
                    .unwrap_or(usize::MAX),
            )
            .then_with(|| preference_misses(left, filters).cmp(&preference_misses(right, filters)))
            .then_with(|| reliability_rank(left).cmp(&reliability_rank(right)))
            .then_with(|| optional_desc(left.intelligence_score, right.intelligence_score))
            .then_with(|| optional_price(left).cmp(&optional_price(right)))
            .then_with(|| optional_asc(left.latency_class, right.latency_class))
            .then_with(|| left.membership_id.cmp(&right.membership_id))
    });
    Ok(eligible)
}

fn candidate_eligible(snapshot: &MembershipProfileSnapshot, filters: &CandidateFilters) -> bool {
    snapshot
        .required_capabilities
        .iter()
        .all(|required| declared_capability(snapshot, required))
        && snapshot
            .skill_references
            .iter()
            .all(|required| snapshot.skills.iter().any(|value| value == required))
        && filters
            .required_authority
            .iter()
            .all(|required| snapshot.authority.iter().any(|value| value == required))
        && filters
            .required_skills
            .iter()
            .all(|required| snapshot.skills.iter().any(|value| value == required))
        && filters
            .required_capabilities
            .iter()
            .all(|required| declared_capability(snapshot, required))
        && filters
            .required_model
            .as_deref()
            .map(|required| snapshot.model.as_deref() == Some(required))
            .unwrap_or(true)
        && filters
            .required_environment
            .as_deref()
            .map(|required| snapshot.environment.as_deref() == Some(required))
            .unwrap_or(true)
        && filters
            .required_readiness
            .as_deref()
            .map(|required| snapshot.readiness.as_deref() == Some(required))
            .unwrap_or(true)
        && filters
            .required_task
            .as_deref()
            .map(|required| snapshot.task_tags.iter().any(|tag| tag == required))
            .unwrap_or(true)
}

/// A requirement is satisfied only by a declared fact.
fn declared_capability(snapshot: &MembershipProfileSnapshot, required: &str) -> bool {
    CapabilityFact::state_of(&snapshot.capabilities, required)
        .is_some_and(CapabilityFactState::satisfies_requirement)
}

fn preference_misses(snapshot: &MembershipProfileSnapshot, filters: &CandidateFilters) -> usize {
    let model = filters
        .preferred_model
        .as_deref()
        .or(snapshot.preferred_model.as_deref());
    let environment = filters
        .preferred_environment
        .as_deref()
        .or(snapshot.preferred_environment.as_deref());
    usize::from(model.is_some_and(|value| snapshot.model.as_deref() != Some(value)))
        + usize::from(
            environment.is_some_and(|value| snapshot.environment.as_deref() != Some(value)),
        )
        + filters
            .preferred_skills
            .iter()
            .filter(|value| !snapshot.skills.contains(value))
            .count()
        + filters
            .preferred_capabilities
            .iter()
            .chain(snapshot.preferred_capabilities.iter())
            .filter(|value| !declared_capability(snapshot, value))
            .count()
        + usize::from(
            filters
                .preferred_task
                .as_deref()
                .is_some_and(|task| !snapshot.task_tags.iter().any(|tag| tag == task)),
        )
}

fn reliability_rank(snapshot: &MembershipProfileSnapshot) -> (bool, u8) {
    let Some(value) = snapshot.reliability_class.as_deref() else {
        return (true, u8::MAX);
    };
    let rank = match value {
        "verified" | "high" | "ready" => 0,
        "standard" | "partial" => 1,
        "low" | "unverified" => 2,
        _ => 3,
    };
    (false, rank)
}

fn optional_desc(left: Option<i64>, right: Option<i64>) -> Ordering {
    match (left, right) {
        (Some(left), Some(right)) => right.cmp(&left),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

fn optional_asc<T: Ord>(left: Option<T>, right: Option<T>) -> Ordering {
    match (left, right) {
        (Some(left), Some(right)) => left.cmp(&right),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

fn optional_price(snapshot: &MembershipProfileSnapshot) -> (bool, u64) {
    let Some(input) = snapshot.price_input_usd_per_million_tokens else {
        return (true, u64::MAX);
    };
    let Some(output) = snapshot.price_output_usd_per_million_tokens else {
        return (true, u64::MAX);
    };
    if !input.is_finite() || !output.is_finite() || input < 0.0 || output < 0.0 {
        return (true, u64::MAX);
    }
    (false, ((input + output) * 1_000_000.0).round() as u64)
}

/// Accounting of one Profile requirement over the whole candidate set.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RequirementOutcome {
    /// At least one participant declares the fact.
    Satisfied,
    /// No participant declares it, and at least one participant has no
    /// readable answer for it.
    Unknown,
    /// Every participant was read and none declares the fact.
    Missing,
}

impl RequirementOutcome {
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Satisfied => "satisfied",
            Self::Unknown => "unknown",
            Self::Missing => "missing",
        }
    }
}

/// One requirement with the participants whose answer is unknown.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileRequirementOutcome {
    pub requirement: String,
    pub outcome: RequirementOutcome,
    pub unknown_membership_ids: Vec<String>,
}

/// Why the resolved participant was chosen.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProfileChoiceOrigin {
    /// An explicit pin decided the choice.
    Pinned,
    /// Every stated preference matched.
    Preference,
    /// The stable ranking order decided the choice.
    Ranked,
}

impl ProfileChoiceOrigin {
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Pinned => "pinned",
            Self::Preference => "preference",
            Self::Ranked => "ranked",
        }
    }

    fn reason(self) -> &'static str {
        match self {
            Self::Pinned => "pinned_membership_admitted",
            Self::Preference => "preference_match_admitted",
            Self::Ranked => "ranked_order_admitted",
        }
    }
}

/// One resolved participant with the model and reasoning it was admitted with.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedProfileChoice {
    pub membership_id: String,
    pub agent_id: String,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub origin: ProfileChoiceOrigin,
    pub reason: String,
    pub capabilities: Vec<CapabilityFact>,
    pub requirements: Vec<ProfileRequirementOutcome>,
}

/// A typed refusal that names the requirement no declared fact satisfied.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileAdmissionRefusal {
    /// The requirement no participant's declared facts satisfied; absent when
    /// the candidate set itself was rejected before requirement accounting.
    pub requirement: Option<String>,
    pub outcome: Option<RequirementOutcome>,
    /// Participants whose answer for the named requirement is unknown.
    pub unknown_membership_ids: Vec<String>,
    pub reason: String,
    pub requirements: Vec<ProfileRequirementOutcome>,
}

impl std::fmt::Display for ProfileAdmissionRefusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.requirement.as_deref() {
            Some(requirement) => write!(formatter, "{}: {requirement}", self.reason),
            None => formatter.write_str(&self.reason),
        }
    }
}

/// One admission result for one Profile.
#[derive(Clone, Debug, PartialEq)]
pub enum ProfileAdmission {
    Admitted(ResolvedProfileChoice),
    Refused(ProfileAdmissionRefusal),
}

impl ProfileAdmission {
    pub fn resolved(&self) -> Option<&ResolvedProfileChoice> {
        match self {
            Self::Admitted(choice) => Some(choice),
            Self::Refused(_) => None,
        }
    }

    pub fn refusal(&self) -> Option<&ProfileAdmissionRefusal> {
        match self {
            Self::Admitted(_) => None,
            Self::Refused(refusal) => Some(refusal),
        }
    }

    /// The three-way accounting of every stated requirement.
    pub fn requirements(&self) -> &[ProfileRequirementOutcome] {
        match self {
            Self::Admitted(choice) => &choice.requirements,
            Self::Refused(refusal) => &refusal.requirements,
        }
    }
}

/// Admit one Profile over the projected facts of its candidate participants.
/// The choice is one eligible participant with the model and reasoning its
/// Profile intent carries, explained by the origin of the choice; when no
/// participant is eligible the result names the requirement that could not be
/// satisfied and the participants whose answer is unknown. Admission starts
/// nothing: it selects, it never dispatches.
pub fn admit_profile_candidates(
    snapshots: &[MembershipProfileSnapshot],
    filters: &CandidateFilters,
) -> ProfileAdmission {
    let requirements = requirement_outcomes(snapshots, filters);
    let ranked = match rank_candidates(snapshots.to_vec(), filters) {
        Ok(ranked) => ranked,
        Err(reason) => {
            return ProfileAdmission::Refused(ProfileAdmissionRefusal {
                requirement: None,
                outcome: None,
                unknown_membership_ids: Vec::new(),
                reason,
                requirements,
            });
        }
    };
    let Some(resolved) = ranked.first() else {
        return ProfileAdmission::Refused(refusal_from_requirements(requirements));
    };
    let origin = choice_origin(resolved, filters);
    ProfileAdmission::Admitted(ResolvedProfileChoice {
        membership_id: resolved.membership_id.clone(),
        agent_id: resolved.agent_id.clone(),
        // The admitted model is the explicit Profile intent when it states one,
        // and the owner-derived default otherwise. The reasoning effort comes
        // from Profile intent alone because no owner derives it.
        model: resolved
            .preferred_model
            .clone()
            .or_else(|| resolved.model.clone()),
        reasoning_effort: resolved.preferred_reasoning_effort.clone(),
        origin,
        reason: origin.reason().to_owned(),
        capabilities: resolved.capabilities.clone(),
        requirements,
    })
}

fn choice_origin(
    snapshot: &MembershipProfileSnapshot,
    filters: &CandidateFilters,
) -> ProfileChoiceOrigin {
    if filters
        .pinned_membership_ids
        .iter()
        .any(|membership_id| membership_id == &snapshot.membership_id)
    {
        return ProfileChoiceOrigin::Pinned;
    }
    if has_preferences(filters) && preference_misses(snapshot, filters) == 0 {
        return ProfileChoiceOrigin::Preference;
    }
    ProfileChoiceOrigin::Ranked
}

fn has_preferences(filters: &CandidateFilters) -> bool {
    filters.preferred_model.is_some()
        || filters.preferred_environment.is_some()
        || filters.preferred_task.is_some()
        || !filters.preferred_skills.is_empty()
        || !filters.preferred_capabilities.is_empty()
}

/// Every requirement of the Profile and of its candidates, in a deterministic
/// order, with the three-way outcome of each one.
fn requirement_outcomes(
    snapshots: &[MembershipProfileSnapshot],
    filters: &CandidateFilters,
) -> Vec<ProfileRequirementOutcome> {
    let mut requirements = filters.required_capabilities.clone();
    for snapshot in snapshots {
        for requirement in &snapshot.required_capabilities {
            if !requirements.contains(requirement) {
                requirements.push(requirement.clone());
            }
        }
    }
    requirements
        .into_iter()
        .map(|requirement| ProfileRequirementOutcome {
            outcome: requirement_outcome(&requirement, snapshots),
            unknown_membership_ids: unknown_membership_ids(&requirement, snapshots),
            requirement,
        })
        .collect()
}

fn requirement_outcome(
    requirement: &str,
    snapshots: &[MembershipProfileSnapshot],
) -> RequirementOutcome {
    let mut unknown = false;
    for snapshot in snapshots {
        match CapabilityFact::state_of(&snapshot.capabilities, requirement) {
            Some(CapabilityFactState::Declared) => return RequirementOutcome::Satisfied,
            // No answer for the name and an explicitly unknown answer are the
            // same condition: no owner could be read for this participant.
            Some(CapabilityFactState::Unknown) | None => unknown = true,
            Some(CapabilityFactState::NotDeclared) => {}
        }
    }
    if unknown {
        RequirementOutcome::Unknown
    } else {
        RequirementOutcome::Missing
    }
}

fn unknown_membership_ids(
    requirement: &str,
    snapshots: &[MembershipProfileSnapshot],
) -> Vec<String> {
    let mut ids = snapshots
        .iter()
        .filter(|snapshot| {
            matches!(
                CapabilityFact::state_of(&snapshot.capabilities, requirement),
                Some(CapabilityFactState::Unknown) | None
            )
        })
        .map(|snapshot| snapshot.membership_id.clone())
        .collect::<Vec<_>>();
    ids.sort();
    ids.dedup();
    ids
}

fn refusal_from_requirements(requirements: Vec<ProfileRequirementOutcome>) -> ProfileAdmissionRefusal {
    let unsatisfied = requirements
        .iter()
        .find(|entry| entry.outcome != RequirementOutcome::Satisfied);
    ProfileAdmissionRefusal {
        requirement: unsatisfied.map(|entry| entry.requirement.clone()),
        outcome: unsatisfied.map(|entry| entry.outcome),
        unknown_membership_ids: unsatisfied
            .map(|entry| entry.unknown_membership_ids.clone())
            .unwrap_or_default(),
        reason: "profile_requirement_unsatisfied".to_owned(),
        requirements,
    }
}
