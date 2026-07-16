import 'package:flutter_client/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:flutter_client/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';

String mobileConversationSessionErrorCode(Map<String, dynamic> result) {
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

/// Secure Mesh history transport and its fail-closed response validation.
mixin AgentConversationMobileSessionController
    on AgentWorkspaceCoordinator, AgentConversationSessionStateController {
  Future<void> loadMobileConversationSessions(String agentId) async {
    final normalizedAgent = agentId.trim();
    final selectedProjectionId = selectedConversationSessionId.trim();
    final previousSelection = selectedConversationSession;
    final pendingNativeSessionId = conversationPendingNativeSessionId(
      normalizedAgent,
    );
    final preferredNativeSessionId = pendingNativeSessionId.isNotEmpty
        ? pendingNativeSessionId
        : previousSelection?.nativeSessionId.trim() ?? '';
    final requiresExactSelection =
        selectedProjectionId.isNotEmpty &&
        selectedProjectionId != mobileConversationSessionLoadFailedSelectionId;
    conversationMobileLoading = true;
    lastError = '';
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      normalizedAgent: const <AgentConversationSession>[],
    };
    conversationSessionsHasMoreByAgent = {
      ...conversationSessionsHasMoreByAgent,
      normalizedAgent: false,
    };
    setSelectedConversationSessionId(normalizedAgent, '');
    preparingNewConversation = false;
    agentWorkspaceSetLocalizedStatusMessage(
      '正在通过 Secure Mesh 读取 $normalizedAgent 原生历史。',
      'Reading native $normalizedAgent history through Secure Mesh.',
    );
    statusCaption = 'Mobile relay';
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
    try {
      final page = await readMobileConversationSessionPage(
        normalizedAgent,
        offset: 0,
      );
      if (page == null) {
        failMobileConversationSessionLoad(
          normalizedAgent,
          lastError.trim().isEmpty
              ? 'secure_agent_sessions_list_failed'
              : lastError.trim(),
          blockedSelectionId: selectedProjectionId,
        );
        return;
      }
      var sortedSessions = page.sessions;
      final hasMore = page.hasMore;
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
          final described = await describeMobileConversationSession(
            normalizedAgent,
            preferredNativeSessionId.isNotEmpty
                ? preferredNativeSessionId
                : selectedProjectionId,
          );
          if (described == null) {
            failMobileConversationSessionLoad(
              normalizedAgent,
              'native_session_readback_missing',
              blockedSelectionId: selectedProjectionId,
            );
            return;
          }
          sortedSessions = mergeConversationSessionsByUpdatedAt(
            sortedSessions,
            [described],
          );
          setSelectedConversationSessionId(normalizedAgent, described.id);
          conversationClearNativeSessionPending(normalizedAgent);
        } else {
          setSelectedConversationSessionId(
            normalizedAgent,
            exactMatches.single.id,
          );
          conversationClearNativeSessionPending(normalizedAgent);
        }
      } else if (sortedSessions.isNotEmpty) {
        setSelectedConversationSessionId(
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
      agentWorkspaceSetLocalizedStatusMessage(
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
      failMobileConversationSessionLoad(
        normalizedAgent,
        'secure_agent_sessions_list_failed',
        blockedSelectionId: selectedProjectionId,
      );
    } finally {
      conversationMobileLoading = false;
      agentWorkspaceNotifyConversationStructureChanged();
      agentWorkspaceNotifyStateChanged();
    }
  }

  Future<void> loadMoreMobileConversationSessions(String agentId) async {
    final normalized = agentId.trim();
    if (normalized.isEmpty ||
        isAgentOrchestrationTargetId(normalized) ||
        conversationMobileLoading ||
        conversationSessionLoadMoreTargets.contains(normalized) ||
        !(conversationSessionsHasMoreByAgent[normalized] ?? false)) {
      return;
    }
    conversationSessionLoadMoreTargets.add(normalized);
    agentWorkspaceSetLocalizedStatusMessage(
      '正在继续读取 $normalized 原生历史。',
      'Continuing to read native $normalized history.',
    );
    statusCaption = 'Mobile relay';
    agentWorkspaceNotifyConversationStructureChanged(activeChanged: false);
    agentWorkspaceNotifyStateChanged();
    try {
      final offset = conversationSessionsByAgent[normalized]?.length ?? 0;
      final page = await readMobileConversationSessionPage(
        normalized,
        offset: offset,
      );
      if (page == null) {
        lastError = lastError.trim().isEmpty
            ? 'secure_agent_sessions_list_failed'
            : lastError.trim();
        agentWorkspaceSetLocalizedStatusMessage(
          '$normalized 原生历史继续加载失败。',
          'Failed to continue loading native $normalized history.',
        );
        return;
      }
      final previous = conversationSessionsByAgent[normalized] ?? const [];
      final next = mergeConversationSessionsByUpdatedAt(
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
        conversationReconcileSelectedSession(normalized, next);
        agentWorkspaceSetLocalizedStatusMessage(
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
      conversationSessionLoadMoreTargets.remove(normalized);
      agentWorkspaceNotifyConversationStructureChanged();
      agentWorkspaceNotifyStateChanged();
    }
  }

  Future<ConversationSessionPage?> readMobileConversationSessionPage(
    String agentId, {
    required int offset,
  }) async {
    final result = await mobileConversationGateway.listSessions(
      agentId: agentId,
      limit: mobileConversationSessionLimit,
      offset: offset,
    );
    if (result['ok'] != true) {
      lastError = mobileConversationSessionErrorCode(result);
      return null;
    }
    final rawSessions = result['sessions'];
    if ((result['agentId'] ?? '').toString().trim() != agentId ||
        rawSessions is! List ||
        rawSessions.length > mobileConversationSessionLimit ||
        result['hasMore'] is! bool) {
      lastError = 'secure_agent_sessions_result_invalid';
      return null;
    }
    final sessions = <AgentConversationSession>[];
    final projectionIds = <String>{};
    final sessionsByNativeId = <String, AgentConversationSession>{};
    for (final rawSession in rawSessions) {
      final sessionJson = agentRelayMap(rawSession);
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
          compareConversationSessionUpdatedAt(session, duplicateNative) < 0) {
        sessionsByNativeId[session.nativeSessionId] = session;
      }
    }
    sessions.addAll(sessionsByNativeId.values);
    return ConversationSessionPage(
      sessions: sortConversationSessionsByUpdatedAt(sessions),
      hasMore: result['hasMore'] == true,
    );
  }

  Future<AgentConversationSession?> describeMobileConversationSession(
    String agentId,
    String sessionId,
  ) async {
    final normalizedSession = sessionId.trim();
    if (normalizedSession.isEmpty) {
      return null;
    }
    final result = await mobileConversationGateway.describeSession(
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
    final sessionJson = agentRelayMap(rawSessions.single);
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

  void failMobileConversationSessionLoad(
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
    setSelectedConversationSessionId(
      agentId,
      blockedSelectionId.isEmpty
          ? mobileConversationSessionLoadFailedSelectionId
          : blockedSelectionId,
    );
    preparingNewConversation = false;
    lastError = errorCode;
    agentWorkspaceSetLocalizedStatusMessage(
      '$agentId 原生历史读取失败，未选择其他会话。',
      'Failed to read native $agentId history; no other session was selected.',
    );
    statusCaption = 'Mobile relay';
  }
}
