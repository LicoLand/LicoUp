//! Comparable task outcomes produced from the real completion, review,
//! settlement and ledger events, with the provenance a later judgment needs.
//!
//! The catalogue, the price owner and the ledger already record what happened:
//! a graph run completed, failed or was cancelled, a review changed or did not
//! change the result, a charge settled late, an execution is still in flight.
//! None of them decides whether two configurations are comparable, and none of
//! them may decide that on its own — that answer needs the *scope* a sample
//! belongs to and the *provenance* it was produced under. This module is that
//! join, and it owns exactly four things:
//!
//! - **One scoped record per comparable scope.** [`OutcomeScope`] is the
//!   project, the task family, the candidate configuration, the baseline it is
//!   compared with, the configuration revision, the selection-policy revision
//!   in force when the work was admitted, the orchestration revision and the
//!   context-policy identity. Events with the same scope update the record they
//!   already have: a repeated completion or a late charge never creates a
//!   second record, and an event that was already applied is absorbed by its
//!   [`OutcomeEvent::event_id`] instead of being counted twice.
//! - **Comparability, not a score.** [`ComparableTaskOutcome::comparable_outcome`]
//!   materializes the existing
//!   [`ComparableOutcome`](crate::domain::model_planning::ComparableOutcome)
//!   pairing the planning owner qualifies. This module never qualifies, never
//!   adopts and never revokes: it fills the facts and leaves `policy_pass`
//!   false, which is the value the existing qualification owner overwrites
//!   after its own policy runs.
//! - **Provenance that does not overclaim.** A routing-only sample says so:
//!   [`OutcomeSampleKind::Routing`] can only ever propose a routing change, so
//!   a routing sample is never read as a general context or collaboration
//!   improvement. Synthetic validation stays
//!   [`EvidenceClass::Synthetic`] and never becomes live qualification, and an
//!   unknown charge makes the economics unknown instead of free.
//! - **Judgment as evidence, not authority.** A judgment input is recorded with
//!   its evaluator, rationale and evidence digest as *proposal* evidence. It
//!   cannot change the active policy: the register has no transition that
//!   adopts, supersedes or revokes, and the selection policy register remains
//!   the only owner of those. An invocation that would actually spend or
//!   disclose requires its own admission; a missing, uncertain or rejected
//!   judgment leaves ordinary dispatch untouched.
//!
//! Nothing here reads a transcript, a prompt, a reply, a credential or a native
//! path. The retained facts are opaque identities, counters, charges and
//! revisions, and the storage entry is one bounded record in the existing
//! client-state `settings` collection — the same durable owner the selection
//! policy register uses.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::{Display, Formatter};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::domain::agent_intelligence_catalog::qualification::{
    EvidenceClass, nearest_rank_p95,
};
use crate::domain::model_planning::{
    AgentModelOption, ComparableOutcome, OutcomeCoverage, PlanningScope, StrategySource,
};

/// The `settings` entry this owner reads and writes.
pub const COMPARABLE_OUTCOMES_SETTINGS_KEY: &str = "comparableTaskOutcomes";

/// The revision identity of the retained outcome document.
pub const COMPARABLE_OUTCOMES_SCHEMA: &str = "licoup.comparable-task-outcomes.v1";

/// How many scoped outcomes are retained. Older scopes are dropped, never
/// silently merged into a newer scope.
pub const MAX_RETAINED_OUTCOMES: usize = 64;

/// How many latency samples one scope keeps for its p95.
pub const MAX_LATENCY_SAMPLES: usize = 256;

const SETTINGS_COLLECTION: &str = "settings";

/// The candidate configuration one comparable outcome was produced with.
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CandidateProvenance {
    /// The Agent runtime that ran the work.
    pub agent_id: String,
    /// The model selector that Agent ran.
    pub model_id: String,
    /// The serving provider, when the request declared one. Never inferred.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_id: Option<String>,
    /// The reasoning effort, when the request declared one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
}

impl CandidateProvenance {
    pub fn new(agent_id: impl Into<String>, model_id: impl Into<String>) -> Self {
        Self {
            agent_id: agent_id.into(),
            model_id: model_id.into(),
            provider_id: None,
            reasoning_effort: None,
        }
    }

    fn identity(&self) -> String {
        let provider = self.provider_id.as_deref().unwrap_or("-");
        let effort = self.reasoning_effort.as_deref().unwrap_or("-");
        format!("{}/{}/{}/{}", self.agent_id, self.model_id, provider, effort)
    }
}

/// What kind of sample produced the outcome.
///
/// The kind bounds what the evidence may later propose. A routing-only sample
/// measured one candidate order; it says nothing about context handling or
/// collaboration, so it can never be promoted as an improvement to either.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutcomeSampleKind {
    #[default]
    Routing,
    Context,
    Collaboration,
}

/// The subject a promotion proposal may name, derived from the sample kind.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutcomePromotionSubject {
    /// Only the candidate order may change.
    RoutingOnly,
    /// The sample measured context handling or collaboration, so it may speak
    /// to that as well as to the route.
    RoutingAndContext,
}

impl OutcomeSampleKind {
    /// The stable token this kind contributes to a scope identity.
    fn token(self) -> &'static str {
        match self {
            Self::Routing => "routing",
            Self::Context => "context",
            Self::Collaboration => "collaboration",
        }
    }

    fn promotion_subject(self) -> OutcomePromotionSubject {
        match self {
            Self::Routing => OutcomePromotionSubject::RoutingOnly,
            Self::Context | Self::Collaboration => OutcomePromotionSubject::RoutingAndContext,
        }
    }
}

/// Identity of one comparable outcome scope.
///
/// Every part is identity: two samples whose configuration revision or policy
/// revision differ are not comparable and are never averaged into one record.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OutcomeScope {
    /// The project the work belongs to. Outcomes in different projects never
    /// invalidate each other.
    pub project_id: String,
    /// The task family the work belongs to inside the project.
    pub task_family: String,
    pub candidate: CandidateProvenance,
    /// The configuration the candidate is compared with, when the sample is a
    /// pairing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub baseline: Option<CandidateProvenance>,
    /// The configuration revision the work was admitted with.
    pub configuration_revision: String,
    /// The selection-policy revision in force when the work was admitted.
    pub policy_revision: String,
    /// The orchestration revision the work ran under.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub orchestration_revision: Option<String>,
    /// The context-policy identity the work ran under.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_policy_id: Option<String>,
    #[serde(default)]
    pub sample_kind: OutcomeSampleKind,
}

