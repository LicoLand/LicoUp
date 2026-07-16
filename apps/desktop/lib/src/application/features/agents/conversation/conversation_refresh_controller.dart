import 'dart:async';

import 'package:flutter_client/src/application/features/agents/conversation/agent_conversation_controller.dart'
    show
        conversationSessionLoadFailedSelectionId,
        conversationSessionReadbackPendingSelectionId;
import 'package:flutter_client/src/application/features/agents/policy/conversation_refresh_policy.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

mixin ConversationRefreshController on AgentWorkspaceCoordinator {
  ConversationRefreshPriority get conversationRefreshPriority {
    if (agentWorkspaceMobileRuntime ||
        switch (conversationAppLifecycleState) {
          ConversationLifecyclePhase.hidden ||
          ConversationLifecyclePhase.paused ||
          ConversationLifecyclePhase.detached => true,
          ConversationLifecyclePhase.resumed ||
          ConversationLifecyclePhase.inactive => false,
        }) {
      return ConversationRefreshPriority.suspended;
    }
    if (agentWorkspaceCurrentSection != ClientSection.agents) {
      return ConversationRefreshPriority.background;
    }
    if (conversationAppLifecycleState == ConversationLifecyclePhase.resumed &&
        conversationViewFocused) {
      return ConversationRefreshPriority.active;
    }
    return ConversationRefreshPriority.warm;
  }

  void updateConversationAttentionState({
    ConversationLifecyclePhase? lifecycleState,
    bool? viewFocused,
  }) {
    final nextLifecycle = lifecycleState ?? conversationAppLifecycleState;
    final nextFocused = viewFocused ?? conversationViewFocused;
    if (nextLifecycle == conversationAppLifecycleState &&
        nextFocused == conversationViewFocused) {
      return;
    }
    final previousPriority = conversationRefreshPriority;
    conversationAppLifecycleState = nextLifecycle;
    conversationViewFocused = nextFocused;
    final nextPriority = conversationRefreshPriority;
    _scheduleConversationRefreshForSelection(
      immediateActive:
          nextPriority == ConversationRefreshPriority.active &&
          previousPriority != ConversationRefreshPriority.active,
    );
  }

  @override
  void conversationAttentionContextChanged({bool immediateActive = true}) {
    _scheduleConversationRefreshForSelection(immediateActive: immediateActive);
  }

  void _scheduleConversationRefreshForSelection({
    bool immediateActive = false,
  }) {
    conversationActiveRefreshTimer?.cancel();
    conversationActiveRefreshTimer = null;
    conversationBackgroundRefreshTimer?.cancel();
    conversationBackgroundRefreshTimer = null;

    final agentId = selectedConversationAgentId.trim();
    final priority = conversationRefreshPriority;
    if (agentWorkspaceDisposed ||
        !initialized ||
        agentId.isEmpty ||
        isAgentOrchestrationTargetId(agentId) ||
        priority == ConversationRefreshPriority.suspended) {
      return;
    }

    _scheduleActiveConversationRefresh(
      agentId,
      immediateActive
          ? Duration.zero
          : conversationRefreshPolicy.activeDelay(priority),
    );
    _scheduleConversationCatalogRefresh(
      agentId,
      conversationRefreshPolicy.catalogDelay(priority),
    );
  }

  void _scheduleActiveConversationRefresh(String agentId, Duration delay) {
    conversationActiveRefreshTimer?.cancel();
    conversationActiveRefreshTimer = Timer(delay, () {
      conversationActiveRefreshTimer = null;
      unawaited(_runScheduledActiveConversationRefresh(agentId));
    });
  }

  Future<void> _runScheduledActiveConversationRefresh(String agentId) async {
    if (!_conversationRefreshTargetIsCurrent(agentId)) {
      return;
    }
    final selectedSessionId = selectedConversationSessionId.trim();
    if (selectedSessionId.isEmpty ||
        selectedSessionId == conversationSessionReadbackPendingSelectionId ||
        selectedSessionId == conversationSessionLoadFailedSelectionId) {
      await refreshConversationCatalogInternal(agentId, foreground: true);
    } else {
      await refreshActiveConversationSessionInternal(
        agentId,
        selectedSessionId,
      );
    }
    if (!_conversationRefreshTargetIsCurrent(agentId)) {
      return;
    }
    final priority = conversationRefreshPriority;
    _scheduleActiveConversationRefresh(
      agentId,
      conversationRefreshPolicy.activeDelay(priority),
    );
  }

  void _scheduleConversationCatalogRefresh(String agentId, Duration delay) {
    conversationBackgroundRefreshTimer?.cancel();
    conversationBackgroundRefreshTimer = Timer(delay, () {
      conversationBackgroundRefreshTimer = null;
      unawaited(_runScheduledConversationCatalogRefresh(agentId));
    });
  }

  Future<void> _runScheduledConversationCatalogRefresh(String agentId) async {
    if (!_conversationRefreshTargetIsCurrent(agentId)) {
      return;
    }
    await refreshConversationCatalogInternal(agentId, foreground: false);
    if (!_conversationRefreshTargetIsCurrent(agentId)) {
      return;
    }
    final priority = conversationRefreshPriority;
    _scheduleConversationCatalogRefresh(
      agentId,
      conversationRefreshPolicy.catalogDelay(priority),
    );
  }

  bool _conversationRefreshTargetIsCurrent(String agentId) {
    return !agentWorkspaceDisposed &&
        initialized &&
        selectedConversationAgentId == agentId &&
        !isAgentOrchestrationTargetId(agentId) &&
        conversationRefreshPriority != ConversationRefreshPriority.suspended;
  }

  @override
  void stopConversationRefreshScheduling() {
    conversationActiveRefreshTimer?.cancel();
    conversationActiveRefreshTimer = null;
    conversationBackgroundRefreshTimer?.cancel();
    conversationBackgroundRefreshTimer = null;
  }

  @override
  int beginConversationRequest() {
    conversationRequestSequence += 1;
    return conversationRequestSequence;
  }

  @override
  bool canApplyConversationRequest(String agentId, int sequence) {
    final applied = conversationAppliedRequestSequenceByAgent[agentId] ?? 0;
    if (agentWorkspaceDisposed || sequence < applied) {
      return false;
    }
    conversationAppliedRequestSequenceByAgent[agentId] = sequence;
    return true;
  }
}
