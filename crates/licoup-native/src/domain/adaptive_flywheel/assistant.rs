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
    BindingKind, BindingValue, GraphStateKind, WorkflowDefinition, compile_workflow,
    validate_workflow_value,
};

pub const ASSISTANT_TEMPORARY_DEFINITION_PREFIX: &str = "assistant-temporary";

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowDiagnosticCode {
    WorkflowSyntaxInvalid,
    WorkflowShapeInvalid,
    WorkflowRequiredFieldMissing,
    WorkflowFieldTypeInvalid,
    WorkflowFieldValueInvalid,
    WorkflowUnknownField,
    WorkflowSchemaUnsupported,
    WorkflowMetadataIdInvalid,
    WorkflowMetadataNameInvalid,
    WorkflowMetadataVersionInvalid,
    WorkflowStateLimit,
    WorkflowTransitionLimit,
    WorkflowBindingLimit,
    WorkflowRuntimeLimit,
    WorkflowParallelismInvalid,
    WorkflowWorksetLimitInvalid,
    WorkflowRetryLimitInvalid,
    WorkflowBindingIdInvalid,
    WorkflowBindingDuplicate,
    WorkflowBindingLabelInvalid,
    WorkflowFallbackInvalid,
    WorkflowEntrySlotInvalid,
    WorkflowRuntimeIdInvalid,
    WorkflowRuntimeBindingInvalid,
    WorkflowWorksetIdInvalid,
    WorkflowWorksetItemBindingInvalid,
    WorkflowWorksetPredecessorFieldInvalid,
    WorkflowWorksetFieldConflict,
    WorkflowStateIdInvalid,
    WorkflowStateLabelInvalid,
    WorkflowStateInstructionInvalid,
    WorkflowStateDuplicate,
    WorkflowStateRetryInvalid,
    WorkflowActorBindingInvalid,
    WorkflowStateFieldInvalid,
    WorkflowScriptRuntimeInvalid,
    WorkflowScriptEntryMissing,
    WorkflowScriptEntryInvalid,
    WorkflowWorksetReferenceInvalid,
    WorkflowWorksetBindingInvalid,
    WorkflowInitialUnknown,
    WorkflowTransitionIdInvalid,
    WorkflowTransitionDuplicate,
    WorkflowTransitionStateUnknown,
    WorkflowGuardInvalid,
    WorkflowGuardAmbiguous,
    WorkflowRoutingInvalid,
    WorkflowTopologyInvalid,
    WorkflowStateUnreachable,
    WorkflowTerminalUnreachable,
    WorkflowEffectCycle,
    WorkflowInvalid,
    GraphIdentityNotAssistantTemporary,
    GraphRuntimeAssetUnavailable,
    GraphAssistantMembershipRejected,
    GraphAssistantDesignationRejected,
    GraphAssistantSkillUnavailable,
    GraphAuthorityRejected,
    GraphBindingDuplicate,
    GraphBindingUnknown,
    GraphBindingKindRejected,
    GraphBindingIncomplete,
    GraphMembershipRejected,
    GraphModelUnavailable,
    GraphModelRejected,
    GraphReadinessRejected,
    GraphEnvironmentUnavailable,
    GraphProfileRejected,
    ConversationStateUnavailable,
    ConversationNotFound,
    GraphRouteStale,
}

