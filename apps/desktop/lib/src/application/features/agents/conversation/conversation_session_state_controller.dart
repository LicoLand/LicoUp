import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';

const int conversationSessionPageSize = 50;
const List<int> conversationInitialProgressiveMilestones = [3, 10, 20];
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

typedef ConversationSessionProgressCallback =
    void Function(ConversationSessionPage page);

/// Owns deterministic session-list reconciliation and native identity binding.
mixin AgentConversationSessionStateController on AgentWorkspaceCoordinator {
  bool conversationCommitCatalog(
    String agentId,
    ConversationSessionPage page, {
    required bool replaceAll,
    required bool updateStatus,
    bool notifyChanges = true,
    bool clearLiveProjectionFromProviderReadback = true,
  }) {
    final previous = conversationSessionsByAgent[agentId] ?? const [];
    final previousSelected = selectedConversationAgentId == agentId
        ? selectedConversationSession
        : null;
    var next = replaceAll || !page.hasMore
        ? page.sessions
        : conversationReconcileSessionHead(previous, page.sessions);
    final liveProjection = liveConversationMessagesByAgent[agentId] ?? const [];
    if (previousSelected != null &&
        liveProjection.isNotEmpty &&
        !next.any(
          (session) =>
              session.nativeSessionId.trim() ==
              previousSelected.nativeSessionId.trim(),
        )) {
      // A completed streamed turn is already an authoritative local session.
      // Provider history can lag behind the terminal event, so a catalog
      // refresh must retain that exact active identity until readback covers
      // the live projection.
      next = insertConversationSessionByUpdatedAt(next, previousSelected);
    }
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
      if (clearLiveProjectionFromProviderReadback) {
        conversationClearLiveProjectionWhenReadBack(agentId);
      }
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
    if (selectedId.isEmpty) {
      selectedConversationSessionId = sessions.first.id;
      return;
    }
    if (!sessions.any((session) => session.id == selectedId)) {
      final nativeMatches = sessions
          .where((session) => session.nativeSessionId.trim() == selectedId)
          .toList(growable: false);
      if (nativeMatches.length == 1) {
        selectedConversationSessionId = nativeMatches.single.id;
      }
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

  /// Keeps a completed streamed turn visible until the native history source
  /// contains the same user/assistant messages. Some adapters persist their
  /// transcript shortly after the transport reports completion; clearing the
  /// live projection before that readback converges makes the reply flash and
  /// then disappear.
  void conversationClearLiveProjectionWhenReadBack(String agentId) {
    final live = liveConversationMessagesByAgent[agentId] ?? const [];
    if (live.isEmpty) {
      return;
    }
    final readBack = selectedConversationAgentId == agentId
        ? selectedConversationSession
        : null;
    if (readBack == null) {
      return;
    }
    final nativeMessages = readBack.messages
        .where(_conversationMessageParticipatesInReadback)
        .toList(growable: false);
    final covered = live
        .where(_conversationMessageParticipatesInReadback)
        .every(
          (pending) => nativeMessages.any(
            (persisted) =>
                persisted.role.trim().toLowerCase() ==
                    pending.role.trim().toLowerCase() &&
                persisted.text.trim() == pending.text.trim(),
          ),
        );
    if (!covered) {
      return;
    }
    liveConversationMessagesByAgent = {
      for (final entry in liveConversationMessagesByAgent.entries)
        if (entry.key != agentId) entry.key: entry.value,
    };
  }

  bool _conversationMessageParticipatesInReadback(
    AgentConversationMessage message,
  ) {
    final role = message.role.trim().toLowerCase();
    return message.text.trim().isNotEmpty &&
        (role == 'user' || role == 'assistant');
  }

  /// Release acceptance binds readback to the exact turn projection instead of
  /// provider history scans. Cursor CLI sessions are not guaranteed to appear
  /// in `conversations list` during the same packaged process.
  void conversationCommitTurnBoundNativeReadback({
    required String agentId,
    required String nativeSessionId,
    required List<AgentConversationMessage> messages,
    required bool mergeWithSelectedSession,
  }) {
    final normalizedAgent = agentId.trim();
    final normalizedSession = nativeSessionId.trim();
    if (normalizedAgent.isEmpty || normalizedSession.isEmpty) {
      return;
    }
    conversationClearNativeSessionPending(normalizedAgent);
    final previous =
        mergeWithSelectedSession &&
            selectedConversationAgentId == normalizedAgent
        ? selectedConversationSession
        : null;
    final mergedMessages =
        previous != null && previous.nativeSessionId.trim() == normalizedSession
        ? [
            ...previous.messages,
            for (final message in messages)
              if (!previous.messages.any(
                (existing) => existing.stableIdentity == message.stableIdentity,
              ))
                message,
          ]
        : messages;
    final now = DateTime.now().toUtc().toIso8601String();
    final session = AgentConversationSession(
      id: normalizedSession,
      agentId: normalizedAgent,
      title: 'Release acceptance',
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
      nativeSessionId: normalizedSession,
      messages: List<AgentConversationMessage>.unmodifiable(mergedMessages),
      messageCount: mergedMessages.length,
      sourceMessageCount: mergedMessages.length,
    );
    conversationCommitCatalog(
      normalizedAgent,
      ConversationSessionPage(sessions: [session], hasMore: false),
      replaceAll: true,
      updateStatus: false,
      clearLiveProjectionFromProviderReadback: false,
    );
    setSelectedConversationSessionId(normalizedAgent, normalizedSession);
  }
}
