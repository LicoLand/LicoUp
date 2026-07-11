part of 'package:flutter_client/src/application/controller/future_client_controller.dart';

extension FutureClientConversationMessagingActions on FutureClientController {
  Future<void> sendConversationMessage(String text) async {
    final agent = selectedConversationAgent;
    final messageText = text;
    if (agent == null ||
        messageText.trim().isEmpty ||
        isSendingConversationMessage) {
      return;
    }
    if (!selectedConversationIsOrchestration && !agent.canRelayRuntime) {
      final blocker = agent.conversationBlocker.trim();
      lastError = blocker.isEmpty
          ? 'native_conversation_parity_${agent.conversationReadiness}'
          : blocker;
      _setLocalizedStatusMessage(
        '${agent.label} 尚未通过原生对话一致性验收，发送已禁用。',
        '${agent.label} has not passed native conversation parity checks. Sending is disabled.',
      );
      statusCaption = 'Agent chat';
      _notifyStateChanged();
      return;
    }
    if (selectedConversationIsOrchestration) {
      await _sendOrchestratedConversationMessage(messageText);
      return;
    }
    final selectedSession = selectedConversationSession;
    if (selectedSession == null &&
        selectedConversationSessionId.trim().isNotEmpty) {
      lastError = 'native_session_unresolved';
      _setLocalizedStatusMessage(
        '${agent.label} 原生会话尚未解析，发送已禁用。',
        'The native ${agent.label} session has not been resolved. Sending is disabled.',
      );
      statusCaption = 'Agent chat';
      _notifyStateChanged();
      return;
    }
    if (selectedSession != null &&
        selectedSession.nativeSessionId.trim().isEmpty) {
      lastError = 'native_session_id_missing';
      _setLocalizedStatusMessage(
        '${agent.label} 历史记录缺少原生会话标识，发送已禁用。',
        'The ${agent.label} history is missing its native session ID. Sending is disabled.',
      );
      statusCaption = 'Agent chat';
      _notifyStateChanged();
      return;
    }
    isSendingConversationMessage = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在通过 ${agent.label} 运行时适配器发送消息。',
      'Sending the message through the ${agent.label} runtime adapter.',
    );
    statusCaption = 'Agent chat';
    _notifyStateChanged();
    try {
      final sessionId = selectedSession == null
          ? ''
          : selectedSession.nativeSessionId.trim();
      final workingDirectory =
          selectedSession?.workingDirectory.trim().isNotEmpty == true
          ? selectedSession!.workingDirectory.trim()
          : (_newConversationWorkingDirectories[agent.target] ?? '').trim();
      final sendThroughMobileRelay = _mobileClientRuntimePlatform;
      final result = sendThroughMobileRelay
          ? await mobileRelayService.sendSecureAgentMessage(
              agentService: agentService,
              agentId: agent.target,
              text: messageText,
              sessionId: sessionId,
              model: selectedConversationModel,
              reasoningEffort: selectedConversationReasoningEffort,
            )
          : (await conversationService.send(
              runner: agentService,
              agentId: agent.target,
              text: messageText,
              sessionId: sessionId,
              bind: AgentDispatchBind(
                sessionPath: selectedSession?.sourcePath ?? '',
                workingDirectory: workingDirectory,
                binaryPath: agent.binaryPath ?? '',
                model: selectedConversationModel,
                reasoningEffort: selectedConversationReasoningEffort,
              ),
              conversationReadiness: agent.conversationReadiness,
            )).raw;
      // The driver owns the continuity identifier. Codex may expose a
      // process/session id that differs from the native thread id used by
      // history and resume, so never infer precedence in the Flutter layer.
      final returnedSessionId = sendThroughMobileRelay
          ? _secureAgentRelayNativeSessionId(result)
          : (result['nativeSessionId'] ??
                    result['threadId'] ??
                    result['sessionId'] ??
                    '')
                .toString()
                .trim();
      if (result['ok'] == true) {
        if (returnedSessionId.isEmpty) {
          _preparingNewConversation = false;
          if (sessionId.isNotEmpty) {
            _markConversationNativeSessionPending(agent.target, sessionId);
          } else {
            selectedConversationSessionId =
                _conversationSessionLoadFailedSelectionId;
          }
          lastError = 'native_session_id_missing_from_result';
          _setLocalizedStatusMessage(
            '${agent.label} 未返回原生会话标识，结果已拒绝。',
            '${agent.label} did not return a native session ID. The result was rejected.',
          );
          statusCaption = 'Agent chat';
          return;
        }
        if (sessionId.isNotEmpty && returnedSessionId != sessionId) {
          _preparingNewConversation = false;
          selectedConversationSessionId =
              _conversationSessionLoadFailedSelectionId;
          lastError = 'native_session_id_mismatch';
          _setLocalizedStatusMessage(
            '${agent.label} 返回了不同的原生会话，结果已拒绝。',
            '${agent.label} returned a different native session. The result was rejected.',
          );
          statusCaption = 'Agent chat';
          return;
        }
        if (!_runtimeEffectiveSettingsMatch(
          result,
          throughMobileRelay: sendThroughMobileRelay,
          requestedModel: selectedConversationModel,
          requestedReasoningEffort: selectedConversationReasoningEffort,
        )) {
          _preparingNewConversation = false;
          _markConversationNativeSessionPending(
            agent.target,
            returnedSessionId,
          );
          lastError = 'native_effective_settings_mismatch';
          _setLocalizedStatusMessage(
            '${agent.label} 未确认请求的原生模型设置，结果已拒绝。',
            '${agent.label} did not confirm the requested native model settings. The result was rejected.',
          );
          statusCaption = 'Agent chat';
          return;
        }
      }
      if (result['ok'] != true) {
        lastError = _runtimeAdapterErrorCode(result);
        if (_nativeConversationOutcomeMayBeUnknown(lastError)) {
          _preparingNewConversation = false;
          if (sessionId.isNotEmpty) {
            _markConversationNativeSessionPending(agent.target, sessionId);
          } else {
            selectedConversationSessionId =
                _conversationSessionLoadFailedSelectionId;
          }
        }
        _setLocalizedStatusMessage(
          '${agent.label} 运行时适配器返回失败。',
          'The ${agent.label} runtime adapter returned a failure.',
        );
        statusCaption = 'Agent chat';
        return;
      }
      _preparingNewConversation = false;
      if (sendThroughMobileRelay) {
        final receivedAt = DateTime.now().toUtc().toIso8601String();
        _appendRelayConversationMessages(
          agent: agent,
          userText: messageText,
          assistantText: _secureAgentRelayReplyText(result),
          sessionId: returnedSessionId,
          updatedAt: receivedAt,
        );
      }
      _setLocalizedStatusMessage(
        sendThroughMobileRelay
            ? '已通过移动中转端到端加密发送 ${agent.label} 命令。'
            : '已通过 ${agent.label} 运行时适配器发送消息。',
        sendThroughMobileRelay
            ? 'Sent the ${agent.label} command through the E2EE mobile relay.'
            : 'Sent the message through the ${agent.label} runtime adapter.',
      );

      if (!sendThroughMobileRelay) {
        try {
          await _reloadSelectedConversationSessionsAfterSend(
            agent.target,
            preferredNativeSessionId: returnedSessionId,
          );
          await refreshFeedPostsForAgent(agent.target);
        } catch (_) {
          lastError = 'native_session_readback_failed';
          _setLocalizedStatusMessage(
            '消息已发送，但原生会话回读尚未完成；发送保持禁用。',
            'The message was sent, but native session readback is not complete. Sending remains disabled.',
          );
        }
        _newConversationWorkingDirectories = {
          ..._newConversationWorkingDirectories,
        }..remove(agent.target);
      } else {
        await refreshFeedPostsForAgent(agent.target);
      }
      statusCaption = 'Agent chat';
    } catch (_) {
      lastError = 'native_agent_transport_failed';
      _setLocalizedStatusMessage(
        '${agent.label} 运行时适配器发送失败。',
        'The ${agent.label} runtime adapter failed to send the message.',
      );
      statusCaption = 'Agent chat';
    } finally {
      isSendingConversationMessage = false;
      _notifyStateChanged();
    }
  }

  String _runtimeAdapterErrorCode(Map<String, dynamic> result) {
    final nested = result['error'];
    final raw = nested is Map ? (nested['code'] ?? '') : (result['code'] ?? '');
    final code = raw.toString().trim();
    return RegExp(r'^[a-z0-9][a-z0-9_-]{0,127}$').hasMatch(code)
        ? code
        : 'native_agent_dispatch_failed';
  }

  bool _nativeConversationOutcomeMayBeUnknown(String errorCode) {
    return const {
      'secure_relay_result_timeout',
      'secure_relay_result_fetch_failed',
      'native_agent_timeout',
      'native_agent_transport_failed',
    }.contains(errorCode);
  }

  bool _runtimeEffectiveSettingsMatch(
    Map<String, dynamic> result, {
    required bool throughMobileRelay,
    required String requestedModel,
    required String requestedReasoningEffort,
  }) {
    final model = requestedModel.trim();
    final reasoning = requestedReasoningEffort.trim();
    if (model.isEmpty && reasoning.isEmpty) {
      return true;
    }
    Map<String, dynamic>? effective;
    if (throughMobileRelay) {
      final polled = _agentRelayMap(result['result']);
      final opened = _agentRelayMap(polled?['openedResult']);
      final execution = _agentRelayMap(opened?['execution']);
      final output = _agentRelayMap(execution?['output']);
      final runtime = _agentRelayMap(output?['output']);
      effective = _agentRelayMap(runtime?['effective']);
    } else {
      effective = _agentRelayMap(result['effective']);
    }
    if (effective == null) {
      return false;
    }
    return (model.isEmpty || (effective['model'] ?? '').toString() == model) &&
        (reasoning.isEmpty ||
            (effective['reasoningEffort'] ?? '').toString() == reasoning);
  }

  void _startConversationSessionPolling(String agentId) {
    if (agentId.trim().isEmpty || _mobileClientRuntimePlatform) {
      _stopConversationSessionPolling();
      return;
    }
    if (_conversationSessionPollingAgentId == agentId &&
        _conversationSessionTimer != null) {
      return;
    }
    _conversationSessionTimer?.cancel();
    _conversationSessionPollingAgentId = agentId;
    _conversationSessionTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_disposed || selectedConversationAgentId != agentId) {
        return;
      }
      unawaited(refreshConversationSessions(agentId));
    });
  }

  void _stopConversationSessionPolling() {
    _conversationSessionTimer?.cancel();
    _conversationSessionTimer = null;
    _conversationSessionPollingAgentId = '';
  }

  void _appendRelayConversationMessages({
    required TargetCandidate agent,
    required String userText,
    required String assistantText,
    required String sessionId,
    required String updatedAt,
  }) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) {
      return;
    }
    final previous = conversationSessionsByAgent[agent.target] ?? const [];
    AgentConversationSession? existing;
    for (final session in previous) {
      if (session.id == normalizedSessionId ||
          (session.nativeSessionId.trim().isNotEmpty &&
              session.nativeSessionId == normalizedSessionId)) {
        existing = session;
        break;
      }
    }
    final messages = <AgentConversationMessage>[
      ...?existing?.messages,
      AgentConversationMessage(
        id: _relayConversationMessageId(agent.target, 'user'),
        role: 'user',
        text: userText,
        createdAt: updatedAt,
      ),
      if (assistantText.trim().isNotEmpty)
        AgentConversationMessage(
          id: _relayConversationMessageId(agent.target, 'assistant'),
          role: 'assistant',
          text: assistantText.trim(),
          createdAt: updatedAt,
        ),
    ];
    final session = AgentConversationSession(
      id: existing?.id ?? normalizedSessionId,
      nativeSessionId: existing?.nativeSessionId ?? normalizedSessionId,
      agentId: agent.target,
      title: existing?.title.trim().isNotEmpty == true
          ? existing!.title
          : agent.label,
      createdAt: existing?.createdAt ?? updatedAt,
      updatedAt: updatedAt,
      adapterId: 'mobile-relay-native-projection',
      sourceKind: 'native-mobile-relay',
      sourceClient: mobileRelayConfig.pcClientId,
      sourceClientLabel: mobileRelayConfig.pcClientName,
      native: true,
      readOnly: true,
      messageCount: messages.length,
      messages: List<AgentConversationMessage>.unmodifiable(messages),
    );
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      agent.target: _insertConversationSessionByUpdatedAt(
        previous.where((item) => item.id != session.id).toList(growable: false),
        session,
      ),
    };
    selectedConversationSessionId = session.id;
  }
}
