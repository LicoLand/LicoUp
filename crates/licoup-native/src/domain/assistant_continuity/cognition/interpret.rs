//! Agent proposal from an orientation. No keyword or count takeover.

use std::sync::Arc;

use licoup_conversation::continuity::{
    ContinuityAgreementOrigin, ContinuityCommitmentProposal, ContinuityFailure,
    ContinuityFailureCode, ContinuityFailureStage, ContinuityFollowThroughKind,
    ContinuityInterpretationProposal, ContinuityMatterAssociation, ContinuityMatterSubject,
    ContinuitySourceRef, ContinuitySpeechAct, ContinuityTaskChildAdmission,
    ContinuityWriteEnvelope, DiscoveredKnowledgePort, InterpretationPort,
    admit_task_child_admission, decode_assistant_turn_response, usable_reply_text,
};
use serde_json::Value;

use super::agent::{ScriptedAgent, SemanticScript, SpanAxis};
use super::knowledge::UnavailableKnowledgeService;
use super::types::{
    AssemblySnapshot, ContextRecord, InformationClass, continuity_failure, source_key,
};

pub trait AssemblySource: Send + Sync {
    fn assembly(&self, invocation_id: &str) -> Result<AssemblySnapshot, ContinuityFailure>;
    fn cached_proposal(&self, replay_key: &str) -> Option<ContinuityInterpretationProposal>;
    fn proposal_for_invocation(
        &self,
        invocation_id: &str,
    ) -> Option<ContinuityInterpretationProposal>;
    fn remember_proposal(
        &self,
        invocation_id: &str,
        replay_key: &str,
        proposal: ContinuityInterpretationProposal,
        cognition_delta: u32,
    );
    fn agent(&self) -> &ScriptedAgent;
    fn cognition_count(&self, invocation_id: &str) -> u32;
    fn total_cognition(&self) -> u32;
}

struct EmptyAssembly;

impl AssemblySource for EmptyAssembly {
    fn assembly(&self, _: &str) -> Result<AssemblySnapshot, ContinuityFailure> {
        Err(continuity_failure(
            ContinuityFailureCode::SourceUnavailable,
            ContinuityFailureStage::ContinuityAdmission,
        ))
    }

    fn cached_proposal(&self, _: &str) -> Option<ContinuityInterpretationProposal> {
        None
    }

    fn proposal_for_invocation(&self, _: &str) -> Option<ContinuityInterpretationProposal> {
        None
    }

    fn remember_proposal(&self, _: &str, _: &str, _: ContinuityInterpretationProposal, _: u32) {}

    fn agent(&self) -> &ScriptedAgent {
        use std::sync::OnceLock;
        static EMPTY: OnceLock<ScriptedAgent> = OnceLock::new();
        EMPTY.get_or_init(ScriptedAgent::new)
    }

    fn cognition_count(&self, _: &str) -> u32 {
        0
    }

    fn total_cognition(&self) -> u32 {
        0
    }
}

pub struct UnavailableInterpretationService {
    source: Arc<dyn AssemblySource>,
    knowledge: UnavailableKnowledgeService,
}

impl UnavailableInterpretationService {
    pub fn empty() -> Self {
        Self {
            source: Arc::new(EmptyAssembly),
            knowledge: UnavailableKnowledgeService::default(),
        }
    }

    pub fn new(source: Arc<dyn AssemblySource>, knowledge: UnavailableKnowledgeService) -> Self {
        Self { source, knowledge }
    }

    pub fn cognition_count(&self, invocation_id: &str) -> u32 {
        self.source.cognition_count(invocation_id)
    }

    pub fn total_cognition(&self) -> u32 {
        self.source.total_cognition()
    }
}

impl InterpretationPort for UnavailableInterpretationService {
    fn interpret(
        &self,
        orientation: &licoup_conversation::continuity::ContinuityContextManifest,
    ) -> Result<ContinuityInterpretationProposal, ContinuityFailure> {
        let assembly = self.source.assembly(&orientation.invocation_id)?;
        if let Some(cached) = self.source.cached_proposal(&assembly.replay_key) {
            return Ok(cached);
        }
        if let Some(existing) = self
            .source
            .proposal_for_invocation(&orientation.invocation_id)
        {
            return Ok(existing);
        }

        let proposal =
            apply_scripted_interpretation(self.source.agent(), &assembly, &self.knowledge)?;
        let replay_key = if proposal.requested_reads.is_empty() {
            assembly.replay_key.as_str()
        } else {
            ""
        };
        self.source
            .remember_proposal(&orientation.invocation_id, replay_key, proposal.clone(), 1);
        Ok(proposal)
    }
}