impl OutcomeScope {
    /// The stable key of this scope inside the register.
    ///
    /// Every member of the scope is part of its identity, the sample kind
    /// included: a routing sample and a context sample measured different
    /// things, so they are two records and never one averaged record.
    pub fn key(&self) -> String {
        let baseline = self.baseline.as_ref().map(CandidateProvenance::identity);
        format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{}",
            self.project_id,
            self.task_family,
            self.candidate.identity(),
            baseline.unwrap_or_else(|| "-".to_owned()),
            self.configuration_revision,
            self.policy_revision,
            self.orchestration_revision.as_deref().unwrap_or("-"),
            self.context_policy_id.as_deref().unwrap_or("-"),
            self.sample_kind.token(),
        )
    }

    /// The suggestion identity this scope's outcomes invalidate.
    fn suggestion_identity(&self) -> SuggestionIdentity {
        SuggestionIdentity {
            project_id: self.project_id.clone(),
            task_family: self.task_family.clone(),
            configuration_revision: self.configuration_revision.clone(),
        }
    }

    fn validate(&self) -> Result<(), OutcomeEventError> {
        if self.project_id.trim().is_empty() {
            return Err(OutcomeEventError::EmptyIdentity("projectId"));
        }
        if self.task_family.trim().is_empty() {
            return Err(OutcomeEventError::EmptyIdentity("taskFamily"));
        }
        if self.candidate.agent_id.trim().is_empty() {
            return Err(OutcomeEventError::EmptyIdentity("candidate.agentId"));
        }
        if self.candidate.model_id.trim().is_empty() {
            return Err(OutcomeEventError::EmptyIdentity("candidate.modelId"));
        }
        if self.configuration_revision.trim().is_empty() {
            return Err(OutcomeEventError::EmptyIdentity("configurationRevision"));
        }
        if self.policy_revision.trim().is_empty() {
            return Err(OutcomeEventError::EmptyIdentity("policyRevision"));
        }
        Ok(())
    }
}

/// What happened, as the existing owners already recorded it.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutcomeEventKind {
    /// The task reached its accepted end.
    Completion,
    /// The task failed.
    Failure,
    /// The task was cancelled.
    Cancellation,
    /// The task needed rework after it was reported done.
    Rework,
    /// The task is still running; the sample is not terminal.
    InFlight,
    /// A charge settled after the task was already counted.
    LateCharge,
}

/// One observed fact about a scope.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OutcomeEvent {
    /// The producer's own event identity. Re-applying the same event is
    /// absorbed instead of counted twice.
    pub event_id: String,
    pub scope: OutcomeScope,
    pub kind: OutcomeEventKind,
    /// Whether the observed result was accepted by its reviewer or user.
    #[serde(default)]
    pub accepted: bool,
    /// Rework corrections the accepted result needed.
    #[serde(default)]
    pub corrections: u64,
    /// End-to-end latency of this sample, when the producer measured one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,
    /// The charge this event settled. `None` means the charge is not known;
    /// it is never read as zero.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub charge: Option<f64>,
    /// Whether a review was observed for this sample, and whether it changed
    /// the result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_effective: Option<bool>,
    /// The evidence class the producer observed this with.
    #[serde(default)]
    pub evidence_class: EvidenceClass,
    pub observed_at_ms: i64,
}

impl OutcomeEvent {
    fn validate(&self) -> Result<(), OutcomeEventError> {
        if self.event_id.trim().is_empty() {
            return Err(OutcomeEventError::EmptyIdentity("eventId"));
        }
        if let Some(charge) = self.charge
            && (!charge.is_finite() || charge < 0.0)
        {
            return Err(OutcomeEventError::InvalidCharge);
        }
        self.scope.validate()
    }
}

/// Why a comparable conclusion cannot be drawn yet.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutcomeEvidenceGap {
    /// Only synthetic validation exists; live qualification is a different
    /// claim and is never inferred from it.
    SyntheticOnly,
    /// At least one charge is unknown, so cost per accepted outcome is unknown.
    UnknownCost,
    /// No terminal sample was observed yet.
    NoTerminalSample,
    /// A charge settled after the sample was counted and is still pending.
    PendingLateCharge,
    /// No outcome was recorded for this scope at all.
    NoOutcome,
}

/// The aggregate of every event recorded for one scope.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ComparableTaskOutcome {
    pub scope: OutcomeScope,
    pub completed: u64,
    pub failed: u64,
    pub cancelled: u64,
    pub rework: u64,
    pub in_flight: u64,
    pub late_charges: u64,
    /// Samples whose reviewer or user accepted the result.
    pub accepted: u64,
    pub corrections: u64,
    /// Samples where a review was observed at all.
    pub reviews_observed: u64,
    /// Samples where the observed review changed the result.
    pub reviews_effective: u64,
    /// Sum of the charges the producers actually reported.
    pub known_cost: f64,
    /// Events whose charge is not known. Any value above zero makes the
    /// economics unknown.
    pub unknown_cost_events: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub latency_samples_ms: Vec<u64>,
    pub evidence_class: EvidenceClass,
    /// Monotonic per scope: one increment per accepted event.
    pub revision: u64,
    pub first_observed_at_ms: i64,
    pub updated_at_ms: i64,
    /// The producer event identities already applied to this scope.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub applied_events: BTreeSet<String>,
}

impl ComparableTaskOutcome {
    fn new(scope: OutcomeScope, observed_at_ms: i64) -> Self {
        Self {
            scope,
            completed: 0,
            failed: 0,
            cancelled: 0,
            rework: 0,
            in_flight: 0,
            late_charges: 0,
            accepted: 0,
            corrections: 0,
            reviews_observed: 0,
            reviews_effective: 0,
            known_cost: 0.0,
            unknown_cost_events: 0,
            latency_samples_ms: Vec::new(),
            evidence_class: EvidenceClass::Synthetic,
            revision: 0,
            first_observed_at_ms: observed_at_ms,
            updated_at_ms: observed_at_ms,
            applied_events: BTreeSet::new(),
        }
    }

    /// Terminal samples: the work reached an end, accepted or not.
    pub fn terminal_samples(&self) -> u64 {
        self.completed + self.failed + self.cancelled
    }

    /// Whether every charge this scope depends on is known.
    pub fn cost_is_known(&self) -> bool {
        self.unknown_cost_events == 0 && self.known_cost.is_finite()
    }

    /// The nearest-rank p95 of the retained latency samples.
    pub fn latency_p95_ms(&self) -> Option<u64> {
        nearest_rank_p95(&self.latency_samples_ms).map(|value| value.round() as u64)
    }

    /// The cost per accepted outcome, or `None` while it is unknown.
    pub fn cost_per_accepted_outcome(&self) -> Option<f64> {
        if !self.cost_is_known() || self.accepted == 0 {
            return None;
        }
        Some(self.known_cost / self.accepted as f64)
    }