impl WorkflowDiagnosticCode {
    pub const fn wire(self) -> &'static str {
        match self {
            Self::WorkflowSyntaxInvalid => "workflow_syntax_invalid",
            Self::WorkflowShapeInvalid => "workflow_shape_invalid",
            Self::WorkflowRequiredFieldMissing => "workflow_required_field_missing",
            Self::WorkflowFieldTypeInvalid => "workflow_field_type_invalid",
            Self::WorkflowFieldValueInvalid => "workflow_field_value_invalid",
            Self::WorkflowUnknownField => "workflow_unknown_field",
            Self::WorkflowSchemaUnsupported => "workflow_schema_unsupported",
            Self::WorkflowMetadataIdInvalid => "workflow_metadata_id_invalid",
            Self::WorkflowMetadataNameInvalid => "workflow_metadata_name_invalid",
            Self::WorkflowMetadataVersionInvalid => "workflow_metadata_version_invalid",
            Self::WorkflowStateLimit => "workflow_state_limit",
            Self::WorkflowTransitionLimit => "workflow_transition_limit",
            Self::WorkflowBindingLimit => "workflow_binding_limit",
            Self::WorkflowRuntimeLimit => "workflow_runtime_limit",
            Self::WorkflowParallelismInvalid => "workflow_parallelism_invalid",
            Self::WorkflowWorksetLimitInvalid => "workflow_workset_limit_invalid",
            Self::WorkflowRetryLimitInvalid => "workflow_retry_limit_invalid",
            Self::WorkflowBindingIdInvalid => "workflow_binding_id_invalid",
            Self::WorkflowBindingDuplicate => "workflow_binding_duplicate",
            Self::WorkflowBindingLabelInvalid => "workflow_binding_label_invalid",
            Self::WorkflowFallbackInvalid => "workflow_fallback_invalid",
            Self::WorkflowEntrySlotInvalid => "workflow_entry_slot_invalid",
            Self::WorkflowRuntimeIdInvalid => "workflow_runtime_id_invalid",
            Self::WorkflowRuntimeBindingInvalid => "workflow_runtime_binding_invalid",
            Self::WorkflowWorksetIdInvalid => "workflow_workset_id_invalid",
            Self::WorkflowWorksetItemBindingInvalid => "workflow_workset_item_binding_invalid",
            Self::WorkflowWorksetPredecessorFieldInvalid => {
                "workflow_workset_predecessor_field_invalid"
            }
            Self::WorkflowWorksetFieldConflict => "workflow_workset_field_conflict",
            Self::WorkflowStateIdInvalid => "workflow_state_id_invalid",
            Self::WorkflowStateLabelInvalid => "workflow_state_label_invalid",
            Self::WorkflowStateInstructionInvalid => "workflow_state_instruction_invalid",
            Self::WorkflowStateDuplicate => "workflow_state_duplicate",
            Self::WorkflowStateRetryInvalid => "workflow_state_retry_invalid",
            Self::WorkflowActorBindingInvalid => "workflow_actor_binding_invalid",
            Self::WorkflowStateFieldInvalid => "workflow_state_field_invalid",
            Self::WorkflowScriptRuntimeInvalid => "workflow_script_runtime_invalid",
            Self::WorkflowScriptEntryMissing => "workflow_script_entry_missing",
            Self::WorkflowScriptEntryInvalid => "workflow_script_entry_invalid",
            Self::WorkflowWorksetReferenceInvalid => "workflow_workset_reference_invalid",
            Self::WorkflowWorksetBindingInvalid => "workflow_workset_binding_invalid",
            Self::WorkflowInitialUnknown => "workflow_initial_unknown",
            Self::WorkflowTransitionIdInvalid => "workflow_transition_id_invalid",
            Self::WorkflowTransitionDuplicate => "workflow_transition_duplicate",
            Self::WorkflowTransitionStateUnknown => "workflow_transition_state_unknown",
            Self::WorkflowGuardInvalid => "workflow_guard_invalid",
            Self::WorkflowGuardAmbiguous => "workflow_guard_ambiguous",
            Self::WorkflowRoutingInvalid => "workflow_routing_invalid",
            Self::WorkflowTopologyInvalid => "workflow_topology_invalid",
            Self::WorkflowStateUnreachable => "workflow_state_unreachable",
            Self::WorkflowTerminalUnreachable => "workflow_terminal_unreachable",
            Self::WorkflowEffectCycle => "workflow_effect_cycle",
            Self::WorkflowInvalid => "workflow_invalid",
            Self::GraphIdentityNotAssistantTemporary => "graph_identity_not_assistant_temporary",
            Self::GraphRuntimeAssetUnavailable => "graph_runtime_asset_unavailable",
            Self::GraphAssistantMembershipRejected => "graph_assistant_membership_rejected",
            Self::GraphAssistantDesignationRejected => "graph_assistant_designation_rejected",
            Self::GraphAssistantSkillUnavailable => "graph_assistant_skill_unavailable",
            Self::GraphAuthorityRejected => "graph_authority_rejected",
            Self::GraphBindingDuplicate => "graph_binding_duplicate",
            Self::GraphBindingUnknown => "graph_binding_unknown",
            Self::GraphBindingKindRejected => "graph_binding_kind_rejected",
            Self::GraphBindingIncomplete => "graph_binding_incomplete",
            Self::GraphMembershipRejected => "graph_membership_rejected",
            Self::GraphModelUnavailable => "graph_model_unavailable",
            Self::GraphModelRejected => "graph_model_rejected",
            Self::GraphReadinessRejected => "graph_readiness_rejected",
            Self::GraphEnvironmentUnavailable => "graph_environment_unavailable",
            Self::GraphProfileRejected => "graph_profile_rejected",
            Self::ConversationStateUnavailable => "conversation_state_unavailable",
            Self::ConversationNotFound => "conversation_not_found",
            Self::GraphRouteStale => "graph_route_stale",
        }
    }

    pub fn from_wire(value: &str) -> Option<Self> {
        const VALUES: &[WorkflowDiagnosticCode] = &[
            WorkflowDiagnosticCode::WorkflowSyntaxInvalid,
            WorkflowDiagnosticCode::WorkflowShapeInvalid,
            WorkflowDiagnosticCode::WorkflowRequiredFieldMissing,
            WorkflowDiagnosticCode::WorkflowFieldTypeInvalid,
            WorkflowDiagnosticCode::WorkflowFieldValueInvalid,
            WorkflowDiagnosticCode::WorkflowUnknownField,
            WorkflowDiagnosticCode::WorkflowSchemaUnsupported,
            WorkflowDiagnosticCode::WorkflowMetadataIdInvalid,
            WorkflowDiagnosticCode::WorkflowMetadataNameInvalid,
            WorkflowDiagnosticCode::WorkflowMetadataVersionInvalid,
            WorkflowDiagnosticCode::WorkflowStateLimit,
            WorkflowDiagnosticCode::WorkflowTransitionLimit,
            WorkflowDiagnosticCode::WorkflowBindingLimit,
            WorkflowDiagnosticCode::WorkflowRuntimeLimit,
            WorkflowDiagnosticCode::WorkflowParallelismInvalid,
            WorkflowDiagnosticCode::WorkflowWorksetLimitInvalid,
            WorkflowDiagnosticCode::WorkflowRetryLimitInvalid,
            WorkflowDiagnosticCode::WorkflowBindingIdInvalid,
            WorkflowDiagnosticCode::WorkflowBindingDuplicate,
            WorkflowDiagnosticCode::WorkflowBindingLabelInvalid,
            WorkflowDiagnosticCode::WorkflowFallbackInvalid,
            WorkflowDiagnosticCode::WorkflowEntrySlotInvalid,
            WorkflowDiagnosticCode::WorkflowRuntimeIdInvalid,
            WorkflowDiagnosticCode::WorkflowRuntimeBindingInvalid,
            WorkflowDiagnosticCode::WorkflowWorksetIdInvalid,
            WorkflowDiagnosticCode::WorkflowWorksetItemBindingInvalid,
            WorkflowDiagnosticCode::WorkflowWorksetPredecessorFieldInvalid,
            WorkflowDiagnosticCode::WorkflowWorksetFieldConflict,
            WorkflowDiagnosticCode::WorkflowStateIdInvalid,
            WorkflowDiagnosticCode::WorkflowStateLabelInvalid,
            WorkflowDiagnosticCode::WorkflowStateInstructionInvalid,
            WorkflowDiagnosticCode::WorkflowStateDuplicate,
            WorkflowDiagnosticCode::WorkflowStateRetryInvalid,
            WorkflowDiagnosticCode::WorkflowActorBindingInvalid,
            WorkflowDiagnosticCode::WorkflowStateFieldInvalid,
            WorkflowDiagnosticCode::WorkflowScriptRuntimeInvalid,
            WorkflowDiagnosticCode::WorkflowScriptEntryMissing,
            WorkflowDiagnosticCode::WorkflowScriptEntryInvalid,
            WorkflowDiagnosticCode::WorkflowWorksetReferenceInvalid,
            WorkflowDiagnosticCode::WorkflowWorksetBindingInvalid,
            WorkflowDiagnosticCode::WorkflowInitialUnknown,
            WorkflowDiagnosticCode::WorkflowTransitionIdInvalid,
            WorkflowDiagnosticCode::WorkflowTransitionDuplicate,
            WorkflowDiagnosticCode::WorkflowTransitionStateUnknown,
            WorkflowDiagnosticCode::WorkflowGuardInvalid,
            WorkflowDiagnosticCode::WorkflowGuardAmbiguous,
            WorkflowDiagnosticCode::WorkflowRoutingInvalid,
            WorkflowDiagnosticCode::WorkflowTopologyInvalid,
            WorkflowDiagnosticCode::WorkflowStateUnreachable,
            WorkflowDiagnosticCode::WorkflowTerminalUnreachable,
            WorkflowDiagnosticCode::WorkflowEffectCycle,
            WorkflowDiagnosticCode::WorkflowInvalid,
            WorkflowDiagnosticCode::GraphIdentityNotAssistantTemporary,
            WorkflowDiagnosticCode::GraphRuntimeAssetUnavailable,
            WorkflowDiagnosticCode::GraphAssistantMembershipRejected,
            WorkflowDiagnosticCode::GraphAssistantDesignationRejected,
            WorkflowDiagnosticCode::GraphAssistantSkillUnavailable,
            WorkflowDiagnosticCode::GraphAuthorityRejected,
            WorkflowDiagnosticCode::GraphBindingDuplicate,
            WorkflowDiagnosticCode::GraphBindingUnknown,
            WorkflowDiagnosticCode::GraphBindingKindRejected,
            WorkflowDiagnosticCode::GraphBindingIncomplete,
            WorkflowDiagnosticCode::GraphMembershipRejected,
            WorkflowDiagnosticCode::GraphModelUnavailable,
            WorkflowDiagnosticCode::GraphModelRejected,
            WorkflowDiagnosticCode::GraphReadinessRejected,
            WorkflowDiagnosticCode::GraphEnvironmentUnavailable,
            WorkflowDiagnosticCode::GraphProfileRejected,
            WorkflowDiagnosticCode::ConversationStateUnavailable,
            WorkflowDiagnosticCode::ConversationNotFound,
            WorkflowDiagnosticCode::GraphRouteStale,
        ];
        VALUES
            .iter()
            .copied()
            .find(|candidate| candidate.wire() == value)
    }
}