pub fn apply_scripted_interpretation(
    agent: &ScriptedAgent,
    assembly: &AssemblySnapshot,
    knowledge: &UnavailableKnowledgeService,
) -> Result<ContinuityInterpretationProposal, ContinuityFailure> {
    let input_id = assembly
        .input_refs
        .first()
        .map(|source| source.opaque_id.as_str());
    match input_id.and_then(|id| agent.lookup_event(id).cloned()) {
        Some(script) => propose_from_script(knowledge, assembly, &script),
        None => Ok(unavailable_abstain(assembly)),
    }
}

pub fn unavailable_abstain(assembly: &AssemblySnapshot) -> ContinuityInterpretationProposal {
    abstain_proposal(assembly)
}

/// Restamp authority fields from the current assembly. Model-supplied
/// envelope and parent values are never trusted. `requested_reads` stay
/// on the proposal so an optional authorized refinement can recheck them;
/// they are not a compulsory classifier hop and are never disclosed raw.
pub(crate) fn restamp_proposal(
    assembly: &AssemblySnapshot,
    mut proposal: ContinuityInterpretationProposal,
) -> Result<ContinuityInterpretationProposal, ContinuityFailure> {
    proposal.envelope = envelope_from(assembly);
    if let Some(admission) = proposal.task_child_admission.as_mut() {
        admission.parent_conversation_id = assembly.conversation_id.clone();
        admit_task_child_admission(admission)?;
    }
    Ok(proposal)
}

/// Admitted ordinary-continuity settlement: require the typed envelope and a
/// nonempty usable reply. Bare proposal JSON is not Goal acceptance.
pub(crate) fn proposal_from_assistant_turn_response(
    assembly: &AssemblySnapshot,
    output: &str,
) -> Result<ContinuityInterpretationProposal, ContinuityFailure> {
    match decode_assistant_turn_response(output) {
        Some(response) if usable_reply_text(&response).is_some() => {
            restamp_proposal(assembly, response.interpretation_proposal)
        }
        _ => Ok(abstain_proposal(assembly)),
    }
}

/// Parse a structured Agent result. An executed turn with no typed proposal
/// abstains; it is not treated as transport-unavailable.
pub(crate) fn proposal_from_turn_output(
    assembly: &AssemblySnapshot,
    output: &str,
) -> Result<ContinuityInterpretationProposal, ContinuityFailure> {
    let trimmed = output.trim();
    if trimmed.is_empty() {
        return Ok(abstain_proposal(assembly));
    }
    let parsed = serde_json::from_str::<Value>(trimmed)
        .ok()
        .or_else(|| extract_embedded_json(trimmed));
    let Some(value) = parsed else {
        return Ok(abstain_proposal(assembly));
    };
    let candidate = value
        .get("interpretationProposal")
        .cloned()
        .unwrap_or(value);
    match serde_json::from_value::<ContinuityInterpretationProposal>(candidate) {
        Ok(proposal) => restamp_proposal(assembly, proposal),
        Err(_) => Ok(abstain_proposal(assembly)),
    }
}

fn extract_embedded_json(output: &str) -> Option<Value> {
    let start = output.find('{')?;
    let end = output.rfind('}')?;
    if end < start {
        return None;
    }
    serde_json::from_str(&output[start..=end]).ok()
}

