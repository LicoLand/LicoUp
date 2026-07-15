part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientConversationSelectionActions on ClientController {
  TargetCandidate? get selectedConversationAgent {
    if (selectedConversationIsOrchestration) {
      return agentOrchestrationTargetCandidate(label: _strings.defaultLabel);
    }
    for (final target in scannedTargets) {
      if (target.target == selectedConversationAgentId) {
        return target;
      }
    }
    return null;
  }

  List<AgentConversationSession> get selectedConversationSessions {
    return conversationSessionsByAgent[selectedConversationAgentId] ?? const [];
  }

  bool get selectedConversationSessionsHasMore {
    return conversationSessionsHasMoreByAgent[selectedConversationAgentId] ??
        false;
  }

  bool get isLoadingMoreSelectedConversationSessions {
    return _conversationSessionLoadMoreTargets.contains(
      selectedConversationAgentId,
    );
  }

  AgentConversationTabActivity conversationTabActivityFor(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return AgentConversationTabActivity.none;
    }
    return conversationTabActivityByAgent[normalized] ??
        AgentConversationTabActivity.none;
  }

  void _setConversationTabActivity(
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

  /// Clears unread completion when the user opens that agent tab.
  /// Approval lights stay until the next send resolves them.
  void _acknowledgeConversationTabWorkFinished(String agentId) {
    if (conversationTabActivityFor(agentId) ==
        AgentConversationTabActivity.workFinished) {
      _setConversationTabActivity(agentId, AgentConversationTabActivity.none);
    }
  }

  void _recordConversationTabSendOutcome({
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
      _setConversationTabActivity(
        normalized,
        AgentConversationTabActivity.workFinished,
      );
      return;
    }
    final code = errorCode.trim().isNotEmpty
        ? errorCode.trim()
        : _runtimeAdapterErrorCode(result);
    final needsApproval =
        agentConversationResultNeedsApproval(result) ||
        code.toLowerCase().contains('user_interaction');
    _setConversationTabActivity(
      normalized,
      needsApproval
          ? AgentConversationTabActivity.needsApproval
          : AgentConversationTabActivity.none,
    );
  }
}
