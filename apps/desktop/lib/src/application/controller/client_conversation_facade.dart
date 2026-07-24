import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

mixin ClientConversationFacade on AgentWorkspaceCoordinator {
  ConversationPresentationSignals get conversationPresentationSignals;

  ValueListenable<int> get conversationStructureListenable =>
      conversationPresentationSignals.structureListenable;
  ValueListenable<int> get activeConversationListenable =>
      conversationPresentationSignals.activeListenable;
  String get conversationComposerDraft =>
      conversationPresentationSignals.composerDraft;

  void updateConversationComposerDraft(String value) {
    conversationPresentationSignals.replaceComposerDraft(value);
  }

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

  @override
  void agentWorkspaceNotifyStateChanged() => notifyClientStateChanged();

  @override
  void agentWorkspaceNotifyConversationStructureChanged({
    bool activeChanged = true,
  }) => notifyConversationStructureChanged(activeChanged: activeChanged);

  @override
  void agentWorkspaceNotifyActiveConversationChanged() =>
      notifyActiveConversationChanged();
}