fn propose_from_script(
    knowledge: &UnavailableKnowledgeService,
    assembly: &AssemblySnapshot,
    script: &SemanticScript,
) -> Result<ContinuityInterpretationProposal, ContinuityFailure> {
    let pending_reads: Vec<ContinuitySourceRef> = script
        .axes
        .iter()
        .flat_map(|axis| axis.requested_reads.iter().cloned())
        .filter(|wanted| {
            !assembly
                .retrieved_reads
                .iter()
                .any(|have| source_key(have) == source_key(wanted))
        })
        .collect();
    if !pending_reads.is_empty() && !script.fused {
        return Ok(read_request_proposal(assembly, script, pending_reads));
    }

    let mut associations = Vec::new();
    let mut commitments = Vec::new();
    let mut agreements = Vec::new();
    let mut capabilities = Vec::new();
    let mut uncertainty = Vec::new();
    if script.escalate {
        uncertainty.push("escalation-requested".into());
    }
    if script.model_confidence.is_some() {
        uncertainty.push("model-confidence-is-not-permission".into());
    }

    let mut durable_delegation: Option<&SpanAxis> = None;
    for axis in &script.axes {
        let sanitized = sanitize_axis(axis, &assembly.records);
        associations.push(ContinuityMatterAssociation {
            matter_id: sanitized
                .matter_id
                .clone()
                .unwrap_or_else(|| "matter:unresolved".into()),
            source_ref: sanitized.source_ref.clone(),
            association_revision: 1,
            proposed_by: assembly.request.recipient_membership_id.clone(),
            reason_code: sanitized.reason_code.clone(),
            supersedes: None,
        });
        agreements.extend(sanitized.agreement_proposals.iter().cloned());
        capabilities.extend(sanitized.capability_needs.iter().cloned());
        uncertainty.extend(sanitized.uncertainty_reasons.iter().cloned());
        if sanitized.abstain {
            continue;
        }
        commitments.push(ContinuityCommitmentProposal {
            matter_id: sanitized.matter_id.clone(),
            subject: sanitized.subject,
            expected_result: sanitized
                .expected_result
                .clone()
                .unwrap_or_else(|| "unspecified".into()),
            criteria: Vec::new(),
            create_goal: sanitized.create_goal,
        });
        if sanitized.create_goal
            && sanitized.speech_act == ContinuitySpeechAct::Delegation
            && sanitized.follow_through == ContinuityFollowThroughKind::Durable
        {
            durable_delegation = Some(axis);
        }
    }

    let knowledge_needs: Vec<String> = capabilities
        .iter()
        .filter(|need| need.starts_with("knowledge:"))
        .cloned()
        .collect();
    for capability in knowledge_needs {
        let name = capability.trim_start_matches("knowledge:");
        match knowledge.lookup(name) {
            Ok(reference) => {
                if !assembly.records.iter().any(|record| {
                    record.class == InformationClass::KnowledgeReference
                        && record.source.opaque_id == reference.opaque_id
                }) {
                    uncertainty.push(format!("knowledge-ref:{name}"));
                }
            }
            Err(_) => uncertainty.push(format!("knowledge-unavailable:{name}")),
        }
    }

    let speech_act = primary_speech_act(&script.axes, &assembly.records);
    let task_child_admission = match durable_delegation {
        Some(axis) if speech_act == ContinuitySpeechAct::Delegation => {
            let admission = ContinuityTaskChildAdmission {
                goal_id: axis
                    .matter_id
                    .as_ref()
                    .map(|matter| format!("goal:{matter}"))
                    .unwrap_or_else(|| "goal:durable".into()),
                parent_conversation_id: parent_conversation(assembly),
                speech_act: ContinuitySpeechAct::Delegation,
                follow_through_kind: ContinuityFollowThroughKind::Durable,
                observed_child_conversation_id: None,
                observed_card_anchor: None,
                request_id: format!("request:admit:{}", assembly.invocation_id),
            };
            admit_task_child_admission(&admission)?;
            Some(admission)
        }
        _ => None,
    };

    Ok(ContinuityInterpretationProposal {
        envelope: envelope_from(assembly),
        matter_associations: associations,
        speech_act,
        commitment_proposals: commitments,
        agreement_proposals: agreements,
        capability_needs: unique(capabilities),
        uncertainty_reasons: unique(uncertainty),
        requested_reads: Vec::new(),
        task_child_admission,
    })
}