    /// Whether this record's evidence may support a learning conclusion.
    ///
    /// Synthetic validation is not live qualification, an unknown charge is
    /// not zero, and a scope with no terminal sample has nothing to conclude
    /// from. A late charge that is still pending keeps the economics open.
    pub fn evidence_gap(&self) -> Option<OutcomeEvidenceGap> {
        if self.terminal_samples() == 0 {
            return Some(OutcomeEvidenceGap::NoTerminalSample);
        }
        if self.evidence_class != EvidenceClass::LiveAuthorized {
            return Some(OutcomeEvidenceGap::SyntheticOnly);
        }
        if !self.cost_is_known() {
            return Some(OutcomeEvidenceGap::UnknownCost);
        }
        None
    }

    pub fn supports_learning_conclusion(&self) -> bool {
        self.evidence_gap().is_none()
    }

    /// Observed coverage, in the vocabulary the planning qualification owner
    /// already reads.
    fn coverage(&self) -> OutcomeCoverage {
        OutcomeCoverage {
            failures: self.failed > 0,
            cancellations: self.cancelled > 0,
            in_flight: self.in_flight > 0,
            rework: self.rework > 0,
            late_charges: self.late_charges > 0,
        }
    }

    /// Pair this outcome with its baseline as the existing comparable-outcome
    /// type, or `None` when the two are not comparable.
    ///
    /// Every part of the scope is identity, so a pairing is refused unless the
    /// two samples share the project, the task family, the configuration
    /// revision, the selection-policy revision, the orchestration revision, the
    /// context-policy identity and the sample kind. A sample produced under a
    /// different policy or a different context policy is not evidence about
    /// this one, and a routing sample is never paired against a context sample.
    ///
    /// `policy_pass` is left false: the qualification owner sets it after its
    /// own policy runs, and this producer never qualifies.
    pub fn comparable_outcome(
        &self,
        baseline: &ComparableTaskOutcome,
    ) -> Option<ComparableOutcome> {
        if self.scope.project_id != baseline.scope.project_id
            || self.scope.task_family != baseline.scope.task_family
            || self.scope.configuration_revision != baseline.scope.configuration_revision
            || self.scope.policy_revision != baseline.scope.policy_revision
            || self.scope.orchestration_revision != baseline.scope.orchestration_revision
            || self.scope.context_policy_id != baseline.scope.context_policy_id
            || self.scope.sample_kind != baseline.scope.sample_kind
            || self.scope.candidate == baseline.scope.candidate
        {
            return None;
        }
        let paired_cases = self.terminal_samples().min(baseline.terminal_samples());
        if paired_cases == 0 {
            return None;
        }
        let planning_scope = PlanningScope::new(
            self.scope.task_family.clone(),
            self.scope.configuration_revision.clone(),
        )
        .ok()?;
        let source = StrategySource::new(
            "comparable-task-outcome",
            COMPARABLE_OUTCOMES_SCHEMA,
        )
        .ok()?;
        Some(ComparableOutcome {
            strategy_id: format!(
                "{}::{}",
                self.scope.key(),
                baseline.scope.key()
            ),
            candidate: AgentModelOption {
                agent_id: self.scope.candidate.agent_id.clone(),
                model_id: self.scope.candidate.model_id.clone(),
                thinking: self
                    .scope
                    .candidate
                    .reasoning_effort
                    .clone()
                    .unwrap_or_default(),
            },
            baseline: AgentModelOption {
                agent_id: baseline.scope.candidate.agent_id.clone(),
                model_id: baseline.scope.candidate.model_id.clone(),
                thinking: baseline
                    .scope
                    .candidate
                    .reasoning_effort
                    .clone()
                    .unwrap_or_default(),
            },
            scope: planning_scope,
            source,
            paired_cases,
            candidate_accepted: self.accepted.min(paired_cases),
            baseline_accepted: baseline.accepted.min(paired_cases),
            candidate_cost_per_accepted_outcome: self.cost_per_accepted_outcome(),
            baseline_cost_per_accepted_outcome: baseline.cost_per_accepted_outcome(),
            candidate_corrections: self.corrections,
            baseline_corrections: baseline.corrections,
            candidate_latency_p95_ms: self.latency_p95_ms(),
            baseline_latency_p95_ms: baseline.latency_p95_ms(),
            coverage: OutcomeCoverage {
                failures: self.coverage().failures && baseline.coverage().failures,
                cancellations: self.coverage().cancellations
                    && baseline.coverage().cancellations,
                in_flight: self.coverage().in_flight && baseline.coverage().in_flight,
                rework: self.coverage().rework && baseline.coverage().rework,
                late_charges: self.coverage().late_charges
                    && baseline.coverage().late_charges,
            },
            evidence_class: if self.evidence_class == EvidenceClass::LiveAuthorized
                && baseline.evidence_class == EvidenceClass::LiveAuthorized
            {
                EvidenceClass::LiveAuthorized
            } else {
                EvidenceClass::Synthetic
            },
            policy_pass: false,
        })
    }
}

/// The identity a suggestion is scoped to.
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SuggestionIdentity {
    pub project_id: String,
    pub task_family: String,
    pub configuration_revision: String,
}

/// One suggestion a producer offered for a scope.
///
/// This register does not compute suggestions; it records which ones exist so
/// that a changed outcome invalidates exactly the affected ones.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OutcomeSuggestion {
    pub suggestion_id: String,
    pub identity: SuggestionIdentity,
    pub policy_revision: String,
    #[serde(default)]
    pub invalidated: bool,
}

/// Why a suggestion was invalidated.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InvalidationCause {
    OutcomeChanged,
    PolicySuperseded,
}

/// What one applied event changed.
#[derive(Clone, Debug, PartialEq)]
pub struct OutcomeUpdate {
    pub scope_key: String,
    /// Whether the event changed the retained facts. A repeated event is
    /// absorbed and reports `false`.
    pub applied: bool,
    pub revision: u64,
    pub invalidated_suggestions: Vec<String>,
    pub cause: InvalidationCause,
}

/// One judgment input, attributed to the evaluator that made it.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutcomeEvaluation {
    /// The evaluator judged the evidence usable for a proposal.
    Usable,
    /// The evaluator rejected the evidence.
    Rejected,
    /// The evaluator could not decide.
    Uncertain,
    /// No evaluation was produced at all.
    Missing,
}

/// A judgment about one scope, as the authorized evaluator reported it.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OutcomeJudgment {
    /// The Agent that judged. Proposals are attributable, never anonymous.
    pub evaluator_id: String,
    pub evaluation: OutcomeEvaluation,
    /// The evaluator's own words. Free text; not a required reply format.
    #[serde(default)]
    pub rationale: String,
    /// The bounded evidence digest the judgment was made against.
    pub evidence_digest: String,
    pub submitted_at_ms: i64,
}

impl OutcomeJudgment {
    fn validate(&self) -> Result<(), OutcomeEventError> {
        if self.evaluator_id.trim().is_empty() {
            return Err(OutcomeEventError::EmptyIdentity("evaluatorId"));
        }
        if self.evidence_digest.trim().is_empty() {
            return Err(OutcomeEventError::EmptyIdentity("evidenceDigest"));
        }
        if self.evaluation != OutcomeEvaluation::Missing && self.rationale.trim().is_empty() {
            return Err(OutcomeEventError::EmptyRationale);
        }
        Ok(())
    }
}

