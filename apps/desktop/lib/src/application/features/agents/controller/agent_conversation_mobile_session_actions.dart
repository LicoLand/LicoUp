part of 'package:flutter_client/src/application/controller/client_controller.dart';

const int _mobileConversationSessionLimit = 20;
const String _mobileConversationSessionLoadFailedSelectionId =
    '__mobile_native_session_unresolved__';

extension ClientMobileConversationSessionActions on ClientController {
  Future<void> _loadMobileConversationSessions(String agentId) async {
    final normalizedAgent = agentId.trim();
    final selectedProjectionId = selectedConversationSessionId.trim();
    final previousSelection = selectedConversationSession;
    final pendingNativeSessionId = _pendingConversationNativeSessionId(
      normalizedAgent,
    );
    final preferredNativeSessionId = pendingNativeSessionId.isNotEmpty
        ? pendingNativeSessionId
        : previousSelection?.nativeSessionId.trim() ?? '';
    final requiresExactSelection =
        selectedProjectionId.isNotEmpty &&
        selectedProjectionId != _mobileConversationSessionLoadFailedSelectionId;
    _isLoadingMobileConversations = true;
    lastError = '';
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      normalizedAgent: const <AgentConversationSession>[],
    };
    conversationSessionsHasMoreByAgent = {
      ...conversationSessionsHasMoreByAgent,
      normalizedAgent: false,
    };
    _setSelectedConversationSessionIdForAgent(normalizedAgent, '');
    _preparingNewConversation = false;
    _setLocalizedStatusMessage(
      '正在通过 Secure Mesh 读取 $normalizedAgent 原生历史。',
      'Reading native $normalizedAgent history through Secure Mesh.',
    );
    statusCaption = 'Mobile relay';
    _notifyConversationStructureChanged();
    _notifyStateChanged();
    try {
      final page = await _readMobileConversationSessionPage(
        normalizedAgent,
        offset: 0,
      );
      if (page == null) {
        _failMobileConversationSessionLoad(
          normalizedAgent,
          lastError.trim().isEmpty
              ? 'secure_agent_sessions_list_failed'
              : lastError.trim(),
          blockedSelectionId: selectedProjectionId,
        );
        return;
      }
      var sortedSessions = page.sessions;
      var hasMore = page.hasMore;
      if (requiresExactSelection) {
        final exactMatches = preferredNativeSessionId.isNotEmpty
            ? sortedSessions.where(
                (session) =>
                    session.nativeSessionId == preferredNativeSessionId,
              )
            : sortedSessions.where(
                (session) => session.id == selectedProjectionId,
              );
        if (exactMatches.length != 1) {
          final described = await _describeMobileConversationSession(
            normalizedAgent,
            preferredNativeSessionId.isNotEmpty
                ? preferredNativeSessionId
                : selectedProjectionId,
          );
          if (described == null) {
            _failMobileConversationSessionLoad(
              normalizedAgent,
              'native_session_readback_missing',
              blockedSelectionId: selectedProjectionId,
            );
            return;
          }
          sortedSessions = _mergeConversationSessionsByUpdatedAt(
            sortedSessions,
            [described],
          );
          _setSelectedConversationSessionIdForAgent(
            normalizedAgent,
            described.id,
          );
          _clearConversationNativeSessionPending(normalizedAgent);
        } else {
          _setSelectedConversationSessionIdForAgent(
            normalizedAgent,
            exactMatches.single.id,
          );
          _clearConversationNativeSessionPending(normalizedAgent);
        }
      } else if (sortedSessions.isNotEmpty) {
        _setSelectedConversationSessionIdForAgent(
          normalizedAgent,
          sortedSessions.first.id,
        );
      }
      conversationSessionsByAgent = {
        ...conversationSessionsByAgent,
        normalizedAgent: sortedSessions,
      };
      conversationSessionsHasMoreByAgent = {
        ...conversationSessionsHasMoreByAgent,
        normalizedAgent: hasMore,
      };
      _setLocalizedStatusMessage(
        sortedSessions.isEmpty
            ? '$normalizedAgent 暂未发现原生历史。'
            : hasMore
            ? '已通过 Secure Mesh 读取前 ${sortedSessions.length} 条 $normalizedAgent 原生历史，滚动到底继续加载。'
            : '已通过 Secure Mesh 读取 ${sortedSessions.length} 条 $normalizedAgent 原生历史。',
        sortedSessions.isEmpty
            ? 'No native $normalizedAgent history found.'
            : hasMore
            ? 'Read the first ${sortedSessions.length} native $normalizedAgent ${sortedSessions.length == 1 ? 'session' : 'sessions'} through Secure Mesh. Scroll to load more.'
            : 'Read ${sortedSessions.length} native $normalizedAgent ${sortedSessions.length == 1 ? 'session' : 'sessions'} through Secure Mesh.',
      );
      statusCaption = 'Mobile relay';
    } catch (_) {
      _failMobileConversationSessionLoad(
        normalizedAgent,
        'secure_agent_sessions_list_failed',
        blockedSelectionId: selectedProjectionId,
      );
    } finally {
      _isLoadingMobileConversations = false;
      _notifyConversationStructureChanged();
      _notifyStateChanged();
    }
  }

  Future<void> _loadMoreMobileConversationSessions(String agentId) async {
    final normalized = agentId.trim();
    if (normalized.isEmpty ||
        isAgentOrchestrationTargetId(normalized) ||
        _isLoadingMobileConversations ||
        _conversationSessionLoadMoreTargets.contains(normalized) ||
        !(conversationSessionsHasMoreByAgent[normalized] ?? false)) {
      return;
    }
    _conversationSessionLoadMoreTargets.add(normalized);
    _setLocalizedStatusMessage(
      '正在继续读取 $normalized 原生历史。',
      'Continuing to read native $normalized history.',
    );
    statusCaption = 'Mobile relay';
    _notifyConversationStructureChanged(activeChanged: false);
    _notifyStateChanged();
    try {
      final offset = conversationSessionsByAgent[normalized]?.length ?? 0;
      final page = await _readMobileConversationSessionPage(
        normalized,
        offset: offset,
      );
      if (page == null) {
        lastError = lastError.trim().isEmpty
            ? 'secure_agent_sessions_list_failed'
            : lastError.trim();
        _setLocalizedStatusMessage(
          '$normalized 原生历史继续加载失败。',
          'Failed to continue loading native $normalized history.',
        );
        return;
      }
      final previous = conversationSessionsByAgent[normalized] ?? const [];
      final next = _mergeConversationSessionsByUpdatedAt(
        previous,
        page.sessions,
      );
      conversationSessionsByAgent = {
        ...conversationSessionsByAgent,
        normalized: next,
      };
      conversationSessionsHasMoreByAgent = {
        ...conversationSessionsHasMoreByAgent,
        normalized: page.hasMore,
      };
      if (selectedConversationAgentId == normalized) {
        _reconcileSelectedConversationSession(normalized, next);
        _setLocalizedStatusMessage(
          page.hasMore
              ? '已读取 ${next.length} 条 $normalized 原生历史，滚动到底继续加载。'
              : '已读取 ${next.length} 条 $normalized 原生历史。',
          page.hasMore
              ? 'Read ${next.length} native $normalized sessions. Scroll to the bottom to load more.'
              : 'Read ${next.length} native $normalized sessions.',
        );
      }
      statusCaption = 'Mobile relay';
    } finally {
      _conversationSessionLoadMoreTargets.remove(normalized);
      _notifyConversationStructureChanged();
      _notifyStateChanged();
    }
  }

  Future<_ConversationSessionPage?> _readMobileConversationSessionPage(
    String agentId, {
    required int offset,
  }) async {
    final result = await mobileRelayService.listSecureAgentSessions(
      agentService: agentService,
      agentId: agentId,
      limit: _mobileConversationSessionLimit,
      offset: offset,
    );
    if (result['ok'] != true) {
      lastError = _mobileConversationSessionErrorCode(result);
      return null;
    }
    final rawSessions = result['sessions'];
    if ((result['agentId'] ?? '').toString().trim() != agentId ||
        rawSessions is! List ||
        rawSessions.length > _mobileConversationSessionLimit ||
        result['hasMore'] is! bool) {
      lastError = 'secure_agent_sessions_result_invalid';
      return null;
    }
    final sessions = <AgentConversationSession>[];
    final projectionIds = <String>{};
    final sessionsByNativeId = <String, AgentConversationSession>{};
    for (final rawSession in rawSessions) {
      final sessionJson = _agentRelayMap(rawSession);
      if (sessionJson == null ||
          sessionJson['native'] != true ||
          sessionJson['readOnly'] != true) {
        lastError = 'secure_agent_sessions_result_invalid';
        return null;
      }
      final session = AgentConversationSession.fromJson(sessionJson);
      if (session.id.trim().isEmpty ||
          session.nativeSessionId.trim().isEmpty ||
          session.agentId.trim() != agentId ||
          !projectionIds.add(session.id)) {
        lastError = 'secure_agent_sessions_result_invalid';
        return null;
      }
      final duplicateNative = sessionsByNativeId[session.nativeSessionId];
      if (duplicateNative == null ||
          _compareConversationSessionUpdatedAt(session, duplicateNative) < 0) {
        sessionsByNativeId[session.nativeSessionId] = session;
      }
    }
    sessions.addAll(sessionsByNativeId.values);
    return _ConversationSessionPage(
      sessions: _sortConversationSessionsByUpdatedAt(sessions),
      hasMore: result['hasMore'] == true,
    );
  }

  Future<AgentConversationSession?> _describeMobileConversationSession(
    String agentId,
    String sessionId,
  ) async {
    final normalizedSession = sessionId.trim();
    if (normalizedSession.isEmpty) {
      return null;
    }
    final result = await mobileRelayService.describeSecureAgentSession(
      agentService: agentService,
      agentId: agentId,
      sessionId: normalizedSession,
    );
    if (result['ok'] != true) {
      return null;
    }
    final rawSessions = result['sessions'];
    if ((result['agentId'] ?? '').toString().trim() != agentId ||
        rawSessions is! List ||
        rawSessions.length != 1) {
      return null;
    }
    final sessionJson = _agentRelayMap(rawSessions.single);
    if (sessionJson == null ||
        sessionJson['native'] != true ||
        sessionJson['readOnly'] != true) {
      return null;
    }
    final session = AgentConversationSession.fromJson(sessionJson);
    if (session.id.trim().isEmpty ||
        session.nativeSessionId.trim().isEmpty ||
        session.agentId.trim() != agentId) {
      return null;
    }
    if (session.nativeSessionId != normalizedSession &&
        session.id != normalizedSession) {
      return null;
    }
    return session;
  }

  void _failMobileConversationSessionLoad(
    String agentId,
    String errorCode, {
    String blockedSelectionId = '',
  }) {
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      agentId: const <AgentConversationSession>[],
    };
    conversationSessionsHasMoreByAgent = {
      ...conversationSessionsHasMoreByAgent,
      agentId: false,
    };
    _setSelectedConversationSessionIdForAgent(
      agentId,
      blockedSelectionId.isEmpty
          ? _mobileConversationSessionLoadFailedSelectionId
          : blockedSelectionId,
    );
    _preparingNewConversation = false;
    lastError = errorCode;
    _setLocalizedStatusMessage(
      '$agentId 原生历史读取失败，未选择其他会话。',
      'Failed to read native $agentId history; no other session was selected.',
    );
    statusCaption = 'Mobile relay';
  }
}

String _mobileConversationSessionErrorCode(Map<String, dynamic> result) {
  final candidate = (result['errorCode'] ?? result['code'] ?? '')
      .toString()
      .trim();
  if (candidate.isNotEmpty &&
      candidate.length <= 64 &&
      RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(candidate)) {
    return candidate;
  }
  return 'secure_agent_sessions_list_failed';
}
