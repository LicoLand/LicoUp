part of 'package:flutter_client/src/application/controller/client_controller.dart';

/// Attention tier used by the native-conversation refresh coordinator.
///
/// The selected conversation only receives [active] while this Flutter view is
/// focused, resumed, and the Agents section is visible. Hidden views are
/// [suspended] and perform no timer-driven work.
enum ConversationRefreshPriority { active, warm, background, suspended }

class ConversationRefreshPolicy {
  const ConversationRefreshPolicy({
    this.activeInterval = const Duration(seconds: 2),
    this.warmInterval = const Duration(seconds: 10),
    this.backgroundInterval = const Duration(seconds: 30),
    this.activeCatalogInterval = const Duration(seconds: 20),
    this.warmCatalogInterval = const Duration(seconds: 45),
    this.backgroundCatalogInterval = const Duration(seconds: 60),
  });

  final Duration activeInterval;
  final Duration warmInterval;
  final Duration backgroundInterval;
  final Duration activeCatalogInterval;
  final Duration warmCatalogInterval;
  final Duration backgroundCatalogInterval;

  Duration activeDelay(ConversationRefreshPriority priority) =>
      switch (priority) {
        ConversationRefreshPriority.active => activeInterval,
        ConversationRefreshPriority.warm => warmInterval,
        ConversationRefreshPriority.background => backgroundInterval,
        ConversationRefreshPriority.suspended => Duration.zero,
      };

  Duration catalogDelay(ConversationRefreshPriority priority) =>
      switch (priority) {
        ConversationRefreshPriority.active => activeCatalogInterval,
        ConversationRefreshPriority.warm => warmCatalogInterval,
        ConversationRefreshPriority.background => backgroundCatalogInterval,
        ConversationRefreshPriority.suspended => Duration.zero,
      };
}

extension ClientConversationRefreshActions on ClientController {
  ConversationRefreshPriority get conversationRefreshPriority {
    if (_mobileClientRuntimePlatform ||
        switch (_conversationAppLifecycleState) {
          AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached => true,
          AppLifecycleState.resumed || AppLifecycleState.inactive => false,
        }) {
      return ConversationRefreshPriority.suspended;
    }
    if (currentSection != ClientSection.agents) {
      return ConversationRefreshPriority.background;
    }
    if (_conversationAppLifecycleState == AppLifecycleState.resumed &&
        _conversationViewFocused) {
      return ConversationRefreshPriority.active;
    }
    return ConversationRefreshPriority.warm;
  }

  void updateConversationAttention({
    AppLifecycleState? lifecycleState,
    bool? viewFocused,
  }) {
    final nextLifecycle = lifecycleState ?? _conversationAppLifecycleState;
    final nextFocused = viewFocused ?? _conversationViewFocused;
    if (nextLifecycle == _conversationAppLifecycleState &&
        nextFocused == _conversationViewFocused) {
      return;
    }
    final previousPriority = conversationRefreshPriority;
    _conversationAppLifecycleState = nextLifecycle;
    _conversationViewFocused = nextFocused;
    final nextPriority = conversationRefreshPriority;
    _scheduleConversationRefreshForSelection(
      immediateActive:
          nextPriority == ConversationRefreshPriority.active &&
          previousPriority != ConversationRefreshPriority.active,
    );
  }

  void _conversationAttentionContextChanged({bool immediateActive = true}) {
    _scheduleConversationRefreshForSelection(immediateActive: immediateActive);
  }

  void _scheduleConversationRefreshForSelection({
    bool immediateActive = false,
  }) {
    _conversationActiveRefreshTimer?.cancel();
    _conversationActiveRefreshTimer = null;
    _conversationBackgroundRefreshTimer?.cancel();
    _conversationBackgroundRefreshTimer = null;

    final agentId = selectedConversationAgentId.trim();
    final priority = conversationRefreshPriority;
    if (_disposed ||
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
    _conversationActiveRefreshTimer?.cancel();
    _conversationActiveRefreshTimer = Timer(delay, () {
      _conversationActiveRefreshTimer = null;
      unawaited(_runScheduledActiveConversationRefresh(agentId));
    });
  }

  Future<void> _runScheduledActiveConversationRefresh(String agentId) async {
    if (!_conversationRefreshTargetIsCurrent(agentId)) {
      return;
    }
    final selectedSessionId = selectedConversationSessionId.trim();
    if (selectedSessionId.isEmpty ||
        selectedSessionId == _conversationSessionReadbackPendingSelectionId ||
        selectedSessionId == _conversationSessionLoadFailedSelectionId) {
      await _refreshConversationCatalog(agentId, foreground: true);
    } else {
      await _refreshActiveConversationSession(agentId, selectedSessionId);
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
    _conversationBackgroundRefreshTimer?.cancel();
    _conversationBackgroundRefreshTimer = Timer(delay, () {
      _conversationBackgroundRefreshTimer = null;
      unawaited(_runScheduledConversationCatalogRefresh(agentId));
    });
  }

  Future<void> _runScheduledConversationCatalogRefresh(String agentId) async {
    if (!_conversationRefreshTargetIsCurrent(agentId)) {
      return;
    }
    await _refreshConversationCatalog(agentId, foreground: false);
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
    return !_disposed &&
        initialized &&
        selectedConversationAgentId == agentId &&
        !isAgentOrchestrationTargetId(agentId) &&
        conversationRefreshPriority != ConversationRefreshPriority.suspended;
  }

  void _stopConversationRefreshScheduling() {
    _conversationActiveRefreshTimer?.cancel();
    _conversationActiveRefreshTimer = null;
    _conversationBackgroundRefreshTimer?.cancel();
    _conversationBackgroundRefreshTimer = null;
  }

  int _beginConversationRequest() {
    _conversationRequestSequence += 1;
    return _conversationRequestSequence;
  }

  bool _canApplyConversationRequest(String agentId, int sequence) {
    final applied = _conversationAppliedRequestSequenceByAgent[agentId] ?? 0;
    if (_disposed || sequence < applied) {
      return false;
    }
    _conversationAppliedRequestSequenceByAgent[agentId] = sequence;
    return true;
  }
}
