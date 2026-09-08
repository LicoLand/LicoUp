use licoup_conversation::continuity::{
    ContinuityCandidateIdentity, ContinuityDatasetSplit, ContinuityFailure, ContinuityFailureCode,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use super::failure::invalid_request;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum EvidenceClass {
    #[default]
    Synthetic,
    LiveAuthorized,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ObservationPolarity {
    #[default]
    Negative,
    Positive,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ObservationJudgment {
    #[default]
    Correct,
    FalseTakeover,
    MissedCommitment,
    Abstain,
    Escalation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ClosureClaim {
    UserAcceptance,
    GoalEvaluation,
    WorkerExit,
    TurnExit,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum EconomyRole {
    Candidate,
    Baseline,
    NativeDirect,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HardInvariantCounts {
    #[serde(default)]
    pub unapproved_disclosures: u64,
    #[serde(default)]
    pub known_duplicate_effects: u64,
    #[serde(default)]
    pub fabricated_goal_closures: u64,
    #[serde(default)]
    pub rewritten_authorship: u64,
    #[serde(default)]
    pub deleted_source_resurrections: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ObservationEconomy {
    pub role: EconomyRole,
    #[serde(default)]
    pub classification_cost: Option<f64>,
    #[serde(default)]
    pub retrieval_cost: Option<f64>,
    #[serde(default)]
    pub escalation_cost: Option<f64>,
    #[serde(default)]
    pub execution_cost: Option<f64>,
    #[serde(default)]
    pub retry_cost: Option<f64>,
    #[serde(default)]
    pub rework_cost: Option<f64>,
    #[serde(default)]
    pub measured_full_cost: Option<f64>,
    #[serde(default)]
    pub input_tokens: Option<u64>,
    #[serde(default)]
    pub output_tokens: Option<u64>,
    #[serde(default)]
    pub model_id: Option<String>,
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub thinking: Option<String>,
    #[serde(default)]
    pub serial_latency_ms: Option<u64>,
    #[serde(default)]
    pub correction_count: u64,
    #[serde(default)]
    pub accepted_outcome: bool,
    #[serde(default)]
    pub native_success: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_identity: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version_identity: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource_identity: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QualificationObservation {
    pub observation_id: String,
    pub conversation_family: String,
    pub split: ContinuityDatasetSplit,
    pub subgroup: String,
    pub polarity: ObservationPolarity,
    pub judgment: ObservationJudgment,
    #[serde(default)]
    pub self_confidence: Option<f64>,
    #[serde(default)]
    pub hard_invariants: HardInvariantCounts,
    #[serde(default)]
    pub economy: Option<ObservationEconomy>,
    #[serde(default)]
    pub closure_claim: Option<ClosureClaim>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EvidenceBundle {
    pub responsibility_id: String,
    pub identity: ContinuityCandidateIdentity,
    pub observations: Vec<QualificationObservation>,
    pub evidence_class: EvidenceClass,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SyntheticRecipe {
    pub negative_families: u64,
    pub positive_families: u64,
    pub false_takeovers: u64,
    pub missed_commitments: u64,
    pub abstentions: u64,
    pub split: ContinuityDatasetSplit,
    pub family_prefix: String,
}

impl QualificationObservation {
    pub fn is_abstain(&self) -> bool {
        self.judgment == ObservationJudgment::Abstain
    }

    pub fn is_false_takeover(&self) -> bool {
        self.polarity == ObservationPolarity::Negative
            && self.judgment == ObservationJudgment::FalseTakeover
    }

    pub fn is_missed_commitment(&self) -> bool {
        self.polarity == ObservationPolarity::Positive
            && matches!(
                self.judgment,
                ObservationJudgment::MissedCommitment | ObservationJudgment::Abstain
            )
    }

    pub fn is_raw_error(&self) -> bool {
        self.is_false_takeover() || self.is_missed_commitment()
    }

    pub fn fabricated_from_exit(&self) -> u64 {
        let claimed = matches!(
            self.closure_claim,
            Some(ClosureClaim::WorkerExit | ClosureClaim::TurnExit)
        );
        self.hard_invariants.fabricated_goal_closures + u64::from(claimed)
    }
}

impl EvidenceBundle {
    pub fn from_fixture_parts(
        responsibility_id: String,
        identity: ContinuityCandidateIdentity,
        observations: Vec<QualificationObservation>,
    ) -> Self {
        Self {
            responsibility_id,
            identity,
            observations,
            evidence_class: EvidenceClass::Synthetic,
        }
    }

    /// Live class is never constructed from a fixture document.
    pub fn authorize_live(mut self, admission: LiveAdmission) -> Self {
        let _ = admission;
        self.evidence_class = EvidenceClass::LiveAuthorized;
        self
    }
}

/// Proof that a later authorized live session may mark evidence live. There is
/// no JSON constructor.
#[derive(Clone, Copy, Debug)]
pub struct LiveAdmission {
    _private: (),
}

impl LiveAdmission {
    pub fn for_authorized_live_session() -> Self {
        Self { _private: () }
    }
}

pub fn admit_identity(identity: &ContinuityCandidateIdentity) -> Result<(), ContinuityFailure> {
    for digest in [
        identity.model_digest.as_str(),
        identity.reasoning_digest.as_str(),
        identity.prompt_digest.as_str(),
        identity.skill_digest.as_str(),
        identity.context_policy_digest.as_str(),
        identity.tool_contract_digest.as_str(),
        identity.adapter_runtime_digest.as_str(),
        identity.dataset_version.as_str(),
        identity.policy_revision.as_str(),
    ] {
        if digest.trim().is_empty() {
            return Err(invalid_request(ContinuityFailureCode::InvalidRequest));
        }
    }
    Ok(())
}

pub fn identities_match(
    left: &ContinuityCandidateIdentity,
    right: &ContinuityCandidateIdentity,
) -> bool {
    left == right
}

pub fn identity_changed(
    previous: &ContinuityCandidateIdentity,
    current: &ContinuityCandidateIdentity,
) -> bool {
    previous != current
}

/// Permission-bearing fields a child Conversation may not widen.
pub fn child_expands_parent_permission(
    parent: &ContinuityCandidateIdentity,
    child: &ContinuityCandidateIdentity,
) -> bool {
    parent.model_digest != child.model_digest
        || parent.reasoning_digest != child.reasoning_digest
        || parent.skill_digest != child.skill_digest
        || parent.context_policy_digest != child.context_policy_digest
        || parent.tool_contract_digest != child.tool_contract_digest
        || parent.adapter_runtime_digest != child.adapter_runtime_digest
        || parent.dataset_version != child.dataset_version
        || parent.policy_revision != child.policy_revision
}

pub fn generate_synthetic(
    recipe: &SyntheticRecipe,
    subgroups: &[String],
) -> Result<Vec<QualificationObservation>, ContinuityFailure> {
    if subgroups.is_empty() {
        return Err(invalid_request(ContinuityFailureCode::InvalidRequest));
    }
    let total = recipe
        .negative_families
        .saturating_add(recipe.positive_families);
    if recipe
        .false_takeovers
        .saturating_add(recipe.missed_commitments)
        .saturating_add(recipe.abstentions)
        > total
    {
        return Err(invalid_request(ContinuityFailureCode::InvalidRequest));
    }
    let mut observations = Vec::with_capacity(total as usize);
    let mut remaining_false = recipe.false_takeovers;
    let mut remaining_miss = recipe.missed_commitments;
    let mut remaining_abstain = recipe.abstentions;
    for index in 0..recipe.negative_families {
        let subgroup = subgroups[index as usize % subgroups.len()].clone();
        let judgment = if remaining_false > 0 {
            remaining_false -= 1;
            ObservationJudgment::FalseTakeover
        } else if remaining_abstain > 0 {
            remaining_abstain -= 1;
            ObservationJudgment::Abstain
        } else {
            ObservationJudgment::Correct
        };
        observations.push(family_observation(
            recipe,
            ObservationPolarity::Negative,
            judgment,
            index,
            subgroup,
        ));
    }
    for index in 0..recipe.positive_families {
        let subgroup = subgroups[index as usize % subgroups.len()].clone();
        let judgment = if remaining_miss > 0 {
            remaining_miss -= 1;
            ObservationJudgment::MissedCommitment
        } else if remaining_abstain > 0 {
            remaining_abstain -= 1;
            ObservationJudgment::Abstain
        } else {
            ObservationJudgment::Correct
        };
        observations.push(family_observation(
            recipe,
            ObservationPolarity::Positive,
            judgment,
            recipe.negative_families + index,
            subgroup,
        ));
    }
    Ok(observations)
}

fn family_observation(
    recipe: &SyntheticRecipe,
    polarity: ObservationPolarity,
    judgment: ObservationJudgment,
    index: u64,
    subgroup: String,
) -> QualificationObservation {
    QualificationObservation {
        observation_id: format!("obs:{}:{index}", recipe.family_prefix),
        conversation_family: format!("{}:{index}", recipe.family_prefix),
        split: recipe.split,
        subgroup,
        polarity,
        judgment,
        self_confidence: None,
        hard_invariants: HardInvariantCounts::default(),
        economy: None,
        closure_claim: None,
    }
}

#[derive(Clone, Debug, Default)]
pub struct EvidenceStore {
    bundles: BTreeMap<(String, IdentityKey), EvidenceBundle>,
    withdrawn: BTreeMap<(String, IdentityKey), ContinuityCandidateIdentity>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct IdentityKey {
    model: String,
    reasoning: String,
    prompt: String,
    skill: String,
    context: String,
    tool: String,
    adapter: String,
    dataset: String,
    policy: String,
}

impl IdentityKey {
    fn from_identity(identity: &ContinuityCandidateIdentity) -> Self {
        Self {
            model: identity.model_digest.clone(),
            reasoning: identity.reasoning_digest.clone(),
            prompt: identity.prompt_digest.clone(),
            skill: identity.skill_digest.clone(),
            context: identity.context_policy_digest.clone(),
            tool: identity.tool_contract_digest.clone(),
            adapter: identity.adapter_runtime_digest.clone(),
            dataset: identity.dataset_version.clone(),
            policy: identity.policy_revision.clone(),
        }
    }
}

impl EvidenceStore {
    pub fn ingest(&mut self, bundle: EvidenceBundle) -> Result<(), ContinuityFailure> {
        if bundle.responsibility_id.trim().is_empty() {
            return Err(invalid_request(ContinuityFailureCode::InvalidRequest));
        }
        admit_identity(&bundle.identity)?;
        for observation in &bundle.observations {
            if observation.observation_id.trim().is_empty()
                || observation.conversation_family.trim().is_empty()
                || observation.subgroup.trim().is_empty()
            {
                return Err(invalid_request(ContinuityFailureCode::InvalidRequest));
            }
        }
        let key = (
            bundle.responsibility_id.clone(),
            IdentityKey::from_identity(&bundle.identity),
        );
        if self.bundles.contains_key(&key) {
            return Err(invalid_request(ContinuityFailureCode::IdempotencyConflict));
        }
        self.bundles.insert(key, bundle);
        Ok(())
    }

    pub fn get(
        &self,
        responsibility_id: &str,
        identity: &ContinuityCandidateIdentity,
    ) -> Option<&EvidenceBundle> {
        self.bundles.get(&(
            responsibility_id.to_owned(),
            IdentityKey::from_identity(identity),
        ))
    }

    pub fn withdraw(
        &mut self,
        responsibility_id: &str,
        identity: &ContinuityCandidateIdentity,
    ) -> Result<(), ContinuityFailure> {
        admit_identity(identity)?;
        self.withdrawn.insert(
            (
                responsibility_id.to_owned(),
                IdentityKey::from_identity(identity),
            ),
            identity.clone(),
        );
        Ok(())
    }

    pub fn is_withdrawn(
        &self,
        responsibility_id: &str,
        identity: &ContinuityCandidateIdentity,
    ) -> bool {
        self.withdrawn.contains_key(&(
            responsibility_id.to_owned(),
            IdentityKey::from_identity(identity),
        ))
    }
}
