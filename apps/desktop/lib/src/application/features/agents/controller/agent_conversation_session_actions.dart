part of 'package:flutter_client/src/application/controller/client_controller.dart';

const String _conversationSessionReadbackPendingSelectionId =
    '__lico_native_session_readback_pending__';
const String _conversationSessionLoadFailedSelectionId =
    '__lico_native_session_load_failed__';

extension ClientConversationSessionActions on ClientController {
  String get selectedConversationModel {
    return (conversationModelsByAgent[selectedConversationAgentId] ?? '')
        .trim();
  }

  String get selectedConversationReasoningEffort {
    return (conversationReasoningEffortsByAgent[selectedConversationAgentId] ??
            '')
        .trim();
  }

  List<String> get selectedConversationModelOptions {
    final agent = selectedConversationAgent;
    return agent == null ? const [] : agentOrchestrationCommanderModels(agent);
  }

  List<String> get selectedConversationReasoningEffortOptions {
    final agent = selectedConversationAgent;
    return agent == null
        ? const []
        : agentOrchestrationReasoningEffortsForModel(
            agent,
            selectedConversationModel,
          );
  }

  void selectConversationModel(String model) {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    final normalized = model.trim();
    if (normalized.isNotEmpty &&
        !selectedConversationModelOptions.contains(normalized)) {
      lastError = 'native_agent_model_not_discovered';
      _notifyActiveConversationChanged();
      _notifyStateChanged();
      return;
    }
    conversationModelsByAgent = {
      ...conversationModelsByAgent,
      agent.target: normalized,
    };
    final reasoning = selectedConversationReasoningEffort;
    if (reasoning.isNotEmpty &&
        !selectedConversationReasoningEffortOptions.contains(reasoning)) {
      conversationReasoningEffortsByAgent = {
        ...conversationReasoningEffortsByAgent,
        agent.target: '',
      };
    }
    lastError = '';
    _notifyActiveConversationChanged();
    _notifyStateChanged();
  }

  void selectConversationReasoningEffort(String reasoningEffort) {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    final normalized = reasoningEffort.trim();
    if (normalized.isNotEmpty &&
        !selectedConversationReasoningEffortOptions.contains(normalized)) {
      lastError = 'native_agent_reasoning_effort_not_discovered';
      _notifyActiveConversationChanged();
      _notifyStateChanged();
      return;
    }
    conversationReasoningEffortsByAgent = {
      ...conversationReasoningEffortsByAgent,
      agent.target: normalized,
    };
    lastError = '';
    _notifyActiveConversationChanged();
    _notifyStateChanged();
  }

  AgentConversationSession? get selectedConversationSession {
    if (_preparingNewConversation) {
      return null;
    }
    final selectedId = selectedConversationSessionId.trim();
    if (selectedId.isNotEmpty) {
      for (final session in selectedConversationSessions) {
        if (session.id == selectedId) {
          return session;
        }
      }
      return null;
    }
    return selectedConversationSessions.isNotEmpty
        ? selectedConversationSessions.first
        : null;
  }

