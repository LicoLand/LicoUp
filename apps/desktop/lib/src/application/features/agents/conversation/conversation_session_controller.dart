import 'dart:async';

import 'package:flutter_client/src/application/features/agents/conversation/agent_conversation_read_only_policy.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_mobile_session_controller.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:flutter_client/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';

/// Desktop history paging plus user-driven session and agent selection.
mixin AgentConversationSessionController
    on
        AgentWorkspaceCoordinator,
        AgentConversationSessionStateController,
        AgentConversationMobileSessionController {
  @override
  Future<void> refreshConversationCatalogInternal(
    String agentId, {
    required bool foreground,
  }) async {
    if (agentId.isEmpty ||
        isAgentOrchestrationTargetId(agentId) ||
        agentWorkspaceMobileRuntime ||
        conversationSessionLoadingTargets.contains(agentId)) {
      return;
    }
    final activeKey = (
      agentId: agentId,
      sessionId: conversationCatalogRefreshKey,
    );
    if (foreground) {
      if (!conversationActiveRefreshTargets.add(activeKey)) {
        return;
      }
    } else if (!conversationBackgroundRefreshTargets.add(agentId)) {
      return;
    }

    final sequence = beginConversationRequest();
    try {
      final page = await readConversationSessionPage(
        agentId,
        offset: 0,
        pageSize: conversationSessionPageSize,
      );
      if (!canApplyConversationRequest(agentId, sequence)) {
        return;
      }
      conversationCommitCatalog(
        agentId,
        page,
        replaceAll: false,
        updateStatus: false,
      );
    } catch (_) {
      // Timer-driven refresh is silent. A later foreground request may repair
      // the stale local projection.
    } finally {
      if (foreground) {
        conversationActiveRefreshTargets.remove(activeKey);
      } else {
        conversationBackgroundRefreshTargets.remove(agentId);
      }
    }
  }

  @override
  Future<void> refreshActiveConversationSessionInternal(
    String agentId,
    String sessionId,
  ) async {
    final key = (agentId: agentId, sessionId: sessionId);
    if (!conversationActiveRefreshTargets.add(key)) {
      return;
    }
    final sequence = beginConversationRequest();
    var exactSessionFound = false;
    try {
      final page = await readConversationSessionPage(
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
      if (!canApplyConversationRequest(agentId, sequence)) {
        return;
      }
      final previous = conversationSessionsByAgent[agentId] ?? const [];
      final next = insertConversationSessionByUpdatedAt(previous, refreshed);
      if (conversationSessionListsEquivalent(previous, next)) {
        return;
      }
      conversationSessionsByAgent = {
        ...conversationSessionsByAgent,
        agentId: next,
      };
      if (selectedConversationAgentId == agentId &&
          selectedConversationSessionId == sessionId) {
        agentWorkspaceNotifyActiveConversationChanged();
      }
    } catch (_) {
      // Exact-session refresh is best effort. The catalog lane repairs misses.
    } finally {
      conversationActiveRefreshTargets.remove(key);
      if (!exactSessionFound &&
          selectedConversationAgentId == agentId &&
          selectedConversationSessionId == sessionId) {
        unawaited(
          refreshConversationCatalogInternal(agentId, foreground: true),
        );
      }
    }
  }

  Future<ConversationSessionPage> readConversationSessionPage(
    String agentId, {
    String sessionId = '',
    required int offset,
    required int pageSize,
  }) async {
    try {
      final streamed = <AgentConversationSession>[];
      var hasMore = false;
      await for (final session in conversationGateway.streamSessions(
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
      return ConversationSessionPage(
        sessions: sortConversationSessionsByUpdatedAt(streamed),
        hasMore: hasMore,
      );
    } catch (_) {
      final loaded = sortConversationSessionsByUpdatedAt(
        await conversationGateway.loadSessions(
          agentId: agentId,
          sessionId: sessionId,
          limit: pageSize + (sessionId.isEmpty ? 1 : 0),
          offset: offset,
        ),
      );
      return ConversationSessionPage(
        sessions: loaded.take(pageSize).toList(growable: false),
        hasMore: sessionId.isEmpty && loaded.length > pageSize,
      );
    }
  }

  Future<void> loadMoreConversationSessions(String agentId) async {
    final normalized = agentId.trim();
    if (agentWorkspaceMobileRuntime) {
      await loadMoreMobileConversationSessions(normalized);
      return;
    }
    if (normalized.isEmpty ||
        isAgentOrchestrationTargetId(normalized) ||
        isLoadingConversations ||
        conversationSessionLoadMoreTargets.contains(normalized) ||
        !(conversationSessionsHasMoreByAgent[normalized] ?? false)) {
      return;
    }
    conversationSessionLoadMoreTargets.add(normalized);
    agentWorkspaceSetLocalizedStatusMessage(
      '正在继续读取 $normalized 原生历史。',
      'Continuing to read native $normalized history.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyConversationStructureChanged(activeChanged: false);
    agentWorkspaceNotifyStateChanged();
    final sequence = beginConversationRequest();
    try {
      final offset = conversationSessionsByAgent[normalized]?.length ?? 0;
      final page = await readConversationSessionPage(
        normalized,
        offset: offset,
        pageSize: conversationSessionPageSize,
      );
      if (!canApplyConversationRequest(normalized, sequence)) {
        return;
      }
      final previous = conversationSessionsByAgent[normalized] ?? const [];
      final next = mergeConversationSessionsByUpdatedAt(
        previous,
        page.sessions,
      );
      if (!conversationSessionListsEquivalent(previous, next)) {
        conversationSessionsByAgent = {
          ...conversationSessionsByAgent,
          normalized: next,
        };
      }
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
    } finally {
      conversationSessionLoadMoreTargets.remove(normalized);
      agentWorkspaceNotifyConversationStructureChanged();
      agentWorkspaceNotifyStateChanged();
    }
  }

  Future<void> reloadSelectedConversationSessionsAfterSend(
    String agentId, {
    String preferredNativeSessionId = '',
  }) async {
    final preferred = preferredNativeSessionId.trim();
    if (preferred.isNotEmpty) {
      conversationMarkNativeSessionPending(agentId, preferred);
    }
    final sequence = beginConversationRequest();
    final page = preferred.isEmpty
        ? await readConversationSessionPage(
            agentId,
            offset: 0,
            pageSize: conversationSessionPageSize,
          )
        : await readConversationSessionPage(
            agentId,
            sessionId: preferred,
            offset: 0,
            pageSize: 1,
          );
    if (!canApplyConversationRequest(agentId, sequence)) {
      return;
    }
    preparingNewConversation = false;
    final committedPage = preferred.isEmpty
        ? page
        : ConversationSessionPage(
            sessions: mergeConversationSessionsByUpdatedAt(
              conversationSessionsByAgent[agentId] ?? const [],
              page.sessions,
            ),
            hasMore: conversationSessionsHasMoreByAgent[agentId] ?? false,
          );
    conversationCommitCatalog(
      agentId,
      committedPage,
      replaceAll: true,
      updateStatus: false,
    );
    if (preferred.isNotEmpty &&
        conversationPendingNativeSessionId(agentId).isNotEmpty) {
      lastError = 'native_session_readback_missing';
      agentWorkspaceSetLocalizedStatusMessage(
        '原生会话尚未出现在历史回读中；未选择其他会话。',
        'The native session has not appeared in history readback; no other session was selected.',
      );
      statusCaption = 'Agent chat';
    }
  }

  void selectConversationSession(String sessionId) {
    conversationClearNativeSessionPending(selectedConversationAgentId);
    selectedConversationSessionId = sessionId;
    preparingNewConversation = false;
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
    conversationAttentionContextChanged();
  }

  void startNewConversationSession() {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    conversationClearNativeSessionPending(agent.target);
    final previousSession = selectedConversationSession;
    final previousWorkingDirectory =
        previousSession?.workingDirectory.trim() ?? '';
    newConversationWorkingDirectories = {
      ...newConversationWorkingDirectories,
      if (previousWorkingDirectory.isNotEmpty)
        agent.target: previousWorkingDirectory,
    };
    if (previousWorkingDirectory.isEmpty) {
      newConversationWorkingDirectories = {...newConversationWorkingDirectories}
        ..remove(agent.target);
    }
    selectedConversationSessionId = '';
    preparingNewConversation = true;
    lastError = '';
    agentWorkspaceSetLocalizedStatusMessage(
      '已准备 ${agent.label} 新对话，发送首条消息后创建。',
      'A new ${agent.label} conversation is ready and will be created after you send the first message.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
    conversationAttentionContextChanged(immediateActive: false);
  }

  Future<void> deleteConversationSession(String sessionId) async {
    final agentId = selectedConversationAgentId;
    if (agentId.isEmpty || sessionId.isEmpty) {
      return;
    }
    lastError = nativeConversationReadOnlyMessageZh;
    agentWorkspaceSetLocalizedStatusMessage(
      '原生历史只读，未删除源会话。',
      'Native history is read-only; the source session was not deleted.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> selectConversationAgent(String agentId) async {
    final normalizedAgentId = agentId.trim();
    if (isAgentOrchestrationTargetId(normalizedAgentId)) {
      if (!routingModuleAvailable) {
        return;
      }
      acknowledgeConversationTabWorkFinished(agentOrchestrationTargetId);
      selectedConversationAgentId = agentOrchestrationTargetId;
      preparingNewConversation = false;
      stopConversationRefreshScheduling();
      syncAgentOrchestrationPolicy();
      ensureOrchestrationConversationSession();
      agentWorkspaceSetLocalizedStatusMessage(
        '已切换到默认智能体编排。',
        'Switched to the default agent orchestration.',
      );
      statusCaption = 'Agent orchestration';
      agentWorkspaceNotifyConversationStructureChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (normalizedAgentId.isEmpty) {
      return;
    }
    if (normalizedAgentId == selectedConversationAgentId &&
        selectedConversationSessions.isNotEmpty) {
      acknowledgeConversationTabWorkFinished(normalizedAgentId);
      conversationAttentionContextChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }

    acknowledgeConversationTabWorkFinished(normalizedAgentId);
    selectedConversationAgentId = normalizedAgentId;
    preparingNewConversation = false;
    agentWorkspaceSetLocalizedStatusMessage(
      '正在读取 $normalizedAgentId 原生历史。',
      'Reading native $normalizedAgentId history.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();

    if (agentWorkspaceMobileRuntime) {
      stopConversationRefreshScheduling();
      await loadConversationSessions(normalizedAgentId);
      return;
    }
    if ((conversationSessionsByAgent[normalizedAgentId] ?? const [])
        .isNotEmpty) {
      conversationAttentionContextChanged();
      return;
    }
    await loadConversationSessions(normalizedAgentId);
  }

  Future<void> loadConversationSessions(String agentId) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty ||
        conversationSessionLoadingTargets.contains(normalizedAgentId)) {
      return;
    }
    if (isAgentOrchestrationTargetId(normalizedAgentId)) {
      if (!routingModuleAvailable) {
        return;
      }
      stopConversationRefreshScheduling();
      ensureOrchestrationConversationSession();
      conversationSessionsHasMoreByAgent = {
        ...conversationSessionsHasMoreByAgent,
        agentOrchestrationTargetId: false,
      };
      agentWorkspaceNotifyConversationStructureChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (agentWorkspaceMobileRuntime) {
      stopConversationRefreshScheduling();
      await loadMobileConversationSessions(normalizedAgentId);
      return;
    }

    conversationSessionLoadingTargets.add(normalizedAgentId);
    if (selectedConversationAgentId == normalizedAgentId) {
      lastError = '';
      agentWorkspaceNotifyConversationStructureChanged(activeChanged: false);
      agentWorkspaceNotifyStateChanged();
    }
    final sequence = beginConversationRequest();
    try {
      final page = await readConversationSessionPage(
        normalizedAgentId,
        offset: 0,
        pageSize: conversationSessionPageSize,
      );
      if (!canApplyConversationRequest(normalizedAgentId, sequence)) {
        return;
      }
      conversationCommitCatalog(
        normalizedAgentId,
        page,
        replaceAll: true,
        updateStatus: selectedConversationAgentId == normalizedAgentId,
        notifyChanges: false,
      );
    } catch (_) {
      if (selectedConversationAgentId == normalizedAgentId) {
        lastError = 'native_history_load_failed';
        agentWorkspaceSetLocalizedStatusMessage(
          '$normalizedAgentId 原生历史读取失败。',
          'Failed to read native $normalizedAgentId history.',
        );
        statusCaption = 'Agent chat';
        if (conversationPendingNativeSessionId(normalizedAgentId).isNotEmpty) {
          selectedConversationSessionId =
              conversationSessionReadbackPendingSelectionId;
        } else if (selectedConversationSessions.isEmpty) {
          selectedConversationSessionId =
              conversationSessionLoadFailedSelectionId;
        }
      }
    } finally {
      conversationSessionLoadingTargets.remove(normalizedAgentId);
      if (selectedConversationAgentId == normalizedAgentId) {
        agentWorkspaceNotifyConversationStructureChanged();
        agentWorkspaceNotifyStateChanged();
        conversationAttentionContextChanged(immediateActive: false);
      }
    }
  }

  Future<void> refreshConversationSessions(String agentId) {
    return refreshConversationCatalogInternal(agentId.trim(), foreground: true);
  }
}
