import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/presentation/composer_drafts.dart';

mixin ClientConversationFacade on AgentWorkspaceCoordinator {
  ClientConversationController get clientConversationController;
  @override
  ConversationPresentationSignals get conversationPresentationSignals;
  ComposerDraftStore get composerDraftStore;

  /// Restores unsent composer text from the client data root. Optional state:
  /// an unreadable document keeps its bytes and leaves drafts in memory.
  Future<void> loadComposerDrafts() =>
      conversationPresentationSignals.loadComposerDrafts(
        store: composerDraftStore,
        portableData: agentWorkspacePortableData,
      );

  Stream<ApplicationChange> get conversationStructureChanges =>
      conversationPresentationSignals.structureChanges;
  Stream<ApplicationChange> get activeConversationChanges =>
      conversationPresentationSignals.activeChanges;
  Stream<ApplicationChange> get liveConversationChanges =>
      conversationPresentationSignals.liveChanges;
  Stream<ApplicationChange> get conversationTabActivityChanges =>
      conversationPresentationSignals.tabActivityChanges;

  void notifyClientStateChanged() {
    if (!lifecycleProjection.disposed) publishChange();
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

  void notifyConversationTabActivityChanged() {
    conversationPresentationSignals.notifyTabActivityChanged();
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

  @override
  void agentWorkspaceNotifyConversationTabActivityChanged() =>
      notifyConversationTabActivityChanged();
}