  Future<void> loadMoreConversationSessions(String agentId) async {
    final normalized = agentId.trim();
    if (_mobileClientRuntimePlatform) {
      await _loadMoreMobileConversationSessions(normalized);
      return;
    }
    if (normalized.isEmpty ||
        isAgentOrchestrationTargetId(normalized) ||
        isLoadingConversations ||
        _conversationSessionLoadMoreTargets.contains(normalized) ||
        !(conversationSessionsHasMoreByAgent[normalized] ?? false)) {
      return;
    }
    _conversationSessionLoadMoreTargets.add(normalized);
    _setLocalizedStatusMessage(
      '正在继续读取 $normalized 原生历史。',
      'Continuing to read native $normalized history.',
    );
    statusCaption = 'Agent chat';
    _notifyConversationStructureChanged(activeChanged: false);
    _notifyStateChanged();
    final sequence = _beginConversationRequest();
    var dataChanged = false;
    try {
      final offset = conversationSessionsByAgent[normalized]?.length ?? 0;
      final page = await _readConversationSessionPage(
        normalized,
        offset: offset,
        pageSize: _conversationSessionPageSize,
      );
      if (!_canApplyConversationRequest(normalized, sequence)) {
        return;
      }
      final previous = conversationSessionsByAgent[normalized] ?? const [];
      final next = _mergeConversationSessionsByUpdatedAt(
        previous,
        page.sessions,
      );
      dataChanged = !_conversationSessionListsEquivalent(previous, next);
      if (dataChanged) {
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
    } finally {
      _conversationSessionLoadMoreTargets.remove(normalized);
      _notifyConversationStructureChanged();
      _notifyStateChanged();
      if (dataChanged) {
        _refreshFeedAfterConversationCatalogChange(normalized);
      }
    }
  }

  Future<void> _reloadSelectedConversationSessionsAfterSend(
    String agentId, {
    String preferredNativeSessionId = '',
  }) async {
    final preferred = preferredNativeSessionId.trim();
    if (preferred.isNotEmpty) {
      _markConversationNativeSessionPending(agentId, preferred);
    }
    final sequence = _beginConversationRequest();
    final page = preferred.isEmpty
        ? await _readConversationSessionPage(
            agentId,
            offset: 0,
            pageSize: _conversationSessionPageSize,
          )
        : await _readConversationSessionPage(
            agentId,
            sessionId: preferred,
            offset: 0,
            pageSize: 1,
          );
    if (!_canApplyConversationRequest(agentId, sequence)) {
      return;
    }
    _preparingNewConversation = false;
    final committedPage = preferred.isEmpty
        ? page
        : _ConversationSessionPage(
            sessions: _mergeConversationSessionsByUpdatedAt(
              conversationSessionsByAgent[agentId] ?? const [],
              page.sessions,
            ),
            hasMore: conversationSessionsHasMoreByAgent[agentId] ?? false,
          );
    _commitConversationCatalog(
      agentId,
      committedPage,
      replaceAll: true,
      updateStatus: false,
    );
    if (preferred.isNotEmpty &&
        _pendingConversationNativeSessionId(agentId).isNotEmpty) {
      lastError = 'native_session_readback_missing';
      _setLocalizedStatusMessage(
        '原生会话尚未出现在历史回读中；未选择其他会话。',
        'The native session has not appeared in history readback; no other session was selected.',
      );
      statusCaption = 'Agent chat';
    }
  }

  String _pendingConversationNativeSessionId(String agentId) {
    return (_pendingConversationNativeSessionIds[agentId] ?? '').trim();
  }

  void _markConversationNativeSessionPending(
    String agentId,
    String nativeSessionId,
  ) {
    _pendingConversationNativeSessionIds = {
      ..._pendingConversationNativeSessionIds,
      agentId: nativeSessionId.trim(),
    };
    _setSelectedConversationSessionIdForAgent(
      agentId,
      _conversationSessionReadbackPendingSelectionId,
    );
  }

  void _clearConversationNativeSessionPending(String agentId) {
    if (!_pendingConversationNativeSessionIds.containsKey(agentId)) {
      return;
    }
    _pendingConversationNativeSessionIds = {
      ..._pendingConversationNativeSessionIds,
    }..remove(agentId);
  }

  void selectConversationSession(String sessionId) {
    _clearConversationNativeSessionPending(selectedConversationAgentId);
    selectedConversationSessionId = sessionId;
    _preparingNewConversation = false;
    _notifyConversationStructureChanged();
    _notifyStateChanged();
    _conversationAttentionContextChanged();
  }

  void startNewConversationSession() {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    _clearConversationNativeSessionPending(agent.target);
    final previousSession = selectedConversationSession;
    final previousWorkingDirectory =
        previousSession?.workingDirectory.trim() ?? '';
    _newConversationWorkingDirectories = {
      ..._newConversationWorkingDirectories,
      if (previousWorkingDirectory.isNotEmpty)
        agent.target: previousWorkingDirectory,
    };
    if (previousWorkingDirectory.isEmpty) {
      _newConversationWorkingDirectories = {
        ..._newConversationWorkingDirectories,
      }..remove(agent.target);
    }
    selectedConversationSessionId = '';
    _preparingNewConversation = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '已准备 ${agent.label} 新对话，发送首条消息后创建。',
      'A new ${agent.label} conversation is ready and will be created after you send the first message.',
    );
    statusCaption = 'Agent chat';
    _notifyConversationStructureChanged();
    _notifyStateChanged();
    _conversationAttentionContextChanged(immediateActive: false);
  }

  Future<void> deleteConversationSession(String sessionId) async {
    final agentId = selectedConversationAgentId;
    if (agentId.isEmpty || sessionId.isEmpty) {
      return;
    }
    lastError = '原生智能体历史只读，LicoLite 不会删除源智能体会话。';
    _setLocalizedStatusMessage(
      '原生历史只读，未删除源会话。',
      'Native history is read-only; the source session was not deleted.',
    );
    statusCaption = 'Agent chat';
    _notifyStateChanged();
  }
}
