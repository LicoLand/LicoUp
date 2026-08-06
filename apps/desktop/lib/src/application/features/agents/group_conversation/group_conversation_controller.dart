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
    _applyGroupConversationRecord(record);
  }

  Future<GroupConversationRecord> _syncGroupConversationRecord() async {
    final portableData = agentWorkspacePortableData;
    final policy = effectiveAgentOrchestrationPolicy;
    final mainAgentId = policy.plainSendDispatchAgentId;
    return _store.syncRosterFromFlywheel(
      portableData: portableData,
      mainAgentId: mainAgentId,
      agents: _flywheelSelectedAgents(policy),
    );
  }

  void _applyGroupConversationRecord(GroupConversationRecord record) {
    groupConversationRoster = record.roster;
    groupConversationAgentSessions = Map.unmodifiable(record.agentSessions);
    groupConversationLastLocalSessionId =
        record.lastLocalOrchestrationSessionId;
  }

  List<({String id, String label})> _flywheelSelectedAgents(
    AgentOrchestrationPolicy policy,
  ) {
    return [
      for (final id in policy.flywheelRosterAgentIds)
        (
          id: id,
          label: () {
            final target = groupConversationTargetFor(id);
            final label = target?.label.trim() ?? '';
            return label.isNotEmpty ? label : id;
          }(),
        ),
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

  GroupAgentSessionBinding? groupConversationBindingFor(String agentId) {
    final id = agentId.trim();
    if (id.isEmpty) return null;
    return groupConversationAgentSessions[id];
  }

  /// Persist the last returned native conversation for one room participant.
  Future<void> rememberGroupAgentSession({
    required String agentId,
    String nativeSessionId = '',
    String sourcePath = '',
    String workingDirectory = '',
    String localOrchestrationSessionId = '',
  }) async {
    final portableData = agentWorkspacePortableData;
    final record = await _store.upsertAgentSession(
      portableData: portableData,
      agentId: agentId,
      nativeSessionId: nativeSessionId,
      sourcePath: sourcePath,
      workingDirectory: workingDirectory,
      localOrchestrationSessionId: localOrchestrationSessionId,
    );
    _applyGroupConversationRecord(record);
  }
}
