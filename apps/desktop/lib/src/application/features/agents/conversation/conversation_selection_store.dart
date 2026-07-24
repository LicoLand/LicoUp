import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

/// Owns the selected target/session and per-tab presentation state without
/// depending on catalog loading, dispatch, or refresh scheduling.
mixin ConversationSelectionStore on AgentWorkspaceCoordinator {
  @override
  TargetCandidate? get selectedConversationAgent {
    if (selectedConversationIsOrchestration) {
      return agentOrchestrationTargetCandidate(
        label: agentWorkspaceStrings.defaultLabel,
      );
    }
    for (final target in scannedTargets) {
      if (target.target == selectedConversationAgentId) {
        return target;
      }
    }
    return null;
  }

  @override
  List<AgentConversationSession> get selectedConversationSessions =>
      conversationSessionsByAgent[selectedConversationAgentId] ?? const [];

  bool get selectedConversationSessionsHasMore =>
      conversationSessionsHasMoreByAgent[selectedConversationAgentId] ?? false;

  bool get isLoadingMoreSelectedConversationSessions =>
      conversationSessionLoadMoreTargets.contains(selectedConversationAgentId);

  @override
  AgentConversationTabActivity conversationTabActivityFor(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return AgentConversationTabActivity.none;
    }
    return conversationTabActivityByAgent[normalized] ??
        AgentConversationTabActivity.none;
  }

  @override
  void setConversationTabActivity(
    String agentId,
    AgentConversationTabActivity activity,
  ) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return;
    }
    final current =
        conversationTabActivityByAgent[normalized] ??
        AgentConversationTabActivity.none;
    if (current == activity) {
      if (activity != AgentConversationTabActivity.none ||
          !conversationTabActivityByAgent.containsKey(normalized)) {
        return;
      }
    }
    final next = <String, AgentConversationTabActivity>{
      ...conversationTabActivityByAgent,
    };
    if (activity == AgentConversationTabActivity.none) {
      next.remove(normalized);
    } else {
      next[normalized] = activity;
    }
    conversationTabActivityByAgent = Map.unmodifiable(next);
  }

  /// Clears unread completion when the user opens that agent tab. Approval
  /// state remains until the next send resolves it.
  @override
  void acknowledgeConversationTabWorkFinished(String agentId) {
    if (conversationTabActivityFor(agentId) ==
        AgentConversationTabActivity.workFinished) {
      setConversationTabActivity(agentId, AgentConversationTabActivity.none);
    }
  }

  @override
  void recordConversationTabSendOutcome({
    required String agentId,
    required bool ok,
    Map<String, dynamic> result = const <String, dynamic>{},
    String failureCode = '',
  }) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return;
    }
    if (ok) {
      _setConversationSendError(normalized, '');
      setConversationTabActivity(
        normalized,
        AgentConversationTabActivity.workFinished,
      );
      return;
    }
    final code = failureCode.trim().isNotEmpty
        ? failureCode.trim()
        : runtimeAdapterFailureCode(result);
    _setConversationSendError(normalized, code);
    final needsApproval =
        agentConversationResultNeedsApproval(result) ||
        code.toLowerCase().contains('user_interaction');
    setConversationTabActivity(
      normalized,
      needsApproval
          ? AgentConversationTabActivity.needsApproval
          : AgentConversationTabActivity.none,
    );
  }

  @override
  String conversationSendErrorFor(String agentId) =>
      (conversationSendErrorsByAgent[agentId.trim()] ?? '').trim();

  void _setConversationSendError(String agentId, String errorCode) {
    final next = <String, String>{...conversationSendErrorsByAgent};
    final normalizedCode = errorCode.trim();
    if (normalizedCode.isEmpty) {
      next.remove(agentId);
    } else {
      next[agentId] = normalizedCode;
    }
    conversationSendErrorsByAgent = Map.unmodifiable(next);
  }

  @override
  String get selectedConversationModel =>
      (conversationModelsByAgent[selectedConversationAgentId] ?? '').trim();

  /// The model the agent falls back to when no explicit model is selected,
  /// as discovered from the agent's own configuration. Empty when unknown.
  String get selectedConversationDefaultModel {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return '';
    }
    return (agent.modelCatalog['defaultModel'] ?? '').toString().trim();
  }

  @override
  String get selectedConversationReasoningEffort =>
      (conversationReasoningEffortsByAgent[selectedConversationAgentId] ?? '')
          .trim();

  List<String> get selectedConversationModelOptions {
    final agent = selectedConversationAgent;
    if (agent == null) return const [];
    final models = agent.modelCatalog['models'];
    if (models is! List) return const [];
    return List<String>.unmodifiable([
      for (final model in models)
        if (model is Map && (model['name'] ?? '').toString().trim().isNotEmpty)
          (model['name'] ?? '').toString().trim(),
    ]);
  }

  List<String> get selectedConversationReasoningEffortOptions {
    final agent = selectedConversationAgent;
    if (agent == null) return const [];
    final models = agent.modelCatalog['models'];
    if (models is! List) return const [];
    for (final model in models) {
      if (model is! Map ||
          (model['name'] ?? '').toString().trim() !=
              selectedConversationModel) {
        continue;
      }
      final efforts = model['reasoningEfforts'];
      if (efforts is! List) return const [];
      return List<String>.unmodifiable(
        efforts
            .map((effort) => effort.toString().trim())
            .where((effort) => effort.isNotEmpty),
      );
    }
    return const [];
  }

  void selectConversationModel(String model) {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    final normalized = model.trim();
    if (normalized.isNotEmpty &&
        !selectedConversationModelOptions.contains(normalized)) {
      lastError = 'native_agent_model_not_discovered';
      agentWorkspaceNotifyActiveConversationChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    conversationModelsByAgent = {
      ...conversationModelsByAgent,
      agent.target: normalized,
    };
    final reasoning = selectedConversationReasoningEffort;
    if (reasoning.isNotEmpty &&
        !selectedConversationReasoningEffortOptions.contains(reasoning)) {
      conversationReasoningEffortsByAgent = {
        ...conversationReasoningEffortsByAgent,
        agent.target: '',
      };
    }
    lastError = '';
    agentWorkspaceNotifyActiveConversationChanged();
    agentWorkspaceNotifyStateChanged();
  }

  void selectConversationReasoningEffort(String reasoningEffort) {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    final normalized = reasoningEffort.trim();
    if (normalized.isNotEmpty &&
        !selectedConversationReasoningEffortOptions.contains(normalized)) {
      lastError = 'native_agent_reasoning_effort_not_discovered';
      agentWorkspaceNotifyActiveConversationChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    conversationReasoningEffortsByAgent = {
      ...conversationReasoningEffortsByAgent,
      agent.target: normalized,
    };
    lastError = '';
    agentWorkspaceNotifyActiveConversationChanged();
    agentWorkspaceNotifyStateChanged();
  }

  @override
  AgentConversationSession? get selectedConversationSession {
    if (preparingNewConversation) {
      return null;
    }
    final selectedId = selectedConversationSessionId.trim();
    if (selectedId.isNotEmpty) {
      for (final session in selectedConversationSessions) {
        if (session.id == selectedId) {
          return session;
        }
      }
      return null;
    }
    return selectedConversationSessions.isNotEmpty
        ? selectedConversationSessions.first
        : null;
  }
}
