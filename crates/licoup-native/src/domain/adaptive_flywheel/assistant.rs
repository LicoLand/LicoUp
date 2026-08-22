//! Assistant-temporary Graph admission.
//!
//! This Facade coordinates Conversation/Profile facts, Graph compilation and
//! exact Membership binding without owning any of those facts. Every
//! rejection here is pure and precedes durable admission or an effect permit.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::{Display, Formatter};

use crate::domain::client_conversation::{
    ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID, CandidateFilters, MembershipProfileSnapshot,
    ProfileResponsibility, rank_candidates,
};

use super::{
    BindingKind, BindingValue, GraphStateKind, MAX_ACTIVE_EFFECTS, MAX_BINDING_SLOTS,
    MAX_GRAPH_STATES, MAX_GRAPH_TRANSITIONS, MAX_RETRY_ATTEMPTS, MAX_RUNTIME_REQUIREMENTS,
    MAX_WORKSET_ITEMS, WorkflowDefinition, compile_workflow,
};

pub const ASSISTANT_TEMPORARY_DEFINITION_PREFIX: &str = "assistant-temporary";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PreflightCheck {
    pub code: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub membership_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PreflightReceipt {
    pub conversation_id: String,
    pub assistant_membership_id: String,
    pub workflow_digest: String,
    pub membership_ids: Vec<String>,
    pub route_receipt: Value,
    pub checks: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PreflightFailure {
    pub code: String,
    pub stage: String,
    pub retryable: bool,
    pub recovery: String,
    pub checks: Vec<PreflightCheck>,
}

impl Display for PreflightFailure {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.code)
    }
}

impl std::error::Error for PreflightFailure {}

impl PreflightFailure {
    pub(crate) fn new(code: &'static str, checks: Vec<PreflightCheck>) -> Self {
        Self {
            code: code.to_owned(),
            stage: "assistant-workflow/preflight".to_owned(),
            retryable: true,
            recovery: "correct_graph_or_bindings_and_retry".to_owned(),
            checks,
        }
    }
}

#[derive(Clone, Debug)]
pub struct AssistantPreflight {
    pub definition: WorkflowDefinition,
    pub bindings: Vec<BindingValue>,
    pub receipt: PreflightReceipt,
    /// Store-owned revisions revalidated immediately before durable admission.
    /// This is internal admission state, not a second public Profile projection.
    pub profile_revisions: BTreeMap<String, i64>,
}