/// The proposal a recorded judgment contributes.
///
/// It is evidence for a user decision, never a policy transition: the active
/// policy revision reported here is the revision that stays in force.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OutcomeProposal {
    pub scope_key: String,
    pub evaluator_id: String,
    pub evaluation: OutcomeEvaluation,
    pub rationale: String,
    pub evidence_digest: String,
    pub promotion_subject: OutcomePromotionSubject,
    /// Whether the evaluator proposed a policy change the user may adopt.
    pub proposes_policy_change: bool,
    /// The revision still in force after recording this judgment.
    pub active_policy_revision: String,
}

/// Bounded, attributable evidence for one scope.
#[derive(Clone, Debug, PartialEq)]
pub struct OutcomeEvidence {
    pub scope_key: String,
    pub policy_revision: String,
    pub evidence_class: EvidenceClass,
    pub terminal_samples: u64,
    pub applied_events: usize,
    pub digest: String,
    pub gap: Option<OutcomeEvidenceGap>,
}

/// Who authorized one actual evaluator invocation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvaluatorAdmission {
    /// The authority that admitted the invocation.
    pub authority: String,
    /// Whether the disclosed evidence was authorized for this evaluator.
    pub disclosure_authorized: bool,
    /// Whether the work admission owner admitted the invocation.
    pub work_admitted: bool,
    /// The cost the invocation may spend. A non-positive budget admits none.
    pub max_cost: f64,
}

/// A request to invoke an evaluator over one scope.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvaluatorInvocation {
    pub scope_key: String,
    pub evaluator_id: String,
}

/// The granted invocation and the evidence it may read.
#[derive(Clone, Debug, PartialEq)]
pub struct EvaluatorInvocationGrant {
    pub invocation: EvaluatorInvocation,
    pub evidence: OutcomeEvidence,
    pub admitted_cost: f64,
}

/// Why an evaluator invocation was refused.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EvaluatorRefusal {
    /// No admission accompanied the invocation.
    NoAdmission,
    /// The admission did not authorize the disclosure.
    DisclosureNotAuthorized,
    /// The admission did not admit the work.
    WorkNotAdmitted,
    /// The admission carried no spendable budget.
    BudgetNotAuthorized,
    /// No outcome exists for the named scope.
    UnknownScope,
}

impl Display for EvaluatorRefusal {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        let code = match self {
            Self::NoAdmission => "evaluator_admission_missing",
            Self::DisclosureNotAuthorized => "evaluator_disclosure_not_authorized",
            Self::WorkNotAdmitted => "evaluator_work_not_admitted",
            Self::BudgetNotAuthorized => "evaluator_budget_not_authorized",
            Self::UnknownScope => "evaluator_scope_unknown",
        };
        formatter.write_str(code)
    }
}

impl std::error::Error for EvaluatorRefusal {}

/// Why an event or judgment was refused.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutcomeEventError {
    EmptyIdentity(&'static str),
    InvalidCharge,
    EmptyRationale,
}

impl Display for OutcomeEventError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EmptyIdentity(field) => write!(formatter, "outcome_identity_empty:{field}"),
            Self::InvalidCharge => formatter.write_str("outcome_charge_invalid"),
            Self::EmptyRationale => formatter.write_str("outcome_rationale_empty"),
        }
    }
}

impl std::error::Error for OutcomeEventError {}

/// The scoped outcome register: the one owner of comparable task outcomes.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OutcomeRegister {
    #[serde(default)]
    schema: String,
    /// The policy revision in force. Reading outcomes never changes it, and
    /// nothing in this register can.
    #[serde(default)]
    policy_revision: String,
    #[serde(default)]
    outcomes: BTreeMap<String, ComparableTaskOutcome>,
    #[serde(default)]
    suggestions: BTreeMap<String, OutcomeSuggestion>,
    #[serde(default)]
    proposals: Vec<OutcomeProposal>,
}

impl OutcomeRegister {
    pub fn new(policy_revision: impl Into<String>) -> Self {
        Self {
            schema: COMPARABLE_OUTCOMES_SCHEMA.to_owned(),
            policy_revision: policy_revision.into(),
            outcomes: BTreeMap::new(),
            suggestions: BTreeMap::new(),
            proposals: Vec::new(),
        }
    }

    /// The policy revision in force. Recording an outcome or a judgment never
    /// changes it.
    pub fn policy_revision(&self) -> &str {
        &self.policy_revision
    }

    pub fn outcome(&self, scope_key: &str) -> Option<&ComparableTaskOutcome> {
        self.outcomes.get(scope_key)
    }

    pub fn outcomes(&self) -> impl Iterator<Item = &ComparableTaskOutcome> {
        self.outcomes.values()
    }

    /// How many scope records are retained.
    pub fn retained(&self) -> usize {
        self.outcomes.len()
    }

    /// Record one observation against its scope.
    ///
    /// The scope key selects the record, so repeated completions or late
    /// charges update the outcome that already exists. An event whose identity
    /// was already applied is absorbed: it neither increments a counter nor
    /// invalidates a suggestion a second time.
    pub fn record(&mut self, event: OutcomeEvent) -> Result<OutcomeUpdate, OutcomeEventError> {
        event.validate()?;
        let scope_key = event.scope.key();
        let entry = self
            .outcomes
            .entry(scope_key.clone())
            .or_insert_with(|| ComparableTaskOutcome::new(event.scope.clone(), event.observed_at_ms));
        if entry.applied_events.contains(&event.event_id) {
            return Ok(OutcomeUpdate {
                scope_key,
                applied: false,
                revision: entry.revision,
                invalidated_suggestions: Vec::new(),
                cause: InvalidationCause::OutcomeChanged,
            });
        }

        entry.revision += 1;
        entry.updated_at_ms = entry.updated_at_ms.max(event.observed_at_ms);
        entry.applied_events.insert(event.event_id.clone());
        if event.evidence_class == EvidenceClass::LiveAuthorized {
            entry.evidence_class = EvidenceClass::LiveAuthorized;
        }
        match event.kind {
            OutcomeEventKind::Completion => {
                entry.completed += 1;
                if event.accepted {
                    entry.accepted += 1;
                }
            }
            OutcomeEventKind::Failure => entry.failed += 1,
            OutcomeEventKind::Cancellation => entry.cancelled += 1,
            OutcomeEventKind::Rework => entry.rework += 1,
            OutcomeEventKind::InFlight => entry.in_flight += 1,
            OutcomeEventKind::LateCharge => entry.late_charges += 1,
        }
        entry.corrections = entry.corrections.saturating_add(event.corrections);
        if let Some(review_effective) = event.review_effective {
            entry.reviews_observed += 1;
            if review_effective {
                entry.reviews_effective += 1;
            }
        }
        match event.charge {
            Some(charge) => entry.known_cost += charge,
            None => entry.unknown_cost_events += 1,
        }
        if let Some(latency_ms) = event.latency_ms {
            if entry.latency_samples_ms.len() < MAX_LATENCY_SAMPLES {
                entry.latency_samples_ms.push(latency_ms);
            }
        }
        let revision = entry.revision;
        let invalidated = self.invalidate_suggestions(&event.scope.suggestion_identity());
        self.retain_bounded();
        Ok(OutcomeUpdate {
            scope_key,
            applied: true,
            revision,
            invalidated_suggestions: invalidated,
            cause: InvalidationCause::OutcomeChanged,
        })
    }

