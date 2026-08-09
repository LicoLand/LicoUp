import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

mixin ClientConversationFacade on AgentWorkspaceCoordinator {
  @override
  ConversationPresentationSignals get conversationPresentationSignals;

  ValueListenable<int> get conversationStructureListenable =>
      conversationPresentationSignals.structureListenable;
  ValueListenable<int> get activeConversationListenable =>
      conversationPresentationSignals.activeListenable;
  ValueListenable<int> get liveConversationListenable =>
      conversationPresentationSignals.liveListenable;

  void notifyClientStateChanged() {
    if (!lifecycleProjection.disposed) notifyListeners();
  }

  void notifyConversationStructureChanged({bool activeChanged = true}) {
    conversationPresentationSignals.notifyStructureChanged(
      activeChanged: activeChanged,
    );
  }

  void notifyActiveConversationChanged() {
    conversationPresentationSignals.notifyActiveChanged();
  }

  void notifyLiveConversationChanged() {
    conversationPresentationSignals.notifyLiveChanged();
  }

  @override
  void agentWorkspaceNotifyStateChanged() => notifyClientStateChanged();

  @override
  void agentWorkspaceNotifyConversationStructureChanged({
    bool activeChanged = true,
  }) => notifyConversationStructureChanged(activeChanged: activeChanged);

  @override
  void agentWorkspaceNotifyActiveConversationChanged() =>
      notifyActiveConversationChanged();

  @override
  void agentWorkspaceNotifyLiveConversationChanged() =>
      notifyLiveConversationChanged();
}