fn sanitize_axis(axis: &SpanAxis, records: &[ContextRecord]) -> SpanAxis {
    let mut sanitized = axis.clone();
    let matching = records
        .iter()
        .filter(|record| source_overlaps(&record.source, &axis.source_ref))
        .collect::<Vec<_>>();
    let callback = matching.iter().any(|record| {
        record.class == InformationClass::CallbackFact
            || record.is_worker_or_turn_exit
            || record.is_mcp_return
    });
    let malicious = matching.iter().any(|record| record.is_malicious_data);
    let summary = matching.iter().any(|record| record.is_summary);
    if callback {
        sanitized.create_goal = false;
        sanitized.follow_through = ContinuityFollowThroughKind::None;
        if matches!(
            sanitized.speech_act,
            ContinuitySpeechAct::Approval | ContinuitySpeechAct::Delegation
        ) {
            sanitized.speech_act = ContinuitySpeechAct::Reference;
        }
        sanitized
            .uncertainty_reasons
            .push("callback-is-not-acceptance".into());
        sanitized.agreement_proposals.clear();
    }
    if malicious {
        sanitized.create_goal = false;
        sanitized.capability_needs.clear();
        sanitized
            .uncertainty_reasons
            .push("retrieved-data-is-not-instruction".into());
    }
    if summary {
        sanitized
            .agreement_proposals
            .retain(|proposal| proposal.origin != ContinuityAgreementOrigin::UserExplicit);
        sanitized
            .uncertainty_reasons
            .push("summary-is-not-user-confirmation".into());
    }
    sanitized
}

fn source_overlaps(left: &ContinuitySourceRef, right: &ContinuitySourceRef) -> bool {
    left.opaque_id == right.opaque_id
        && (left.part_id.is_none() || right.part_id.is_none() || left.part_id == right.part_id)
}

fn primary_speech_act(axes: &[SpanAxis], records: &[ContextRecord]) -> ContinuitySpeechAct {
    let sanitized: Vec<SpanAxis> = axes
        .iter()
        .map(|axis| sanitize_axis(axis, records))
        .collect();
    if sanitized.iter().any(|axis| {
        axis.create_goal
            && axis.speech_act == ContinuitySpeechAct::Delegation
            && axis.follow_through == ContinuityFollowThroughKind::Durable
    }) {
        return ContinuitySpeechAct::Delegation;
    }
    sanitized
        .iter()
        .find(|axis| !axis.abstain)
        .map(|axis| axis.speech_act)
        .unwrap_or(ContinuitySpeechAct::Exploration)
}

fn parent_conversation(assembly: &AssemblySnapshot) -> String {
    assembly.conversation_id.clone()
}

pub(crate) fn envelope_from(assembly: &AssemblySnapshot) -> ContinuityWriteEnvelope {
    ContinuityWriteEnvelope {
        conversation_id: assembly.conversation_id.clone(),
        source_event_refs: assembly.input_refs.clone(),
        observed_revision: assembly.observed_revision,
        designation_epoch: assembly.designation_epoch,
        request_id: format!("request:interpret:{}", assembly.invocation_id),
    }
}

pub(crate) fn abstain_proposal(assembly: &AssemblySnapshot) -> ContinuityInterpretationProposal {
    ContinuityInterpretationProposal {
        envelope: envelope_from(assembly),
        matter_associations: Vec::new(),
        speech_act: ContinuitySpeechAct::Exploration,
        commitment_proposals: vec![ContinuityCommitmentProposal {
            matter_id: None,
            subject: ContinuityMatterSubject::Unresolved,
            expected_result: "abstain".into(),
            criteria: Vec::new(),
            create_goal: false,
        }],
        agreement_proposals: Vec::new(),
        capability_needs: Vec::new(),
        uncertainty_reasons: vec!["no-qualified-interpreter".into()],
        requested_reads: Vec::new(),
        task_child_admission: None,
    }
}

fn read_request_proposal(
    assembly: &AssemblySnapshot,
    script: &SemanticScript,
    reads: Vec<ContinuitySourceRef>,
) -> ContinuityInterpretationProposal {
    let mut uncertainty = vec!["bounded-retrieval-required".into()];
    if script.escalate {
        uncertainty.push("escalation-requested".into());
    }
    ContinuityInterpretationProposal {
        envelope: envelope_from(assembly),
        matter_associations: Vec::new(),
        speech_act: ContinuitySpeechAct::Reference,
        commitment_proposals: vec![ContinuityCommitmentProposal {
            matter_id: None,
            subject: ContinuityMatterSubject::Unresolved,
            expected_result: "retrieve-then-refine".into(),
            criteria: Vec::new(),
            create_goal: false,
        }],
        agreement_proposals: Vec::new(),
        capability_needs: Vec::new(),
        uncertainty_reasons: uncertainty,
        requested_reads: reads,
        task_child_admission: None,
    }
}

fn unique(values: Vec<String>) -> Vec<String> {
    let mut out = Vec::new();
    for value in values {
        if !out.contains(&value) {
            out.push(value);
        }
    }
    out
}