    /// Register a suggestion so a later outcome change can invalidate it.
    pub fn register_suggestion(&mut self, suggestion: OutcomeSuggestion) {
        self.suggestions
            .insert(suggestion.suggestion_id.clone(), suggestion);
    }

    pub fn suggestion(&self, suggestion_id: &str) -> Option<&OutcomeSuggestion> {
        self.suggestions.get(suggestion_id)
    }

    /// Invalidate exactly the suggestions scoped to one identity.
    ///
    /// Suggestions for another project, task family or configuration revision
    /// are untouched, which is what keeps an unrelated project's proposal
    /// valid when this project's facts move.
    fn invalidate_suggestions(&mut self, identity: &SuggestionIdentity) -> Vec<String> {
        let affected = self
            .suggestions
            .iter()
            .filter(|(_, suggestion)| &suggestion.identity == identity && !suggestion.invalidated)
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        for id in &affected {
            if let Some(suggestion) = self.suggestions.get_mut(id) {
                suggestion.invalidated = true;
            }
        }
        affected
    }

    /// Record a judgment as proposal evidence.
    ///
    /// The active policy revision is returned unchanged: this register has no
    /// adopt, supersede or revoke transition, and the selection-policy
    /// register remains the only owner of those.
    pub fn record_judgment(
        &mut self,
        scope_key: &str,
        judgment: OutcomeJudgment,
    ) -> Result<OutcomeProposal, OutcomeEventError> {
        judgment.validate()?;
        let sample_kind = self
            .outcomes
            .get(scope_key)
            .map(|outcome| outcome.scope.sample_kind)
            .unwrap_or_default();
        let proposes_policy_change = judgment.evaluation == OutcomeEvaluation::Usable;
        let proposal = OutcomeProposal {
            scope_key: scope_key.to_owned(),
            evaluator_id: judgment.evaluator_id,
            evaluation: judgment.evaluation,
            rationale: judgment.rationale,
            evidence_digest: judgment.evidence_digest,
            promotion_subject: sample_kind.promotion_subject(),
            proposes_policy_change,
            active_policy_revision: self.policy_revision.clone(),
        };
        self.proposals.push(proposal.clone());
        Ok(proposal)
    }

    /// Every proposal recorded so far, in submission order.
    pub fn proposals(&self) -> &[OutcomeProposal] {
        &self.proposals
    }

    /// Bounded, attributable evidence for one scope.
    pub fn evidence(&self, scope_key: &str) -> Option<OutcomeEvidence> {
        let outcome = self.outcomes.get(scope_key)?;
        Some(OutcomeEvidence {
            scope_key: scope_key.to_owned(),
            policy_revision: outcome.scope.policy_revision.clone(),
            evidence_class: outcome.evidence_class,
            terminal_samples: outcome.terminal_samples(),
            applied_events: outcome.applied_events.len(),
            digest: outcome_digest(outcome),
            gap: outcome.evidence_gap(),
        })
    }

    fn retain_bounded(&mut self) {
        while self.outcomes.len() > MAX_RETAINED_OUTCOMES {
            let Some(oldest) = self
                .outcomes
                .iter()
                .min_by_key(|(_, outcome)| (outcome.updated_at_ms, outcome.scope.key()))
                .map(|(key, _)| key.clone())
            else {
                break;
            };
            self.outcomes.remove(&oldest);
        }
    }
}

/// Admit one actual evaluator invocation.
///
/// Reading a suggestion is passive and needs no admission. Spending, or
/// disclosing evidence to an evaluator, is an actual invocation: without an
/// admission that authorizes the disclosure, admits the work and carries a
/// spendable budget, the invocation is refused instead of launched.
pub fn admit_evaluator_invocation(
    register: &OutcomeRegister,
    invocation: &EvaluatorInvocation,
    admission: Option<&EvaluatorAdmission>,
) -> Result<EvaluatorInvocationGrant, EvaluatorRefusal> {
    let evidence = register
        .evidence(&invocation.scope_key)
        .ok_or(EvaluatorRefusal::UnknownScope)?;
    let Some(admission) = admission else {
        return Err(EvaluatorRefusal::NoAdmission);
    };
    if !admission.disclosure_authorized {
        return Err(EvaluatorRefusal::DisclosureNotAuthorized);
    }
    if !admission.work_admitted {
        return Err(EvaluatorRefusal::WorkNotAdmitted);
    }
    if !admission.max_cost.is_finite() || admission.max_cost <= 0.0 {
        return Err(EvaluatorRefusal::BudgetNotAuthorized);
    }
    Ok(EvaluatorInvocationGrant {
        invocation: invocation.clone(),
        evidence,
        admitted_cost: admission.max_cost,
    })
}

/// A stable digest of the bounded facts one judgment is made against.
///
/// The digest commits to the counters, the charges and the identities, so a
/// later reader can tell whether the judgment was made against these facts.
fn outcome_digest(outcome: &ComparableTaskOutcome) -> String {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    let mut mix = |value: &str| {
        for byte in value.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    };
    mix(&outcome.scope.key());
    for (name, value) in [
        ("completed", outcome.completed),
        ("failed", outcome.failed),
        ("cancelled", outcome.cancelled),
        ("rework", outcome.rework),
        ("inFlight", outcome.in_flight),
        ("lateCharges", outcome.late_charges),
        ("accepted", outcome.accepted),
        ("corrections", outcome.corrections),
        ("unknownCostEvents", outcome.unknown_cost_events),
        ("revision", outcome.revision),
    ] {
        mix(name);
        mix(&value.to_string());
    }
    mix(&format!("{:.6}", outcome.known_cost));
    mix(match outcome.evidence_class {
        EvidenceClass::Synthetic => "synthetic",
        EvidenceClass::LiveAuthorized => "liveAuthorized",
    });
    format!("outcome-{hash:016x}")
}