pub fn preflight_assistant_graph(
    conversation_id: &str,
    assistant_membership_id: &str,
    workflow: &Value,
    bindings: &[BindingValue],
    snapshots: &[MembershipProfileSnapshot],
    filters: &CandidateFilters,
) -> Result<AssistantPreflight, PreflightFailure> {
    let definition: WorkflowDefinition = serde_json::from_value(workflow.clone())
        .map_err(|_| PreflightFailure::new("graph_invalid", Vec::new()))?;
    if !definition
        .metadata
        .id
        .starts_with(ASSISTANT_TEMPORARY_DEFINITION_PREFIX)
    {
        return Err(PreflightFailure::new(
            "graph_identity_rejected",
            vec![check("graph_identity_not_assistant_temporary", None)],
        ));
    }
    let compiled = compile_workflow(definition)
        .map_err(|_| PreflightFailure::new("graph_invalid", Vec::new()))?;
    let definition = compiled.definition;
    let mut checks = resource_checks(&definition);
    if !definition.runtimes.is_empty()
        || definition
            .states
            .iter()
            .any(|state| state.kind == GraphStateKind::Script)
    {
        checks.push(check("graph_runtime_asset_unavailable", None));
    }

    let by_membership = snapshots
        .iter()
        .map(|snapshot| (snapshot.membership_id.as_str(), snapshot))
        .collect::<BTreeMap<_, _>>();
    let Some(assistant) = by_membership.get(assistant_membership_id).copied() else {
        checks.push(check(
            "graph_assistant_membership_rejected",
            Some(assistant_membership_id),
        ));
        return Err(PreflightFailure::new("graph_preflight_rejected", checks));
    };
    if assistant.responsibility != ProfileResponsibility::Assistant {
        checks.push(check(
            "graph_assistant_designation_rejected",
            Some(assistant_membership_id),
        ));
    }
    if !assistant
        .skills
        .iter()
        .any(|skill| skill == ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID)
        || !conversation_driver_available(assistant)
    {
        checks.push(check(
            "graph_assistant_skill_unavailable",
            Some(assistant_membership_id),
        ));
    }
    if filters
        .required_authority
        .iter()
        .any(|required| !assistant.authority.contains(required))
    {
        checks.push(check(
            "graph_authority_rejected",
            Some(assistant_membership_id),
        ));
    }

    let actor_slots = definition
        .actor_slots
        .iter()
        .map(|slot| (slot.id.as_str(), slot))
        .collect::<BTreeMap<_, _>>();
    let required_slots = definition
        .actor_slots
        .iter()
        .filter(|slot| slot.required && slot.kind == BindingKind::Actor)
        .map(|slot| slot.id.as_str())
        .collect::<BTreeSet<_>>();
    let mut seen_bindings = BTreeSet::new();
    let mut bound_slots = BTreeSet::new();
    let mut bound_membership_ids = BTreeSet::new();
    let mut canonical_bindings = Vec::new();
    for binding in bindings {
        if !seen_bindings.insert((binding.slot_id.as_str(), binding.ordinal)) {
            checks.push(check("graph_binding_duplicate", None));
            continue;
        }
        let Some(slot) = actor_slots.get(binding.slot_id.as_str()) else {
            checks.push(check("graph_binding_unknown", None));
            continue;
        };
        if slot.kind != BindingKind::Actor || binding.ordinal >= 16 {
            checks.push(check("graph_binding_kind_rejected", None));
            continue;
        }
        if binding.ordinal == 0 {
            bound_slots.insert(binding.slot_id.as_str());
        }
        let Some(member) = by_membership.get(binding.value_id.as_str()).copied() else {
            checks.push(check(
                "graph_membership_rejected",
                Some(binding.value_id.as_str()),
            ));
            continue;
        };
        bound_membership_ids.insert(member.membership_id.clone());
        if member.model.is_none() {
            checks.push(check(
                "graph_model_unavailable",
                Some(member.membership_id.as_str()),
            ));
        } else if !binding.model.is_empty()
            && member.model.as_deref() != Some(binding.model.as_str())
        {
            checks.push(check(
                "graph_model_rejected",
                Some(member.membership_id.as_str()),
            ));
        }
        if member.readiness.as_deref() != Some("ready") {
            checks.push(check(
                "graph_readiness_rejected",
                Some(member.membership_id.as_str()),
            ));
        }
        if member.environment.is_none() {
            checks.push(check(
                "graph_environment_unavailable",
                Some(member.membership_id.as_str()),
            ));
        }
        canonical_bindings.push(BindingValue {
            slot_id: binding.slot_id.clone(),
            ordinal: binding.ordinal,
            value_id: member.membership_id.clone(),
            model: member.model.clone().unwrap_or_default(),
            reasoning_effort: binding.reasoning_effort.clone(),
            revision: 0,
        });
    }
    for slot in required_slots.difference(&bound_slots) {
        checks.push(check("graph_binding_incomplete", Some(slot)));
    }

    let requested_memberships = filters
        .membership_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    if !requested_memberships.is_empty()
        && bound_membership_ids
            .iter()
            .any(|membership_id| !requested_memberships.contains(membership_id.as_str()))
    {
        checks.push(check("graph_membership_rejected", None));
    }
    let mut exact_filters = filters.clone();
    exact_filters.membership_ids = bound_membership_ids.iter().cloned().collect();
    let ranked = match rank_candidates(snapshots.to_vec(), &exact_filters) {
        Ok(ranked) => ranked,
        Err(_) => {
            checks.push(check("graph_profile_rejected", None));
            Vec::new()
        }
    };

    if !checks.is_empty() {
        return Err(PreflightFailure::new("graph_preflight_rejected", checks));
    }
    canonical_bindings.sort_by(|left, right| {
        left.slot_id
            .cmp(&right.slot_id)
            .then_with(|| left.ordinal.cmp(&right.ordinal))
            .then_with(|| left.value_id.cmp(&right.value_id))
    });
    let route_receipt = crate::domain::client_conversation::route_receipt(conversation_id, &ranked);
    let digest_payload = json!({
        "workflow": definition,
        "bindings": canonical_bindings,
        "routeReceipt": route_receipt,
    });
    let workflow_digest = sha256_hex(&serde_json::to_vec(&digest_payload).unwrap_or_default());
    let membership_ids = bound_membership_ids.into_iter().collect::<Vec<_>>();
    let profile_revisions = snapshots
        .iter()
        .filter(|snapshot| {
            snapshot.membership_id == assistant_membership_id
                || membership_ids.contains(&snapshot.membership_id)
        })
        .map(|snapshot| (snapshot.membership_id.clone(), snapshot.intent_revision))
        .collect();
    Ok(AssistantPreflight {
        definition,
        bindings: canonical_bindings,
        receipt: PreflightReceipt {
            conversation_id: conversation_id.to_owned(),
            assistant_membership_id: assistant_membership_id.to_owned(),
            workflow_digest,
            membership_ids,
            route_receipt,
            checks: vec![
                "graph_structure".to_owned(),
                "graph_limits".to_owned(),
                "graph_assistant".to_owned(),
                "graph_membership".to_owned(),
                "graph_profile".to_owned(),
                "graph_authority".to_owned(),
            ],
        },
        profile_revisions,
    })
}

