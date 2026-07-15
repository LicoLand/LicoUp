part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientConversationActions on ClientController {
  Future<void> selectConversationAgent(String agentId) async {
    final normalizedAgentId = agentId.trim();
    if (isAgentOrchestrationTargetId(normalizedAgentId)) {
      if (!routingModuleAvailable) {
        return;
      }
      _acknowledgeConversationTabWorkFinished(agentOrchestrationTargetId);
      selectedConversationAgentId = agentOrchestrationTargetId;
      _preparingNewConversation = false;
      _stopConversationRefreshScheduling();
      _syncAgentOrchestrationPolicy();
      _ensureOrchestrationConversationSession();
      _setLocalizedStatusMessage(
        '已切换到默认智能体编排。',
        'Switched to the default agent orchestration.',
      );
      statusCaption = 'Agent orchestration';
      _notifyConversationStructureChanged();
      _notifyStateChanged();
      return;
    }
    if (normalizedAgentId.isEmpty) {
      return;
    }
    if (normalizedAgentId == selectedConversationAgentId &&
        selectedConversationSessions.isNotEmpty) {
      _acknowledgeConversationTabWorkFinished(normalizedAgentId);
      _conversationAttentionContextChanged();
      _notifyStateChanged();
      return;
    }

    _acknowledgeConversationTabWorkFinished(normalizedAgentId);
    selectedConversationAgentId = normalizedAgentId;
    _preparingNewConversation = false;
    _setLocalizedStatusMessage(
      '正在读取 $normalizedAgentId 原生历史。',
      'Reading native $normalizedAgentId history.',
    );
    statusCaption = 'Agent chat';
    _notifyConversationStructureChanged();
    _notifyStateChanged();

    if (_mobileClientRuntimePlatform) {
      _stopConversationRefreshScheduling();
      await loadConversationSessions(normalizedAgentId);
      return;
    }
    if ((conversationSessionsByAgent[normalizedAgentId] ?? const [])
        .isNotEmpty) {
      _conversationAttentionContextChanged();
      return;
    }
    await loadConversationSessions(normalizedAgentId);
  }

  Future<void> loadConversationSessions(String agentId) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty ||
        _conversationSessionLoadingTargets.contains(normalizedAgentId)) {
      return;
    }
    if (isAgentOrchestrationTargetId(normalizedAgentId)) {
      if (!routingModuleAvailable) {
        return;
      }
      _stopConversationRefreshScheduling();
      _ensureOrchestrationConversationSession();
      conversationSessionsHasMoreByAgent = {
        ...conversationSessionsHasMoreByAgent,
        agentOrchestrationTargetId: false,
      };
      _notifyConversationStructureChanged();
      _notifyStateChanged();
      return;
    }
    if (_mobileClientRuntimePlatform) {
      _stopConversationRefreshScheduling();
      await _loadMobileConversationSessions(normalizedAgentId);
      return;
    }

    _conversationSessionLoadingTargets.add(normalizedAgentId);
    if (selectedConversationAgentId == normalizedAgentId) {
      lastError = '';
      _notifyConversationStructureChanged(activeChanged: false);
      _notifyStateChanged();
    }
    final sequence = _beginConversationRequest();
    var dataChanged = false;
    try {
      final page = await _readConversationSessionPage(
        normalizedAgentId,
        offset: 0,
        pageSize: _conversationSessionPageSize,
      );
      if (!_canApplyConversationRequest(normalizedAgentId, sequence)) {
        return;
      }
      dataChanged = _commitConversationCatalog(
        normalizedAgentId,
        page,
        replaceAll: true,
        updateStatus: selectedConversationAgentId == normalizedAgentId,
        notifyChanges: false,
      );
    } catch (_) {
      if (selectedConversationAgentId == normalizedAgentId) {
        lastError = 'native_history_load_failed';
        _setLocalizedStatusMessage(
          '$normalizedAgentId 原生历史读取失败。',
          'Failed to read native $normalizedAgentId history.',
        );
        statusCaption = 'Agent chat';
        if (_pendingConversationNativeSessionId(normalizedAgentId).isNotEmpty) {
          selectedConversationSessionId =
              _conversationSessionReadbackPendingSelectionId;
        } else if (selectedConversationSessions.isEmpty) {
          selectedConversationSessionId =
              _conversationSessionLoadFailedSelectionId;
        }
      }
    } finally {
      _conversationSessionLoadingTargets.remove(normalizedAgentId);
      if (selectedConversationAgentId == normalizedAgentId) {
        _notifyConversationStructureChanged();
        _notifyStateChanged();
        _conversationAttentionContextChanged(immediateActive: false);
      }
      if (dataChanged) {
        _refreshFeedAfterConversationCatalogChange(normalizedAgentId);
      }
    }
  }

  Future<void> refreshConversationSessions(String agentId) {
    return _refreshConversationCatalog(agentId.trim(), foreground: true);
  }
}
