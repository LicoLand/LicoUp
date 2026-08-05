import 'package:licoup/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/platform/agents/group_conversation_store.dart';

/// Client-local group Conversation roster and turn-taking state.
mixin GroupConversationController on AgentOrchestrationPolicyController {
  static final GroupConversationStore _store = GroupConversationStore();

  Future<void> ensureGroupConversationReady() async {
    if (!selectedConversationIsOrchestration) return;
    final record = await _syncGroupConversationRecord();
    groupConversationRoster = record.roster;
  }

  Future<GroupConversationRecord> _syncGroupConversationRecord() async {
    final portableData = agentWorkspacePortableData;
    final policy = effectiveAgentOrchestrationPolicy;
    final mainAgentId = policy.commanderAgentId.trim();
    return _store.syncRosterFromFlywheel(
      portableData: portableData,
      mainAgentId: mainAgentId,
      agents: _flywheelSelectedAgents(policy),
    );
  }

  List<({String id, String label})> _flywheelSelectedAgents(
    AgentOrchestrationPolicy policy,
  ) {
    final selected = <String, String>{};
    void put(String agentId) {
      final id = agentId.trim();
      if (id.isEmpty) return;
      final target = groupConversationTargetFor(id);
      selected.putIfAbsent(
        id,
        () =>
            target?.label.trim().isNotEmpty == true ? target!.label.trim() : id,
      );
    }

    put(policy.commanderAgentId);
    for (final role in CodeEngineeringRoleSlot.values) {
      put(policy.assignmentFor(role).agentId);
    }
    return [
      for (final entry in selected.entries) (id: entry.key, label: entry.value),
    ];
  }

  TargetCandidate? groupConversationTargetFor(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) return null;
    for (final target in scannedTargets) {
      if (target.target == normalized) return target;
    }
    return null;
  }

  List<TargetCandidate> get groupConversationParticipantTargets {
    if (!selectedConversationIsOrchestration) return const [];
    final agentIds = groupConversationRoster.participants
        .where((participant) => participant.kind == GroupParticipantKind.agent)
        .map((participant) => participant.agentId?.trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (agentIds.isEmpty) {
      return orchestrationAvailableTargets;
    }
    return scannedTargets
        .where((target) => agentIds.contains(target.target))
        .toList(growable: false);
  }

  List<GroupParticipant> get groupConversationRosterParticipants =>
      groupConversationRoster.participants;
}