fn resource_checks(definition: &WorkflowDefinition) -> Vec<PreflightCheck> {
    let mut checks = Vec::new();
    for (code, actual, maximum) in [
        ("graph_states", definition.states.len(), MAX_GRAPH_STATES),
        (
            "graph_transitions",
            definition.transitions.len(),
            MAX_GRAPH_TRANSITIONS,
        ),
        (
            "graph_binding_slots",
            definition.actor_slots.len(),
            MAX_BINDING_SLOTS,
        ),
        (
            "graph_runtime_requirements",
            definition.runtimes.len(),
            MAX_RUNTIME_REQUIREMENTS,
        ),
        (
            "graph_workset_limit",
            definition.limits.max_workset_items as usize,
            MAX_WORKSET_ITEMS,
        ),
    ] {
        if actual > maximum {
            checks.push(check(code, None));
        }
    }
    let parallelism = definition.limits.max_parallelism as usize;
    if parallelism == 0 || parallelism > MAX_ACTIVE_EFFECTS {
        checks.push(check("graph_parallelism_limit", None));
    }
    if definition.limits.max_attempts as usize > MAX_RETRY_ATTEMPTS as usize {
        checks.push(check("graph_attempts_limit", None));
    }
    checks
}

fn conversation_driver_available(snapshot: &MembershipProfileSnapshot) -> bool {
    snapshot.capabilities.iter().any(|capability| {
        matches!(
            capability.as_str(),
            "conversationDriver:supported" | "conversationDriver:ready"
        )
    })
}