impl PartialEq<&str> for WorkflowDiagnosticCode {
    fn eq(&self, other: &&str) -> bool {
        self.wire() == *other
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
pub enum WorkflowDiagnosticStage {
    #[serde(rename = "workflow/parse")]
    WorkflowParse,
    #[serde(rename = "workflow/compile")]
    WorkflowCompile,
    #[serde(rename = "package/validate")]
    PackageValidate,
    #[serde(rename = "assistant-workflow/preflight")]
    AssistantWorkflowPreflight,
    #[serde(rename = "assistant-workflow/revalidate")]
    AssistantWorkflowRevalidate,
}

impl WorkflowDiagnosticStage {
    pub const fn wire(self) -> &'static str {
        match self {
            Self::WorkflowParse => "workflow/parse",
            Self::WorkflowCompile => "workflow/compile",
            Self::PackageValidate => "package/validate",
            Self::AssistantWorkflowPreflight => "assistant-workflow/preflight",
            Self::AssistantWorkflowRevalidate => "assistant-workflow/revalidate",
        }
    }

    fn from_wire(value: &str) -> Option<Self> {
        match value {
            "workflow/parse" => Some(Self::WorkflowParse),
            "workflow/compile" => Some(Self::WorkflowCompile),
            "package/validate" => Some(Self::PackageValidate),
            "assistant-workflow/preflight" => Some(Self::AssistantWorkflowPreflight),
            "assistant-workflow/revalidate" => Some(Self::AssistantWorkflowRevalidate),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowDiagnosticExpected {
    Object,
    Array,
    String,
    Integer,
    Boolean,
    EnumValue,
    Identifier,
    NonEmptyText,
    UniqueId,
    ExistingReference,
    SupportedSchema,
    ValidRouting,
    ValidTopology,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowDiagnosticActualKind {
    Missing,
    Null,
    Object,
    Array,
    String,
    Number,
    Boolean,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowDiagnosticRecovery {
    AddRequiredField,
    CorrectField,
    RemoveUnknownField,
    RemoveDuplicate,
    CorrectReference,
    ReduceResource,
    CorrectRouting,
    CorrectTopology,
    UpdateAssistantProfile,
    UpdateBinding,
    RefreshConversationState,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PreflightDiagnostic {
    pub code: WorkflowDiagnosticCode,
    pub stage: WorkflowDiagnosticStage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub related_paths: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub membership_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actual: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected: Option<WorkflowDiagnosticExpected>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actual_kind: Option<WorkflowDiagnosticActualKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovery: Option<WorkflowDiagnosticRecovery>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PreflightReceipt {
    pub conversation_id: String,
    pub assistant_membership_id: String,
    pub workflow_digest: String,
    pub membership_ids: Vec<String>,
    pub route_receipt: Value,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PreflightFailure {
    pub code: String,
    pub stage: String,
    pub retryable: bool,
    pub recovery: String,
    pub diagnostics: Vec<PreflightDiagnostic>,
}

impl Display for PreflightFailure {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.code)
    }
}

impl std::error::Error for PreflightFailure {}

impl PreflightFailure {
    pub(crate) fn new(code: &'static str, mut diagnostics: Vec<PreflightDiagnostic>) -> Self {
        diagnostics.sort_by(|left, right| {
            left.stage
                .cmp(&right.stage)
                .then_with(|| left.path.cmp(&right.path))
                .then_with(|| left.code.cmp(&right.code))
                .then_with(|| left.related_paths.cmp(&right.related_paths))
                .then_with(|| left.membership_id.cmp(&right.membership_id))
        });
        diagnostics.dedup();
        Self {
            code: code.to_owned(),
            stage: "assistant-workflow/preflight".to_owned(),
            retryable: true,
            recovery: "correct_graph_or_bindings_and_retry".to_owned(),
            diagnostics,
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
    let validation = validate_workflow_value(workflow);
    let mut checks = validation.diagnostics;

    let by_membership = snapshots
        .iter()
        .map(|snapshot| (snapshot.membership_id.as_str(), snapshot))
        .collect::<BTreeMap<_, _>>();
    let assistant = by_membership.get(assistant_membership_id).copied();
    if assistant.is_none() {
        checks.push(check_at(
            "graph_assistant_membership_rejected",
            Some("/assistantMembershipId"),
            Some(assistant_membership_id),
        ));
    }
    if assistant
        .is_some_and(|assistant| assistant.responsibility != ProfileResponsibility::Assistant)
    {
        checks.push(check_at(
            "graph_assistant_designation_rejected",
            Some("/assistantMembershipId"),
            Some(assistant_membership_id),
        ));
    }
    if assistant.is_some_and(|assistant| {
        !assistant
            .skills
            .iter()
            .any(|skill| skill == ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID)
            || !conversation_driver_available(assistant)
    }) {
        checks.push(check_at(
            "graph_assistant_skill_unavailable",
            Some("/assistantMembershipId"),
            Some(assistant_membership_id),
        ));
    }
    if assistant.is_some_and(|assistant| {
        filters
            .required_authority
            .iter()
            .any(|required| !assistant.authority.contains(required))
    }) {
        checks.push(check_at(
            "graph_authority_rejected",
            Some("/filters/requiredAuthority"),
            Some(assistant_membership_id),
        ));
    }
    if assistant.is_some_and(|assistant| assistant.model.is_none()) {
        checks.push(check_at(
            "graph_model_unavailable",
            Some("/assistantMembershipId"),
            Some(assistant_membership_id),
        ));
    }
    if assistant.is_some_and(|assistant| assistant.readiness.as_deref() != Some("ready")) {
        checks.push(check_at(
            "graph_readiness_rejected",
            Some("/assistantMembershipId"),
            Some(assistant_membership_id),
        ));
    }
    if assistant.is_some_and(|assistant| assistant.environment.is_none()) {
        checks.push(check_at(
            "graph_environment_unavailable",
            Some("/assistantMembershipId"),
            Some(assistant_membership_id),
        ));
    }

    let Some(definition) = validation.definition else {
        return Err(PreflightFailure::new(failure_code(&checks), checks));
    };
    if !definition
        .metadata
        .id
        .starts_with(ASSISTANT_TEMPORARY_DEFINITION_PREFIX)
    {
        checks.push(diagnostic(
            "graph_identity_not_assistant_temporary",
            "assistant-workflow/preflight",
            Some("/metadata/id"),
            None,
            None,
            None,
        ));
    }
    let compiler_blocked = checks.iter().any(|diagnostic| {
        matches!(
            diagnostic.stage,
            WorkflowDiagnosticStage::WorkflowParse | WorkflowDiagnosticStage::WorkflowCompile
        )
    });
    let compiled = if compiler_blocked {
        None
    } else {
        match compile_workflow(definition.clone()) {
            Ok(compiled) => Some(compiled),
            Err(_) => {
                checks.push(diagnostic(
                    "workflow_topology_invalid",
                    "workflow/compile",
                    Some(""),
                    None,
                    None,
                    None,
                ));
                None
            }
        }
    };
    if !definition.runtimes.is_empty()
        || definition
            .states
            .iter()
            .any(|state| state.kind == GraphStateKind::Script)
    {
        checks.push(check_at(
            "graph_runtime_asset_unavailable",
            Some("/runtimes"),
            None,
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
    for (binding_index, binding) in bindings.iter().enumerate() {
        let binding_pointer = format!("/bindings/{binding_index}");
        if !seen_bindings.insert((binding.slot_id.as_str(), binding.ordinal)) {
            checks.push(check_at(
                "graph_binding_duplicate",
                Some(binding_pointer.as_str()),
                None,
            ));
            continue;
        }
        let Some(slot) = actor_slots.get(binding.slot_id.as_str()) else {
            checks.push(check_at(
                "graph_binding_unknown",
                Some(format!("{binding_pointer}/slotId").as_str()),
                None,
            ));
            continue;
        };
        if slot.kind != BindingKind::Actor || binding.ordinal >= 16 {
            checks.push(check_at(
                "graph_binding_kind_rejected",
                Some(binding_pointer.as_str()),
                None,
            ));
            continue;
        }
        if binding.ordinal == 0 {
            bound_slots.insert(binding.slot_id.as_str());
        }
        let Some(member) = by_membership.get(binding.value_id.as_str()).copied() else {
            checks.push(check_at(
                "graph_membership_rejected",
                Some(format!("{binding_pointer}/valueId").as_str()),
                Some(binding.value_id.as_str()),
            ));
            continue;
        };
        bound_membership_ids.insert(member.membership_id.clone());
        if member.membership_id != assistant_membership_id && member.model.is_none() {
            checks.push(check_at(
                "graph_model_unavailable",
                Some(format!("{binding_pointer}/model").as_str()),
                Some(member.membership_id.as_str()),
            ));
        } else if !binding.model.is_empty()
            && member.model.as_deref() != Some(binding.model.as_str())
        {
            checks.push(check_at(
                "graph_model_rejected",
                Some(format!("{binding_pointer}/model").as_str()),
                Some(member.membership_id.as_str()),
            ));
        }
        if member.membership_id != assistant_membership_id
            && member.readiness.as_deref() != Some("ready")
        {
            checks.push(check_at(
                "graph_readiness_rejected",
                Some(format!("{binding_pointer}/valueId").as_str()),
                Some(member.membership_id.as_str()),
            ));
        }
        if member.membership_id != assistant_membership_id && member.environment.is_none() {
            checks.push(check_at(
                "graph_environment_unavailable",
                Some(format!("{binding_pointer}/valueId").as_str()),
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
        let slot_index = definition
            .actor_slots
            .iter()
            .position(|candidate| candidate.id == *slot)
            .unwrap_or_default();
        checks.push(check_at(
            "graph_binding_incomplete",
            Some(format!("/actorSlots/{slot_index}").as_str()),
            None,
        ));
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
        checks.push(check_at(
            "graph_membership_rejected",
            Some("/filters/membershipIds"),
            None,
        ));
    }
    let mut exact_filters = filters.clone();
    exact_filters.membership_ids = bound_membership_ids.iter().cloned().collect();
    let ranked = match rank_candidates(snapshots.to_vec(), &exact_filters) {
        Ok(ranked) => ranked,
        Err(_) => {
            checks.push(check_at("graph_profile_rejected", Some("/filters"), None));
            Vec::new()
        }
    };

    if !checks.is_empty() {
        return Err(PreflightFailure::new(failure_code(&checks), checks));
    }
    let Some(compiled) = compiled else {
        return Err(PreflightFailure::new(
            "graph_invalid",
            vec![diagnostic(
                "workflow_topology_invalid",
                "workflow/compile",
                Some(""),
                None,
                None,
                None,
            )],
        ));
    };
    let definition = compiled.definition;
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
        },
        profile_revisions,
    })
}

fn failure_code(diagnostics: &[PreflightDiagnostic]) -> &'static str {
    if diagnostics.len() == 1
        && diagnostics[0].code == WorkflowDiagnosticCode::GraphIdentityNotAssistantTemporary
    {
        "graph_identity_rejected"
    } else if diagnostics.iter().any(|diagnostic| {
        matches!(
            diagnostic.stage,
            WorkflowDiagnosticStage::AssistantWorkflowPreflight
                | WorkflowDiagnosticStage::AssistantWorkflowRevalidate
        )
    }) {
        "graph_preflight_rejected"
    } else {
        "graph_invalid"
    }
}

fn conversation_driver_available(snapshot: &MembershipProfileSnapshot) -> bool {
    snapshot.capabilities.iter().any(|capability| {
        matches!(
            capability.as_str(),
            "conversationDriver:supported" | "conversationDriver:ready"
        )
    })
}

fn check_at(
    code: &str,
    json_pointer: Option<&str>,
    membership_id: Option<&str>,
) -> PreflightDiagnostic {
    diagnostic(
        code,
        "assistant-workflow/preflight",
        json_pointer,
        membership_id,
        None,
        None,
    )
}

fn diagnostic(
    code: &str,
    stage: &str,
    json_pointer: Option<&str>,
    membership_id: Option<&str>,
    actual: Option<u64>,
    limit: Option<u64>,
) -> PreflightDiagnostic {
    let code =
        WorkflowDiagnosticCode::from_wire(code).unwrap_or(WorkflowDiagnosticCode::WorkflowInvalid);
    let recovery = diagnostic_recovery(code);
    PreflightDiagnostic {
        code,
        stage: WorkflowDiagnosticStage::from_wire(stage)
            .unwrap_or(WorkflowDiagnosticStage::WorkflowCompile),
        path: json_pointer.map(str::to_owned),
        related_paths: Vec::new(),
        membership_id: membership_id
            .filter(|value| valid_diagnostic_identity(value))
            .map(str::to_owned),
        actual,
        limit,
        expected: None,
        actual_kind: None,
        recovery: Some(recovery),
        line: None,
        column: None,
    }
}

fn diagnostic_recovery(code: WorkflowDiagnosticCode) -> WorkflowDiagnosticRecovery {
    use WorkflowDiagnosticCode as Code;
    match code {
        Code::WorkflowRequiredFieldMissing => WorkflowDiagnosticRecovery::AddRequiredField,
        Code::WorkflowUnknownField => WorkflowDiagnosticRecovery::RemoveUnknownField,
        Code::WorkflowBindingDuplicate
        | Code::WorkflowStateDuplicate
        | Code::WorkflowTransitionDuplicate => WorkflowDiagnosticRecovery::RemoveDuplicate,
        Code::WorkflowRuntimeBindingInvalid
        | Code::WorkflowActorBindingInvalid
        | Code::WorkflowScriptRuntimeInvalid
        | Code::WorkflowWorksetReferenceInvalid
        | Code::WorkflowWorksetBindingInvalid
        | Code::WorkflowInitialUnknown
        | Code::WorkflowTransitionStateUnknown => WorkflowDiagnosticRecovery::CorrectReference,
        Code::WorkflowStateLimit
        | Code::WorkflowTransitionLimit
        | Code::WorkflowBindingLimit
        | Code::WorkflowRuntimeLimit
        | Code::WorkflowParallelismInvalid
        | Code::WorkflowWorksetLimitInvalid
        | Code::WorkflowRetryLimitInvalid => WorkflowDiagnosticRecovery::ReduceResource,
        Code::WorkflowGuardAmbiguous | Code::WorkflowRoutingInvalid => {
            WorkflowDiagnosticRecovery::CorrectRouting
        }
        Code::WorkflowTopologyInvalid
        | Code::WorkflowStateUnreachable
        | Code::WorkflowTerminalUnreachable
        | Code::WorkflowEffectCycle => WorkflowDiagnosticRecovery::CorrectTopology,
        Code::GraphAssistantMembershipRejected
        | Code::GraphAssistantDesignationRejected
        | Code::GraphAssistantSkillUnavailable
        | Code::GraphAuthorityRejected
        | Code::GraphModelUnavailable
        | Code::GraphModelRejected
        | Code::GraphReadinessRejected
        | Code::GraphEnvironmentUnavailable
        | Code::GraphProfileRejected => WorkflowDiagnosticRecovery::UpdateAssistantProfile,
        Code::GraphBindingDuplicate
        | Code::GraphBindingUnknown
        | Code::GraphBindingKindRejected
        | Code::GraphBindingIncomplete
        | Code::GraphMembershipRejected => WorkflowDiagnosticRecovery::UpdateBinding,
        Code::ConversationStateUnavailable | Code::ConversationNotFound | Code::GraphRouteStale => {
            WorkflowDiagnosticRecovery::RefreshConversationState
        }
        _ => WorkflowDiagnosticRecovery::CorrectField,
    }
}

fn valid_diagnostic_identity(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, ':' | '.' | '_' | '-')
        })
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::super::{MAX_ACTIVE_EFFECTS, MAX_WORKSET_ITEMS};
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
            preferred_reasoning_effort: None,
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
                .diagnostics
                .iter()
                .any(|check| check.code == "graph_assistant_skill_unavailable")
        );
        assert!(
            failure
                .diagnostics
                .iter()
                .any(|check| check.code == "graph_runtime_asset_unavailable")
        );
    }

    #[test]
    fn resource_and_identity_diagnostics_preserve_safe_repair_locations() {
        let mut invalid = workflow();
        invalid["metadata"]["id"] = json!("imported-workflow");
        invalid["limits"]["maxParallelism"] = json!(0);
        invalid["limits"]["maxWorksetItems"] = json!(MAX_WORKSET_ITEMS + 1);
        let failure = preflight_assistant_graph(
            "conversation:g",
            "membership:assistant",
            &invalid,
            &[],
            &[],
            &CandidateFilters::default(),
        )
        .unwrap_err();
        assert_eq!(failure.code, "graph_preflight_rejected");
        assert!(failure.diagnostics.iter().any(|diagnostic| {
            diagnostic.code == "graph_identity_not_assistant_temporary"
                && diagnostic.path.as_deref() == Some("/metadata/id")
        }));
        assert!(failure.diagnostics.iter().any(|diagnostic| {
            diagnostic.code == "workflow_parallelism_invalid"
                && diagnostic.path.as_deref() == Some("/limits/maxParallelism")
                && diagnostic.actual == Some(0)
                && diagnostic.limit == Some(MAX_ACTIVE_EFFECTS as u64)
        }));
        assert!(failure.diagnostics.iter().any(|diagnostic| {
            diagnostic.code == "workflow_workset_limit_invalid"
                && diagnostic.path.as_deref() == Some("/limits/maxWorksetItems")
                && diagnostic.actual == Some((MAX_WORKSET_ITEMS + 1) as u64)
                && diagnostic.limit == Some(MAX_WORKSET_ITEMS as u64)
        }));
    }

    #[test]
    fn binding_diagnostics_identify_the_exact_request_item() {
        let snapshots = vec![snapshot(
            "membership:assistant",
            ProfileResponsibility::Assistant,
        )];
        let failure = preflight_assistant_graph(
            "conversation:g",
            "membership:assistant",
            &workflow(),
            &[BindingValue {
                slot_id: "actor".to_owned(),
                ordinal: 0,
                value_id: "membership:missing".to_owned(),
                model: String::new(),
                reasoning_effort: String::new(),
                revision: 0,
            }],
            &snapshots,
            &CandidateFilters::default(),
        )
        .unwrap_err();
        assert!(failure.diagnostics.iter().any(|diagnostic| {
            diagnostic.code == "graph_membership_rejected"
                && diagnostic.path.as_deref() == Some("/bindings/0/valueId")
                && diagnostic.membership_id.as_deref() == Some("membership:missing")
        }));
    }
}
