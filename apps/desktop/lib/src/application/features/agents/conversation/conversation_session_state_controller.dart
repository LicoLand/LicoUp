import 'package:flutter_client/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';

const int conversationSessionPageSize = 50;
const String conversationCatalogRefreshKey = '__lico_catalog_refresh__';
const int mobileConversationSessionLimit = 20;
const String mobileConversationSessionLoadFailedSelectionId =
    '__mobile_native_session_unresolved__';
const String conversationSessionReadbackPendingSelectionId =
    '__lico_native_session_readback_pending__';
const String conversationSessionLoadFailedSelectionId =
    '__lico_native_session_load_failed__';

final class ConversationSessionPage {
  const ConversationSessionPage({
    required this.sessions,
    required this.hasMore,
  });

  final List<AgentConversationSession> sessions;
  final bool hasMore;
}

/// Owns deterministic session-list reconciliation and native identity binding.
mixin AgentConversationSessionStateController on AgentWorkspaceCoordinator {
  bool conversationCommitCatalog(
    String agentId,
    ConversationSessionPage page, {
    required bool replaceAll,
    required bool updateStatus,
    bool notifyChanges = true,
  }) {
    final previous = conversationSessionsByAgent[agentId] ?? const [];
    final previousSelected = selectedConversationAgentId == agentId
        ? selectedConversationSession
        : null;
    final next = replaceAll || !page.hasMore
        ? page.sessions
        : conversationReconcileSessionHead(previous, page.sessions);
    final sessionsChanged = !conversationSessionListsEquivalent(previous, next);
    final hasMoreChanged =
        (conversationSessionsHasMoreByAgent[agentId] ?? false) != page.hasMore;
    if (sessionsChanged) {
      conversationSessionsByAgent = {
        ...conversationSessionsByAgent,
        agentId: next,
      };
    }
    if (hasMoreChanged) {
      conversationSessionsHasMoreByAgent = {
        ...conversationSessionsHasMoreByAgent,
        agentId: page.hasMore,
      };
    }

    if (selectedConversationAgentId == agentId) {
      conversationReconcileSelectedSession(agentId, next);
      final activeChanged = !conversationSessionsEquivalent(
        previousSelected,
        selectedConversationSession,
      );
      if (notifyChanges && (sessionsChanged || hasMoreChanged)) {
        agentWorkspaceNotifyConversationStructureChanged(
          activeChanged: activeChanged,
        );
      }
      if (updateStatus) {
        agentWorkspaceSetLocalizedStatusMessage(
          next.isEmpty
              ? '$agentId 暂未发现原生历史。'
              : page.hasMore
              ? '已读取 ${next.length} 条 $agentId 原生历史，滚动到底继续加载。'
              : '已读取 ${next.length} 条 $agentId 原生历史。',
          next.isEmpty
              ? 'No native $agentId history found.'
              : page.hasMore
              ? 'Read ${next.length} native $agentId ${next.length == 1 ? 'session' : 'sessions'}. Scroll to the bottom to load more.'
              : 'Read ${next.length} native $agentId ${next.length == 1 ? 'session' : 'sessions'}.',
        );
        statusCaption = 'Agent chat';
      }
    }
    return sessionsChanged;
  }

  void conversationReconcileSelectedSession(
    String agentId,
    List<AgentConversationSession> sessions,
  ) {
    final pendingNativeSessionId = conversationPendingNativeSessionId(agentId);
    if (pendingNativeSessionId.isNotEmpty) {
      final matches = sessions
          .where(
            (session) =>
                session.nativeSessionId.trim() == pendingNativeSessionId,
          )
          .toList(growable: false);
      if (matches.length == 1) {
        conversationClearNativeSessionPending(agentId);
        selectedConversationSessionId = matches.single.id;
        if (lastError == 'native_session_readback_missing') {
          lastError = '';
        }
      } else {
        selectedConversationSessionId =
            conversationSessionReadbackPendingSelectionId;
      }
      return;
    }
    if (preparingNewConversation) {
      return;
    }
    if (sessions.isEmpty) {
      selectedConversationSessionId = '';
      return;
    }
    final selectedId = selectedConversationSessionId.trim();
    if (selectedId.isEmpty ||
        !sessions.any((session) => session.id == selectedId)) {
      selectedConversationSessionId = sessions.first.id;
    }
  }

  List<AgentConversationSession> conversationReconcileSessionHead(
    List<AgentConversationSession> previous,
    List<AgentConversationSession> refreshedHead,
  ) {
    if (previous.length <= conversationSessionPageSize) {
      return refreshedHead;
    }
    final refreshedIds = refreshedHead.map((session) => session.id).toSet();
    final retainedTail = previous
        .skip(conversationSessionPageSize)
        .where((session) => !refreshedIds.contains(session.id));
    return sortConversationSessionsByUpdatedAt([
      ...refreshedHead,
      ...retainedTail,
    ]);
  }

  String conversationPendingNativeSessionId(String agentId) {
    return (pendingConversationNativeSessionIds[agentId] ?? '').trim();
  }

  void conversationMarkNativeSessionPending(
    String agentId,
    String nativeSessionId,
  ) {
    pendingConversationNativeSessionIds = {
      ...pendingConversationNativeSessionIds,
      agentId: nativeSessionId.trim(),
    };
    setSelectedConversationSessionId(
      agentId,
      conversationSessionReadbackPendingSelectionId,
    );
  }

  void conversationClearNativeSessionPending(String agentId) {
    if (!pendingConversationNativeSessionIds.containsKey(agentId)) {
      return;
    }
    pendingConversationNativeSessionIds = {
      ...pendingConversationNativeSessionIds,
    }..remove(agentId);
  }
}