fn check(code: &str, membership_id: Option<&str>) -> PreflightCheck {
    PreflightCheck {
        code: code.to_owned(),
        membership_id: membership_id.map(str::to_owned),
    }
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workflow() -> Value {
        json!({
            "schema": "licoup.adaptive-flywheel.workflow.v1",
            "metadata": {"id": "assistant-temporary", "name": "Temporary", "version": "1"},
            "limits": {"maxParallelism": 2, "maxWorksetItems": 16, "maxAttempts": 2},
            "actorSlots": [{"id": "actor", "kind": "actor", "label": "Actor", "required": true, "entry": true}],
            "runtimes": [],
            "worksets": [],
            "initial": "run",
            "states": [
                {"id": "run", "kind": "actor", "label": "Run", "binding": "actor"},
                {"id": "done", "kind": "succeed", "label": "Done"},
                {"id": "failed", "kind": "fail", "label": "Failed"}
            ],
            "transitions": [
                {"id": "done", "from": "run", "to": "done", "event": "success"},
                {"id": "failed", "from": "run", "to": "failed", "event": "failure"}
            ],
        })
    }

    fn snapshot(id: &str, responsibility: ProfileResponsibility) -> MembershipProfileSnapshot {
        MembershipProfileSnapshot {
            conversation_id: "conversation:g".to_owned(),
            membership_id: id.to_owned(),
            agent_id: "agent:a".to_owned(),
            intent_revision: 1,
            responsibility,
            required_capabilities: vec!["conversationDriver:supported".to_owned()],
            preferred_capabilities: Vec::new(),
            skill_references: if responsibility == ProfileResponsibility::Assistant {
                vec![ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID.to_owned()]
            } else {
                Vec::new()
            },
            preferred_model: None,
            preferred_environment: None,
            model: Some("model-a".to_owned()),
            capabilities: vec!["conversationDriver:supported".to_owned()],
            skills: if responsibility == ProfileResponsibility::Assistant {
                vec![ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID.to_owned()]
            } else {
                Vec::new()
            },
            environment: Some("local".to_owned()),
            readiness: Some("ready".to_owned()),
            price_input_usd_per_million_tokens: Some(1.0),
            price_output_usd_per_million_tokens: Some(2.0),
            intelligence_score: Some(8),
            reliability_class: Some("verified".to_owned()),
            latency_class: Some(1),
            authority: vec![
                "conversation.act".to_owned(),
                "conversation.read".to_owned(),
            ],
        }
    }

    #[test]
    fn exact_memberships_and_owner_derived_model_are_frozen() {
        let snapshots = vec![
            snapshot("membership:assistant", ProfileResponsibility::Assistant),
            snapshot("membership:actor", ProfileResponsibility::Member),
        ];
        let admitted = preflight_assistant_graph(
            "conversation:g",
            "membership:assistant",
            &workflow(),
            &[BindingValue {
                slot_id: "actor".to_owned(),
                ordinal: 0,
                value_id: "membership:actor".to_owned(),
                model: String::new(),
                reasoning_effort: String::new(),
                revision: 0,
            }],
            &snapshots,
            &CandidateFilters::default(),
        )
        .unwrap();
        assert_eq!(admitted.bindings[0].value_id, "membership:actor");
        assert_eq!(admitted.bindings[0].model, "model-a");
        assert_eq!(admitted.receipt.membership_ids, vec!["membership:actor"]);
    }

    #[test]
    fn missing_skill_and_runtime_assets_fail_before_admission() {
        let mut assistant = snapshot("membership:assistant", ProfileResponsibility::Assistant);
        assistant.skills.clear();
        let mut script = workflow();
        script["actorSlots"].as_array_mut().unwrap().push(json!({
            "id": "node",
            "kind": "runtime",
            "label": "Node",
            "required": true
        }));
        script["runtimes"] = json!([{"id": "node", "kind": "node"}]);
        let failure = preflight_assistant_graph(
            "conversation:g",
            "membership:assistant",
            &script,
            &[],
            &[assistant],
            &CandidateFilters::default(),
        )
        .unwrap_err();
        assert!(
            failure
                .checks
                .iter()
                .any(|check| check.code == "graph_assistant_skill_unavailable")
        );
        assert!(
            failure
                .checks
                .iter()
                .any(|check| check.code == "graph_runtime_asset_unavailable")
        );
    }
}
