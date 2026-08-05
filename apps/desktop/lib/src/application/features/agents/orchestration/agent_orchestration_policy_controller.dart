import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/platform/agents/group_conversation_store.dart';

/// Persists the adaptive flywheel: Daily Conversation priority, Current
/// Conversation (`main_agent`) dispatch owner, plus code-engineering Designer,
/// frontend/backend Worker, and frontend/backend Reviewer roles.
mixin AgentOrchestrationPolicyController on AgentWorkspaceCoordinator {
  bool get orchestrationAvailable => !agentWorkspaceMobileRuntime;

  @override
  bool get selectedConversationIsOrchestration =>
      orchestrationAvailable &&
      isAgentOrchestrationTargetId(selectedConversationAgentId);

  List<TargetCandidate> get orchestrationAvailableTargets {
    if (!orchestrationAvailable) return const [];
    return scannedTargets
        .where((target) => target.isConversationAgent && target.canRelayRuntime)
        .toList(growable: false);
  }

  AgentOrchestrationPolicy get effectiveAgentOrchestrationPolicy {
    if (orchestrationPolicyDraft.isNotEmpty) {
      return normalizeOrchestrationPolicyForPersistence(
        AgentOrchestrationPolicy.fromTomlConfig(orchestrationPolicyDraft),
      );
    }
    return const AgentOrchestrationPolicy();
  }

  bool get agentOrchestrationPolicyConfigured =>
      effectiveAgentOrchestrationPolicy.configured;

  bool get orchestrationPolicyConfigured => agentOrchestrationPolicyConfigured;

  Map<String, Object?> get effectiveOrchestrationPolicy =>
      orchestrationPolicyDraft;

  Set<String> get agentOrchestrationOpenCircuitAgentIds => const {};

  TargetCandidate? get agentOrchestrationManagerTarget {
    final id = effectiveAgentOrchestrationPolicy.commanderAgentId;
    for (final target in orchestrationAvailableTargets) {
      if (target.target == id) return target;
    }
    return null;
  }

  /// The configured main agent, even when its executable binding is not yet
  /// runnable. This is presentation state; dispatch continues to use
  /// [agentOrchestrationManagerTarget].
  TargetCandidate? get agentOrchestrationConfiguredManagerTarget {
    final id = effectiveAgentOrchestrationPolicy.commanderAgentId;
    for (final target in scannedTargets) {
      if (target.target == id) return target;
    }
    return null;
  }

  List<TargetCandidate> get agentOrchestrationSubordinates {
    final managerId = effectiveAgentOrchestrationPolicy.commanderAgentId;
    return orchestrationAvailableTargets
        .where((target) => target.target != managerId)
        .toList(growable: false);
  }

  @override
  Future<void> loadAgentOrchestrationPolicy() async {
    try {
      final stored = await agentWorkspaceReadAdaptiveFlywheelState();
      final storedPolicy = AgentOrchestrationPolicy.fromTomlConfig(stored);
      if (!storedPolicy.configured) return;
      // Startup first hydrates a paint-fast target cache whose executable
      // bindings are intentionally removed. Do not validate persisted
      // selection against that non-authoritative projection: the background
      // scan will make [effectiveAgentOrchestrationPolicy] resolve it
      // dynamically as soon as the real runtime target is available.
      _applyMainAgentSelection(storedPolicy);
      await _syncGroupConversationRosterFromPolicy();
    } catch (_) {
      // A missing or malformed optional setting must not block client startup.
    }
  }

  Future<void> saveAgentOrchestrationPolicy(
    AgentOrchestrationPolicy policy,
  ) async {
    if (!orchestrationAvailable) {
      return;
    }
    final draft = normalizeOrchestrationPolicyForPersistence(policy);
    if (!draft.configured) {
      if (!await _persistAdaptiveFlywheel(
        const AgentOrchestrationPolicy().toTomlConfig(),
      )) {
        return;
      }
      orchestrationPolicyDraft = const {};
      activeOrchestrationPolicyRevision = '';
      agentWorkspaceSetLocalizedStatusMessage(
        '适应性飞轮设置已清空。',
        'Adaptive flywheel settings cleared.',
      );
      statusCaption = 'Adaptive flywheel';
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (!await _persistAdaptiveFlywheel(draft.toTomlConfig())) return;
    _applyMainAgentSelection(draft);
    await _syncGroupConversationRosterFromPolicy();
    agentWorkspaceSetLocalizedStatusMessage(
      '适应性飞轮已保存，代码工程将按前后端角色策略调度。',
      'Adaptive flywheel saved; code engineering now follows the frontend/backend role policy.',
    );
    statusCaption = 'Adaptive flywheel';
    agentWorkspaceNotifyStateChanged();
  }

  void _applyMainAgentSelection(AgentOrchestrationPolicy draft) {
    orchestrationPolicyDraft = Map<String, Object?>.unmodifiable(
      draft.toTomlConfig(),
    );
    activeOrchestrationPolicyRevision = _policyRevision(draft);
    conversationModelsByAgent = {
      ...conversationModelsByAgent,
      agentOrchestrationTargetId: draft.commanderModelName,
    };
    conversationReasoningEffortsByAgent = {
      ...conversationReasoningEffortsByAgent,
      agentOrchestrationTargetId: draft.commanderReasoningEffort,
    };
  }

  Future<bool> _persistAdaptiveFlywheel(Map<String, Object?> policy) async {
    try {
      await agentWorkspaceWriteAdaptiveFlywheelState(policy);
      lastError = '';
      return true;
    } catch (_) {
      lastError = 'main_agent_settings_write_failed';
      agentWorkspaceSetLocalizedStatusMessage(
        '适应性飞轮设置保存失败。',
        'Could not save the adaptive flywheel settings.',
      );
      statusCaption = 'Adaptive flywheel';
      agentWorkspaceNotifyStateChanged();
      return false;
    }
  }

  String _policyRevision(AgentOrchestrationPolicy policy) {
    return [
      for (final assignment in policy.dailyConversationAgents) ...[
        assignment.id,
        assignment.agentId,
        assignment.modelName,
        assignment.reasoningEffort,
        assignment.fast ? '1' : '0',
      ],
      policy.commanderAgentId,
      policy.commanderModelName,
      policy.commanderReasoningEffort,
      for (final list in [
        policy.designerAgents,
        policy.workerAgents,
        policy.reviewerAgents,
      ])
        for (final assignment in list) ...[
          assignment.id,
          assignment.agentId,
          assignment.modelName,
          assignment.reasoningEffort,
        ],
    ].join('\u0000');
  }

  Future<void> _syncGroupConversationRosterFromPolicy() async {
    if (!orchestrationAvailable) return;
    try {
      final policy = effectiveAgentOrchestrationPolicy;
      final selected = <String, String>{};
      void put(String agentId) {
        final id = agentId.trim();
        if (id.isEmpty) return;
        TargetCandidate? match;
        for (final target in scannedTargets) {
          if (target.target == id) {
            match = target;
            break;
          }
        }
        selected.putIfAbsent(
          id,
          () =>
              match?.label.trim().isNotEmpty == true ? match!.label.trim() : id,
        );
      }

      for (final agentId in policy.dailyConversationAgentIds) {
        put(agentId);
      }
      put(policy.commanderAgentId);
      for (final agentId in policy.codeEngineeringAgentIds) {
        put(agentId);
      }
      final record = await GroupConversationStore().syncRosterFromFlywheel(
        portableData: agentWorkspacePortableData,
        mainAgentId: policy.commanderAgentId,
        agents: [
          for (final entry in selected.entries)
            (id: entry.key, label: entry.value),
        ],
      );
      groupConversationRoster = record.roster;
    } catch (_) {
      // Group roster sync is best-effort and must not block policy saves.
    }
  }
}
