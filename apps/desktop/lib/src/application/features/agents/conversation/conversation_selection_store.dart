import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_conversation_tab_activity.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

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
    String errorCode = '',
  }) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return;
    }
    if (ok) {
      setConversationTabActivity(
        normalized,
        AgentConversationTabActivity.workFinished,
      );
      return;
    }
    final code = errorCode.trim().isNotEmpty
        ? errorCode.trim()
        : runtimeAdapterErrorCode(result);
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
  String get selectedConversationModel =>
      (conversationModelsByAgent[selectedConversationAgentId] ?? '').trim();

  @override
  String get selectedConversationReasoningEffort =>
      (conversationReasoningEffortsByAgent[selectedConversationAgentId] ?? '')
          .trim();

  List<String> get selectedConversationModelOptions {
    final agent = selectedConversationAgent;
    return agent == null ? const [] : agentOrchestrationCommanderModels(agent);
  }

  List<String> get selectedConversationReasoningEffortOptions {
    final agent = selectedConversationAgent;
    return agent == null
        ? const []
        : agentOrchestrationReasoningEffortsForModel(
            agent,
            selectedConversationModel,
          );
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