/// Read the retained outcomes from the existing client-state `settings`
/// collection.
///
/// An absent, unreadable or foreign record reads as an empty register with no
/// policy revision, which is the fail-closed direction: no outcome is invented
/// and no policy is applied.
pub fn load(params: &Value) -> OutcomeRegister {
    let Ok(store) = super::persistence::client_state_store(params) else {
        return OutcomeRegister::default();
    };
    let Ok(collection) = store.read_collection_read_only(SETTINGS_COLLECTION) else {
        return OutcomeRegister::default();
    };
    let Some(value) = collection.get(COMPARABLE_OUTCOMES_SETTINGS_KEY) else {
        return OutcomeRegister::default();
    };
    let Ok(register) = serde_json::from_value::<OutcomeRegister>(value.clone()) else {
        return OutcomeRegister::default();
    };
    if register.schema != COMPARABLE_OUTCOMES_SCHEMA {
        return OutcomeRegister::default();
    }
    register
}

/// Persist the register as one bounded `settings` entry.
pub fn persist(params: &Value, register: &OutcomeRegister) -> anyhow::Result<()> {
    let store = super::persistence::client_state_store(params)?;
    let settings = store.read_collection(SETTINGS_COLLECTION)?;
    let mut settings = settings.as_object().cloned().unwrap_or_default();
    settings.insert(
        COMPARABLE_OUTCOMES_SETTINGS_KEY.to_owned(),
        serde_json::to_value(register)?,
    );
    store
        .write_collection(SETTINGS_COLLECTION, Value::Object(settings))
        .map(|_| ())
        .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn scope(project: &str, candidate: &str, policy_revision: &str) -> OutcomeScope {
        OutcomeScope {
            project_id: project.to_owned(),
            task_family: "implement".to_owned(),
            candidate: CandidateProvenance::new("codex", candidate),
            baseline: None,
            configuration_revision: "config-1".to_owned(),
            policy_revision: policy_revision.to_owned(),
            orchestration_revision: Some("orchestration-1".to_owned()),
            context_policy_id: Some("context-1".to_owned()),
            sample_kind: OutcomeSampleKind::Routing,
        }
    }

    fn event(
        event_id: &str,
        scope: OutcomeScope,
        kind: OutcomeEventKind,
        charge: Option<f64>,
    ) -> OutcomeEvent {
        OutcomeEvent {
            event_id: event_id.to_owned(),
            scope,
            kind,
            accepted: matches!(kind, OutcomeEventKind::Completion),
            corrections: 0,
            latency_ms: Some(1_000),
            charge,
            review_effective: Some(true),
            evidence_class: EvidenceClass::LiveAuthorized,
            observed_at_ms: 1_700_000_000_000,
        }
    }

    fn suggestion(id: &str, scope: &OutcomeScope) -> OutcomeSuggestion {
        OutcomeSuggestion {
            suggestion_id: id.to_owned(),
            identity: scope.suggestion_identity(),
            policy_revision: scope.policy_revision.clone(),
            invalidated: false,
        }
    }

    #[test]
    fn repeated_events_update_one_scoped_outcome() {
        let mut register = OutcomeRegister::new("policy-1");
        let scope = scope("project-a", "gpt-5", "policy-1");
        register
            .register_suggestion(suggestion("suggestion-a", &scope));

        let first = register
            .record(event(
                "run-1",
                scope.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();
        assert!(first.applied);
        assert_eq!(first.revision, 1);
        assert_eq!(first.invalidated_suggestions, vec!["suggestion-a"]);

        // The same producer event applied twice is absorbed, not counted.
        let repeated = register
            .record(event(
                "run-1",
                scope.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();
        assert!(!repeated.applied);
        assert_eq!(repeated.revision, 1);
        assert!(repeated.invalidated_suggestions.is_empty());

        let second = register
            .record(event(
                "run-2",
                scope.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();
        assert!(second.applied);

        let outcome = register.outcome(&scope.key()).unwrap();
        assert_eq!(register.retained(), 1);
        assert_eq!(outcome.completed, 2);
        assert_eq!(outcome.accepted, 2);
        assert_eq!(outcome.revision, 2);
        assert!((outcome.known_cost - 1.0).abs() < f64::EPSILON);
        assert_eq!(outcome.unknown_cost_events, 0);
        assert_eq!(outcome.reviews_observed, 2);
        assert_eq!(outcome.reviews_effective, 2);
        assert_eq!(outcome.scope.orchestration_revision.as_deref(), Some("orchestration-1"));
        assert_eq!(outcome.scope.context_policy_id.as_deref(), Some("context-1"));
        assert!(outcome.supports_learning_conclusion());
    }

    #[test]
    fn a_late_charge_updates_the_same_outcome() {
        let mut register = OutcomeRegister::new("policy-1");
        let scope = scope("project-a", "gpt-5", "policy-1");
        register
            .record(event(
                "run-1",
                scope.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();

        register
            .record(event(
                "charge-1",
                scope.clone(),
                OutcomeEventKind::LateCharge,
                Some(0.25),
            ))
            .unwrap();

        let outcome = register.outcome(&scope.key()).unwrap();
        assert_eq!(register.retained(), 1);
        assert_eq!(outcome.late_charges, 1);
        assert_eq!(outcome.completed, 1);
        assert!((outcome.known_cost - 0.75).abs() < f64::EPSILON);
        assert_eq!(outcome.terminal_samples(), 1);
    }

    #[test]
    fn invalidation_touches_only_the_affected_scope() {
        let mut register = OutcomeRegister::new("policy-1");
        let affected = scope("project-a", "gpt-5", "policy-1");
        let unrelated = scope("project-b", "gpt-5", "policy-1");
        register.register_suggestion(suggestion("suggestion-a1", &affected));
        register.register_suggestion(suggestion("suggestion-a2", &affected));
        // The unrelated project's own event invalidates its own suggestion. It
        // is recorded first and its suggestion registered afterwards, so the
        // only event that could touch `suggestion-b1` below is project A's.
        let own_event = register
            .record(event(
                "run-b",
                unrelated.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();
        assert!(own_event.invalidated_suggestions.is_empty());
        register.register_suggestion(suggestion("suggestion-b1", &unrelated));

        let update = register
            .record(event(
                "run-a",
                affected.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();

        assert_eq!(
            update.invalidated_suggestions,
            vec!["suggestion-a1", "suggestion-a2"]
        );
        assert!(
            register
                .suggestion("suggestion-b1")
                .is_some_and(|suggestion| !suggestion.invalidated),
            "another project's suggestion must stay valid"
        );
        // The unrelated project's outcome is unchanged by project A's event.
        let untouched = register.outcome(&unrelated.key()).unwrap();
        assert_eq!(untouched.completed, 1);
        assert_eq!(untouched.revision, 1);
    }

    #[test]
    fn an_unknown_charge_blocks_a_learning_conclusion() {
        let mut register = OutcomeRegister::new("policy-1");
        let scope = scope("project-a", "gpt-5", "policy-1");
        register
            .record(event("run-1", scope.clone(), OutcomeEventKind::Completion, None))
            .unwrap();

        let outcome = register.outcome(&scope.key()).unwrap();
        assert_eq!(outcome.unknown_cost_events, 1);
        assert!(!outcome.cost_is_known());
        assert_eq!(outcome.cost_per_accepted_outcome(), None);
        assert_eq!(outcome.evidence_gap(), Some(OutcomeEvidenceGap::UnknownCost));
        assert!(!outcome.supports_learning_conclusion());
    }

    #[test]
    fn synthetic_validation_is_not_live_qualification() {
        let mut register = OutcomeRegister::new("policy-1");
        let scope = scope("project-a", "gpt-5", "policy-1");
        let mut observed = event(
            "run-1",
            scope.clone(),
            OutcomeEventKind::Completion,
            Some(0.5),
        );
        observed.evidence_class = EvidenceClass::Synthetic;
        register.record(observed).unwrap();

        let outcome = register.outcome(&scope.key()).unwrap();
        assert_eq!(outcome.evidence_class, EvidenceClass::Synthetic);
        assert_eq!(
            outcome.evidence_gap(),
            Some(OutcomeEvidenceGap::SyntheticOnly)
        );
    }

    #[test]
    fn a_scope_without_a_terminal_sample_has_no_conclusion() {
        let mut register = OutcomeRegister::new("policy-1");
        let scope = scope("project-a", "gpt-5", "policy-1");
        register
            .record(event(
                "run-1",
                scope.clone(),
                OutcomeEventKind::InFlight,
                Some(0.5),
            ))
            .unwrap();

        let outcome = register.outcome(&scope.key()).unwrap();
        assert_eq!(outcome.in_flight, 1);
        assert_eq!(
            outcome.evidence_gap(),
            Some(OutcomeEvidenceGap::NoTerminalSample)
        );
    }

    #[test]
    fn judgment_inputs_never_change_the_active_policy() {
        let mut register = OutcomeRegister::new("policy-1");
        let scope = scope("project-a", "gpt-5", "policy-1");
        register
            .record(event(
                "run-1",
                scope.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();
        let evidence = register.evidence(&scope.key()).unwrap();

        let usable = register
            .record_judgment(
                &scope.key(),
                OutcomeJudgment {
                    evaluator_id: "main-agent".to_owned(),
                    evaluation: OutcomeEvaluation::Usable,
                    rationale: "the paired sample is live and its cost is known".to_owned(),
                    evidence_digest: evidence.digest.clone(),
                    submitted_at_ms: 1,
                },
            )
            .unwrap();
        assert!(usable.proposes_policy_change);
        assert_eq!(usable.active_policy_revision, "policy-1");

        for (evaluation, rationale) in [
            (OutcomeEvaluation::Rejected, "the sample is not comparable"),
            (OutcomeEvaluation::Uncertain, "the sample is too small"),
            (OutcomeEvaluation::Missing, ""),
        ] {
            let proposal = register
                .record_judgment(
                    &scope.key(),
                    OutcomeJudgment {
                        evaluator_id: "main-agent".to_owned(),
                        evaluation,
                        rationale: rationale.to_owned(),
                        evidence_digest: evidence.digest.clone(),
                        submitted_at_ms: 2,
                    },
                )
                .unwrap();
            assert!(!proposal.proposes_policy_change);
            assert_eq!(proposal.active_policy_revision, "policy-1");
        }

        assert_eq!(register.proposals().len(), 4);
        // Recording judgments is evidence only: the revision in force is the
        // one the register was opened with.
        assert_eq!(register.policy_revision(), "policy-1");
    }

    #[test]
    fn a_missing_judgment_needs_no_rationale_but_a_verdict_does() {
        let mut register = OutcomeRegister::new("policy-1");
        let scope = scope("project-a", "gpt-5", "policy-1");
        register
            .record(event(
                "run-1",
                scope.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();

        let refused = register.record_judgment(
            &scope.key(),
            OutcomeJudgment {
                evaluator_id: "main-agent".to_owned(),
                evaluation: OutcomeEvaluation::Usable,
                rationale: String::new(),
                evidence_digest: "digest".to_owned(),
                submitted_at_ms: 1,
            },
        );
        assert_eq!(refused, Err(OutcomeEventError::EmptyRationale));

        let anonymous = register.record_judgment(
            &scope.key(),
            OutcomeJudgment {
                evaluator_id: String::new(),
                evaluation: OutcomeEvaluation::Missing,
                rationale: String::new(),
                evidence_digest: "digest".to_owned(),
                submitted_at_ms: 1,
            },
        );
        assert_eq!(
            anonymous,
            Err(OutcomeEventError::EmptyIdentity("evaluatorId"))
        );
    }

    #[test]
    fn a_routing_sample_only_ever_proposes_a_route_change() {
        let mut register = OutcomeRegister::new("policy-1");
        let routing = scope("project-a", "gpt-5", "policy-1");
        let mut context = scope("project-a", "gpt-5", "policy-1");
        context.sample_kind = OutcomeSampleKind::Context;

        for (scope, event_id) in [(&routing, "run-routing"), (&context, "run-context")] {
            register
                .record(event(
                    event_id,
                    scope.clone(),
                    OutcomeEventKind::Completion,
                    Some(0.5),
                ))
                .unwrap();
        }

        let routing_proposal = register
            .record_judgment(
                &routing.key(),
                OutcomeJudgment {
                    evaluator_id: "main-agent".to_owned(),
                    evaluation: OutcomeEvaluation::Usable,
                    rationale: "route order is cheaper".to_owned(),
                    evidence_digest: "digest-routing".to_owned(),
                    submitted_at_ms: 1,
                },
            )
            .unwrap();
        // Different sample kinds are different scopes, never one averaged
        // record: a routing sample and a context sample measured different
        // things.
        assert_ne!(routing.key(), context.key());
        assert_eq!(register.retained(), 2);
        assert_eq!(
            routing_proposal.promotion_subject,
            OutcomePromotionSubject::RoutingOnly
        );

        let context_proposal = register
            .record_judgment(
                &context.key(),
                OutcomeJudgment {
                    evaluator_id: "main-agent".to_owned(),
                    evaluation: OutcomeEvaluation::Usable,
                    rationale: "context handling improved".to_owned(),
                    evidence_digest: "digest-context".to_owned(),
                    submitted_at_ms: 2,
                },
            )
            .unwrap();
        assert_eq!(
            context_proposal.promotion_subject,
            OutcomePromotionSubject::RoutingAndContext
        );
    }

    #[test]
    fn a_pair_materializes_the_existing_comparable_outcome() {
        let mut register = OutcomeRegister::new("policy-1");
        let candidate = scope("project-a", "gpt-5", "policy-1");
        let mut baseline_scope = scope("project-a", "gpt-4o", "policy-1");
        baseline_scope.candidate = CandidateProvenance::new("codex", "gpt-4o");

        for (event_id, scope, charge, latency) in [
            ("candidate-1", &candidate, 0.4, 900_u64),
            ("candidate-2", &candidate, 0.4, 1_100),
            ("baseline-1", &baseline_scope, 1.0, 1_400),
            ("baseline-2", &baseline_scope, 1.0, 1_600),
        ] {
            let mut observed = event(event_id, scope.clone(), OutcomeEventKind::Completion, Some(charge));
            observed.latency_ms = Some(latency);
            register.record(observed).unwrap();
        }

        let candidate_outcome = register.outcome(&candidate.key()).unwrap();
        let baseline_outcome = register.outcome(&baseline_scope.key()).unwrap();
        let paired = candidate_outcome
            .comparable_outcome(baseline_outcome)
            .expect("a paired sample is comparable");

        assert_eq!(paired.paired_cases, 2);
        assert_eq!(paired.candidate_accepted, 2);
        assert_eq!(paired.baseline_accepted, 2);
        assert_eq!(paired.candidate_latency_p95_ms, Some(1_100));
        assert_eq!(paired.baseline_latency_p95_ms, Some(1_600));
        assert!(paired.candidate_cost_per_accepted_outcome.unwrap() < 1.0);
        assert_eq!(paired.evidence_class, EvidenceClass::LiveAuthorized);
        assert_eq!(paired.scope.task_kind, "implement");
        // This producer never qualifies; the existing qualification owner
        // overwrites this after its own policy runs.
        assert!(!paired.policy_pass);
    }

    #[test]
    fn scopes_without_a_shared_identity_are_not_comparable() {
        let mut register = OutcomeRegister::new("policy-1");
        let candidate = scope("project-a", "gpt-5", "policy-1");
        let other_policy = scope("project-a", "gpt-4o", "policy-2");

        for (event_id, scope) in [("candidate", &candidate), ("baseline", &other_policy)] {
            register
                .record(event(
                    event_id,
                    scope.clone(),
                    OutcomeEventKind::Completion,
                    Some(0.5),
                ))
                .unwrap();
        }

        let candidate_outcome = register.outcome(&candidate.key()).unwrap();
        let other = register.outcome(&other_policy.key()).unwrap();
        assert_eq!(register.retained(), 2);
        assert!(candidate_outcome.comparable_outcome(other).is_none());
    }

    #[test]
    fn an_actual_evaluator_invocation_needs_its_own_admission() {
        let mut register = OutcomeRegister::new("policy-1");
        let scope = scope("project-a", "gpt-5", "policy-1");
        register
            .record(event(
                "run-1",
                scope.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();
        let invocation = EvaluatorInvocation {
            scope_key: scope.key(),
            evaluator_id: "judging-agent".to_owned(),
        };

        // A passive reader needs no admission; an actual invocation does.
        assert!(register.evidence(&invocation.scope_key).is_some());
        assert_eq!(
            admit_evaluator_invocation(&register, &invocation, None),
            Err(EvaluatorRefusal::NoAdmission)
        );

        let unauthorized = EvaluatorAdmission {
            authority: "user".to_owned(),
            disclosure_authorized: false,
            work_admitted: true,
            max_cost: 1.0,
        };
        assert_eq!(
            admit_evaluator_invocation(&register, &invocation, Some(&unauthorized)),
            Err(EvaluatorRefusal::DisclosureNotAuthorized)
        );

        let unadmitted_work = EvaluatorAdmission {
            authority: "user".to_owned(),
            disclosure_authorized: true,
            work_admitted: false,
            max_cost: 1.0,
        };
        assert_eq!(
            admit_evaluator_invocation(&register, &invocation, Some(&unadmitted_work)),
            Err(EvaluatorRefusal::WorkNotAdmitted)
        );

        let unfunded = EvaluatorAdmission {
            authority: "user".to_owned(),
            disclosure_authorized: true,
            work_admitted: true,
            max_cost: 0.0,
        };
        assert_eq!(
            admit_evaluator_invocation(&register, &invocation, Some(&unfunded)),
            Err(EvaluatorRefusal::BudgetNotAuthorized)
        );

        let admitted = EvaluatorAdmission {
            authority: "user".to_owned(),
            disclosure_authorized: true,
            work_admitted: true,
            max_cost: 0.25,
        };
        let grant = admit_evaluator_invocation(&register, &invocation, Some(&admitted))
            .expect("an admitted invocation is granted");
        assert_eq!(grant.admitted_cost, 0.25);
        assert_eq!(grant.evidence.terminal_samples, 1);
        assert!(grant.evidence.digest.starts_with("outcome-"));

        let unknown = EvaluatorInvocation {
            scope_key: "project-a|implement|missing".to_owned(),
            evaluator_id: "judging-agent".to_owned(),
        };
        assert_eq!(
            admit_evaluator_invocation(&register, &unknown, Some(&admitted)),
            Err(EvaluatorRefusal::UnknownScope)
        );
    }

    #[test]
    fn persisted_outcomes_round_trip_through_the_settings_collection() {
        let root = std::env::temp_dir().join(format!(
            "licoup-comparable-outcomes-{}",
            uuid::Uuid::new_v4()
        ));
        let params = serde_json::json!({ "stateRoot": root.to_string_lossy() });
        let mut register = OutcomeRegister::new("policy-1");
        let scope = scope("project-a", "gpt-5", "policy-1");
        register
            .record(event(
                "run-1",
                scope.clone(),
                OutcomeEventKind::Completion,
                Some(0.5),
            ))
            .unwrap();
        register
            .record_judgment(
                &scope.key(),
                OutcomeJudgment {
                    evaluator_id: "main-agent".to_owned(),
                    evaluation: OutcomeEvaluation::Usable,
                    rationale: "usable sample".to_owned(),
                    evidence_digest: "digest".to_owned(),
                    submitted_at_ms: 1,
                },
            )
            .unwrap();

        persist(&params, &register).unwrap();
        let restored = load(&params);

        assert_eq!(restored.retained(), 1);
        assert_eq!(restored.policy_revision(), "policy-1");
        assert_eq!(restored.proposals(), register.proposals());
        let restored_outcome = restored.outcome(&scope.key()).unwrap();
        assert_eq!(restored_outcome.completed, 1);
        assert_eq!(restored_outcome.scope, scope);
        // An absent record reads as an empty register instead of inventing one.
        let empty = load(&serde_json::json!({
            "stateRoot": std::env::temp_dir()
                .join(format!("licoup-comparable-outcomes-empty-{}", uuid::Uuid::new_v4()))
                .to_string_lossy()
        }));
        assert_eq!(empty.retained(), 0);
        assert_eq!(empty.policy_revision(), "");

        let _ = PathBuf::from(&root);
        let _ = std::fs::remove_dir_all(root);
    }
}
