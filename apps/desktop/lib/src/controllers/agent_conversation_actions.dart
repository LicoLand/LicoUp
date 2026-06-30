part of 'future_client_controller.dart';

extension FutureClientConversationActions on FutureClientController {
  TargetCandidate? get selectedConversationAgent {
    for (final target in scannedTargets) {
      if (target.target == selectedConversationAgentId) {
        return target;
      }
    }
    return null;
  }

  List<AgentConversationSession> get selectedConversationSessions {
    return conversationSessionsByAgent[selectedConversationAgentId] ?? const [];
  }

  AgentConversationSession? get selectedConversationSession {
    for (final session in selectedConversationSessions) {
      if (session.id == selectedConversationSessionId) {
        return session;
      }
    }
    return selectedConversationSessions.isNotEmpty
        ? selectedConversationSessions.first
        : null;
  }

  Future<void> selectConversationAgent(String agentId) async {
    if (agentId == selectedConversationAgentId &&
        selectedConversationSessions.isNotEmpty) {
      return;
    }
    selectedConversationAgentId = agentId;
    selectedConversationSessionId = '';
    statusMessage = '正在读取 $agentId 原生历史。';
    statusCaption = 'Agent chat';
    _notifyStateChanged();
    await loadConversationSessions(agentId);
  }

  Future<void> loadConversationSessions(String agentId) async {
    if (agentId.trim().isEmpty || isLoadingConversations) {
      return;
    }
    isLoadingConversations = true;
    lastError = '';
    _notifyStateChanged();
    try {
      final sessions = await conversationService.loadSessions(
        agentService: agentService,
        agentId: agentId,
      );
      conversationSessionsByAgent = {
        ...conversationSessionsByAgent,
        agentId: sessions,
      };
      if (sessions.isEmpty) {
        selectedConversationSessionId = '';
      } else if (!sessions.any(
        (session) => session.id == selectedConversationSessionId,
      )) {
        selectedConversationSessionId = sessions.first.id;
      }
      statusMessage = sessions.isEmpty
          ? '$agentId 暂未发现原生历史。'
          : '已读取 ${sessions.length} 条 $agentId 原生历史。';
      statusCaption = 'Agent chat';
    } catch (error) {
      debugPrint('Failed to load agent conversations: $error');
      lastError = error.toString();
      statusMessage = '$agentId 原生历史读取失败。';
      statusCaption = 'Agent chat';
    } finally {
      isLoadingConversations = false;
      _notifyStateChanged();
    }
  }

  void selectConversationSession(String sessionId) {
    selectedConversationSessionId = sessionId;
    _notifyStateChanged();
  }

  Future<void> deleteConversationSession(String sessionId) async {
    final agentId = selectedConversationAgentId;
    if (agentId.isEmpty || sessionId.isEmpty) {
      return;
    }
    lastError = '原生智能体历史只读，LicoLite 不会删除源智能体会话。';
    statusMessage = '原生历史只读，未删除源会话。';
    statusCaption = 'Agent chat';
    _notifyStateChanged();
  }

  Future<void> sendConversationMessage(String text) async {
    final agent = selectedConversationAgent;
    final trimmedText = text.trim();
    if (agent == null || trimmedText.isEmpty || isSendingConversationMessage) {
      return;
    }
    isSendingConversationMessage = true;
    lastError = '';
    statusMessage = '正在通过 ${agent.label} runtime adapter 发送消息。';
    statusCaption = 'Agent chat';
    _notifyStateChanged();
    try {
      final selectedSession = selectedConversationSession;
      final sessionId = selectedSession == null
          ? selectedConversationSessionId
          : (selectedSession.nativeSessionId.trim().isNotEmpty
                ? selectedSession.nativeSessionId
                : selectedSession.id);
      final result = await conversationService.sendRuntimeMessage(
        agentService: agentService,
        agentId: agent.target,
        text: trimmedText,
        sessionId: sessionId,
      );
      if (result['ok'] != true) {
        lastError =
            (result['stderr'] ?? result['error'] ?? 'runtime adapter failed')
                .toString();
        statusMessage = '${agent.label} runtime adapter 返回失败。';
      } else {
        statusMessage = '已通过 ${agent.label} runtime adapter 发送消息。';
      }

      final sessions = await conversationService.loadSessions(
        agentService: agentService,
        agentId: agent.target,
      );
      conversationSessionsByAgent = {
        ...conversationSessionsByAgent,
        agent.target: sessions,
      };
      if (sessions.isEmpty) {
        selectedConversationSessionId = '';
      } else if (!sessions.any(
        (session) => session.id == selectedConversationSessionId,
      )) {
        selectedConversationSessionId = sessions.first.id;
      }
      statusCaption = 'Agent chat';
    } catch (error) {
      debugPrint('Failed to send agent runtime message: $error');
      lastError = error.toString();
      statusMessage = '${agent.label} runtime adapter 发送失败。';
      statusCaption = 'Agent chat';
    } finally {
      isSendingConversationMessage = false;
      _notifyStateChanged();
    }
  }
}
