part of 'package:flutter_client/src/application/controller/client_controller.dart';

const int _conversationSessionPageSize = 50;
const String _conversationCatalogRefreshKey = '__lico_catalog_refresh__';

final class _ConversationSessionPage {
  const _ConversationSessionPage({
    required this.sessions,
    required this.hasMore,
  });

  final List<AgentConversationSession> sessions;
  final bool hasMore;
}

extension ClientConversationCatalogActions on ClientController {
  Future<void> _refreshConversationCatalog(
    String agentId, {
    required bool foreground,
  }) async {
    if (agentId.isEmpty ||
        isAgentOrchestrationTargetId(agentId) ||
        _mobileClientRuntimePlatform ||
        _conversationSessionLoadingTargets.contains(agentId)) {
      return;
    }
    final activeKey = (
      agentId: agentId,
      sessionId: _conversationCatalogRefreshKey,
    );
    if (foreground) {
      if (!_conversationActiveRefreshTargets.add(activeKey)) {
        return;
      }
    } else if (!_conversationBackgroundRefreshTargets.add(agentId)) {
      return;
    }

    final sequence = _beginConversationRequest();
    var dataChanged = false;
    try {
      final page = await _readConversationSessionPage(
        agentId,
        offset: 0,
        pageSize: _conversationSessionPageSize,
      );
      if (!_canApplyConversationRequest(agentId, sequence)) {
        return;
      }
      dataChanged = _commitConversationCatalog(
        agentId,
        page,
        replaceAll: false,
        updateStatus: false,
      );
    } catch (_) {
      // Timer-driven refresh is silent. The stale snapshot remains visible and
      // a later foreground request may still succeed.
    } finally {
      if (foreground) {
        _conversationActiveRefreshTargets.remove(activeKey);
      } else {
        _conversationBackgroundRefreshTargets.remove(agentId);
      }
      if (dataChanged) {
        _refreshFeedAfterConversationCatalogChange(agentId);
      }
    }
  }

  Future<void> _refreshActiveConversationSession(
    String agentId,
    String sessionId,
  ) async {
    final key = (agentId: agentId, sessionId: sessionId);
    if (!_conversationActiveRefreshTargets.add(key)) {
      return;
    }
    final sequence = _beginConversationRequest();
    var exactSessionFound = false;
    try {
      final page = await _readConversationSessionPage(
        agentId,
        sessionId: sessionId,
        offset: 0,
        pageSize: 1,
      );
      AgentConversationSession? refreshed;
      for (final session in page.sessions) {
        if (session.id == sessionId) {
          refreshed = session;
          break;
        }
      }
      if (refreshed == null) {
        return;
      }
      exactSessionFound = true;
      if (!_canApplyConversationRequest(agentId, sequence)) {
        return;
      }
      final previous = conversationSessionsByAgent[agentId] ?? const [];
      final next = _insertConversationSessionByUpdatedAt(previous, refreshed);
      if (_conversationSessionListsEquivalent(previous, next)) {
        return;
      }
      conversationSessionsByAgent = {
        ...conversationSessionsByAgent,
        agentId: next,
      };
      if (selectedConversationAgentId == agentId &&
          selectedConversationSessionId == sessionId) {
        _notifyActiveConversationChanged();
      }
    } catch (_) {
      // Exact-session refresh is best-effort. The catalog lane repairs misses.
    } finally {
      _conversationActiveRefreshTargets.remove(key);
      if (!exactSessionFound &&
          selectedConversationAgentId == agentId &&
          selectedConversationSessionId == sessionId) {
        unawaited(_refreshConversationCatalog(agentId, foreground: true));
      }
    }
  }

  Future<_ConversationSessionPage> _readConversationSessionPage(
    String agentId, {
    String sessionId = '',
    required int offset,
    required int pageSize,
  }) async {
    try {
      final streamed = <AgentConversationSession>[];
      var hasMore = false;
      await for (final session in conversationService.streamSessions(
        agentService: agentService,
        agentId: agentId,
        sessionId: sessionId,
        limit: pageSize + (sessionId.isEmpty ? 1 : 0),
        offset: offset,
      )) {
        if (streamed.length >= pageSize) {
          hasMore = true;
          continue;
        }
        streamed.add(session);
      }
      return _ConversationSessionPage(
        sessions: _sortConversationSessionsByUpdatedAt(streamed),
        hasMore: hasMore,
      );
    } catch (_) {
      final loaded = _sortConversationSessionsByUpdatedAt(
        await conversationService.loadSessions(
          agentService: agentService,
          agentId: agentId,
          sessionId: sessionId,
          limit: pageSize + (sessionId.isEmpty ? 1 : 0),
          offset: offset,
        ),
      );
      return _ConversationSessionPage(
        sessions: loaded.take(pageSize).toList(growable: false),
        hasMore: sessionId.isEmpty && loaded.length > pageSize,
      );
    }
  }

  bool _commitConversationCatalog(
    String agentId,
    _ConversationSessionPage page, {
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
        : _reconcileConversationSessionHead(previous, page.sessions);
    final sessionsChanged = !_conversationSessionListsEquivalent(
      previous,
      next,
    );
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
      _reconcileSelectedConversationSession(agentId, next);
      final activeChanged = !_conversationSessionsEquivalent(
        previousSelected,
        selectedConversationSession,
      );
      if (notifyChanges && (sessionsChanged || hasMoreChanged)) {
        _notifyConversationStructureChanged(activeChanged: activeChanged);
      }
      if (updateStatus) {
        _setLocalizedStatusMessage(
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

  void _reconcileSelectedConversationSession(
    String agentId,
    List<AgentConversationSession> sessions,
  ) {
    final pendingNativeSessionId = _pendingConversationNativeSessionId(agentId);
    if (pendingNativeSessionId.isNotEmpty) {
      final matches = sessions
          .where(
            (session) =>
                session.nativeSessionId.trim() == pendingNativeSessionId,
          )
          .toList(growable: false);
      if (matches.length == 1) {
        _clearConversationNativeSessionPending(agentId);
        selectedConversationSessionId = matches.single.id;
        if (lastError == 'native_session_readback_missing') {
          lastError = '';
        }
      } else {
        selectedConversationSessionId =
            _conversationSessionReadbackPendingSelectionId;
      }
      return;
    }
    if (_preparingNewConversation) {
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

  List<AgentConversationSession> _reconcileConversationSessionHead(
    List<AgentConversationSession> previous,
    List<AgentConversationSession> refreshedHead,
  ) {
    if (previous.length <= _conversationSessionPageSize) {
      return refreshedHead;
    }
    final refreshedIds = refreshedHead.map((session) => session.id).toSet();
    final retainedTail = previous
        .skip(_conversationSessionPageSize)
        .where((session) => !refreshedIds.contains(session.id));
    return _sortConversationSessionsByUpdatedAt([
      ...refreshedHead,
      ...retainedTail,
    ]);
  }

  void _refreshFeedAfterConversationCatalogChange(String agentId) {
    if (currentSection != ClientSection.controlPanel &&
        currentSection != ClientSection.feed) {
      return;
    }
    unawaited(refreshFeedPostsForAgent(agentId).catchError((_) {}));
  }
}
