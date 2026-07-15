part of 'package:flutter_client/src/application/controller/client_controller.dart';

const _releaseConversationAcceptanceMode =
    bool.fromEnvironment('LICO_AGENT_CONVERSATION_RELEASE_LIVE')
    ? 'dispatch-lane-unified-1'
    : '';

extension ClientConversationMessagingActions on ClientController {
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
    sendingConversationSessionId = selectedSession?.id.trim() ?? '';
    sendingConversationNativeSessionId =
        selectedSession?.nativeSessionId.trim() ?? '';
    final liveTurnId =
        'live-${agent.target}-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    _startLiveConversationProjection(
      agentId: agent.target,
      turnId: liveTurnId,
      userText: messageText,
    );
    lastError = '';
    _setConversationTabActivity(
      agent.target,
      AgentConversationTabActivity.none,
    );
    _setLocalizedStatusMessage(
      '正在通过 ${agent.label} 运行时适配器发送消息。',
      'Sending the message through the ${agent.label} runtime adapter.',
    );
    statusCaption = 'Agent chat';
    _notifyActiveConversationChanged();
    _notifyStateChanged();
    _conversationAttentionContextChanged();
    try {
      final sessionId = selectedSession == null
          ? ''
          : selectedSession.nativeSessionId.trim();
      final workingDirectory =
          selectedSession?.workingDirectory.trim().isNotEmpty == true
          ? selectedSession!.workingDirectory.trim()
          : (_newConversationWorkingDirectories[agent.target] ?? '').trim();
      final sendThroughMobileRelay = _mobileClientRuntimePlatform;
      late final Map<String, dynamic> result;
      if (sendThroughMobileRelay) {
        result = await mobileRelayService.sendSecureAgentMessage(
          agentService: agentService,
          agentId: agent.target,
          text: messageText,
          sessionId: sessionId,
          model: selectedConversationModel,
          reasoningEffort: selectedConversationReasoningEffort,
        );
      } else {
        var streamedText = '';
        AgentDispatchTurnResult? turn;
        await for (final event in conversationService.sendStreaming(
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
            acceptanceMode: _releaseConversationAcceptanceMode,
          ),
          conversationReadiness: agent.conversationReadiness,
        )) {
          if (event.kind == 'agent.message.chunk' ||
              event.kind == 'agent.message.completed') {
            final chunk = (event.payload['text'] ?? '').toString();
            if (chunk.isNotEmpty) {
              streamedText = _mergeProgressiveConversationText(
                streamedText,
                chunk,
                completed: event.kind == 'agent.message.completed',
              );
              _upsertLiveConversationReply(
                agentId: agent.target,
                turnId: liveTurnId,
                text: streamedText,
              );
              _setLocalizedStatusMessage(
                '正在接收 ${agent.label} 回复…',
                'Receiving the ${agent.label} reply…',
              );
              statusCaption = streamedText.length > 80
                  ? '${streamedText.substring(0, 80)}…'
                  : streamedText;
              _notifyStateChanged();
            }
          } else if (event.kind == 'agent.approval.needed') {
            await _handleNativeApprovalNeededEvent(
              agentId: agent.target,
              event: event,
            );
          } else if (event.kind == 'dispatch.turn.completed' ||
              event.kind == 'dispatch.turn.failed') {
            final raw = Map<String, dynamic>.from(event.payload);
            final ok = raw['ok'] == true;
            final nested = raw['error'];
            final rawCode = nested is Map
                ? (nested['code'] ?? '')
                : (raw['code'] ?? '');
            turn = AgentDispatchTurnResult(
              ok: ok,
              sessionId: event.sessionId,
              turnId: event.turnId,
              status: (raw['turnStatus'] ?? raw['status'] ?? '').toString(),
              errorCode: ok ? '' : rawCode.toString(),
              errorMessage: ok
                  ? ''
                  : (nested is Map ? (nested['message'] ?? '') : '').toString(),
              raw: raw,
            );
          } else {
            _appendLiveConversationProcessEvent(
              agentId: agent.target,
              turnId: liveTurnId,
              event: event,
            );
          }
        }
        result =
            (turn ??
                    AgentDispatchTurnResult(
                      ok: false,
                      sessionId: sessionId,
                      errorCode: 'dispatch_stream_incomplete',
                      raw: const <String, dynamic>{
                        'ok': false,
                        'code': 'dispatch_stream_incomplete',
                      },
                    ))
                .raw;
      }
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
      if (returnedSessionId.isNotEmpty) {
        sendingConversationNativeSessionId = returnedSessionId;
      }
      if (result['ok'] == true) {
        if (returnedSessionId.isEmpty) {
          _preparingNewConversation = false;
          if (sessionId.isNotEmpty) {
            _markConversationNativeSessionPending(agent.target, sessionId);
          } else {
            _setSelectedConversationSessionIdForAgent(
              agent.target,
              _conversationSessionLoadFailedSelectionId,
            );
          }
          lastError = 'native_session_id_missing_from_result';
          _recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            errorCode: lastError,
          );
          _setLocalizedStatusMessage(
            '${agent.label} 未返回原生会话标识，结果已拒绝。',
            '${agent.label} did not return a native session ID. The result was rejected.',
          );
          statusCaption = 'Agent chat';
          return;
        }
        if (sessionId.isNotEmpty && returnedSessionId != sessionId) {
          _preparingNewConversation = false;
          _setSelectedConversationSessionIdForAgent(
            agent.target,
            _conversationSessionLoadFailedSelectionId,
          );
          lastError = 'native_session_id_mismatch';
          _recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            errorCode: lastError,
          );
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
          _recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            errorCode: lastError,
          );
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
        _recordConversationTabSendOutcome(
          agentId: agent.target,
          ok: false,
          result: result,
          errorCode: lastError,
        );
        if (_nativeConversationOutcomeMayBeUnknown(lastError)) {
          _preparingNewConversation = false;
          if (sessionId.isNotEmpty) {
            _markConversationNativeSessionPending(agent.target, sessionId);
          } else {
            _setSelectedConversationSessionIdForAgent(
              agent.target,
              _conversationSessionLoadFailedSelectionId,
            );
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
      _recordConversationTabSendOutcome(agentId: agent.target, ok: true);
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
          _refreshFeedAfterConversationCatalogChange(agent.target);
          _clearLiveConversationProjection(agent.target);
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
        _refreshFeedAfterConversationCatalogChange(agent.target);
        _clearLiveConversationProjection(agent.target);
      }
      statusCaption = 'Agent chat';
    } catch (_) {
      lastError = 'native_agent_transport_failed';
      _recordConversationTabSendOutcome(
        agentId: agent.target,
        ok: false,
        errorCode: lastError,
      );
      _setLocalizedStatusMessage(
        '${agent.label} 运行时适配器发送失败。',
        'The ${agent.label} runtime adapter failed to send the message.',
      );
      statusCaption = 'Agent chat';
    } finally {
      isSendingConversationMessage = false;
      sendingConversationSessionId = '';
      sendingConversationNativeSessionId = '';
      _notifyConversationStructureChanged();
      _notifyStateChanged();
      _conversationAttentionContextChanged();
    }
  }

  String _mergeProgressiveConversationText(
    String current,
    String incoming, {
    required bool completed,
  }) {
    if (completed || current.isEmpty) {
      return incoming;
    }
    if (incoming.startsWith(current)) {
      return incoming;
    }
    if (current.endsWith(incoming)) {
      return current;
    }
    return '$current$incoming';
  }

  void _startLiveConversationProjection({
    required String agentId,
    required String turnId,
    required String userText,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    liveConversationMessagesByAgent = {
      ...liveConversationMessagesByAgent,
      agentId: List<AgentConversationMessage>.unmodifiable([
        AgentConversationMessage(
          id: '$turnId-user',
          role: 'user',
          text: userText,
          createdAt: now,
          stableIdentity: '$turnId-user',
        ),
      ]),
    };
  }

  void _upsertLiveConversationReply({
    required String agentId,
    required String turnId,
    required String text,
  }) {
    final messageId = '$turnId-assistant';
    final current = liveConversationMessagesByAgent[agentId] ?? const [];
    final previous = current
        .where((message) => message.id == messageId)
        .firstOrNull;
    final now = DateTime.now().toUtc().toIso8601String();
    liveConversationMessagesByAgent = {
      ...liveConversationMessagesByAgent,
      agentId: List<AgentConversationMessage>.unmodifiable([
        for (final message in current)
          if (message.id != messageId) message,
        AgentConversationMessage(
          id: messageId,
          role: 'assistant',
          text: text,
          createdAt: previous?.createdAt ?? now,
          stableIdentity: messageId,
        ),
      ]),
    };
  }

  Future<void> _handleNativeApprovalNeededEvent({
    required String agentId,
    required AgentDispatchEvent event,
  }) async {
    _setConversationTabActivity(
      agentId,
      AgentConversationTabActivity.needsApproval,
    );
    final summary = (event.payload['displaySummary'] ?? '').toString().trim();
    final pendingOperationId = (event.payload['pendingOperationId'] ?? '')
        .toString()
        .trim();
    final token = (event.payload['adapterCallbackTokenRef'] ?? '')
        .toString()
        .trim();
    final nonce = (event.payload['responseNonce'] ?? '').toString().trim();
    final expiresAt = (event.payload['expiresAt'] ?? '').toString().trim();
    final originEndpointId =
        (event.payload['originEndpointId'] ?? 'local-desktop')
            .toString()
            .trim();
    final tools = <String>[];
    final rawTools = event.payload['requestedTools'];
    if (rawTools is List) {
      for (final tool in rawTools) {
        final name = tool.toString().trim();
        if (name.isNotEmpty) {
          tools.add(name);
        }
      }
    }
    if (pendingOperationId.isNotEmpty && token.isNotEmpty) {
      // Upsert from the stream event so the inbox is visible even when the
      // approval ledger lives in a different native process than list/inbox.
      final request = SecureMeshApprovalRequest(
        pendingOperationId: pendingOperationId,
        requesterAgentId: (event.payload['agentId'] ?? agentId).toString(),
        targetClientId: 'local-desktop',
        originEndpointId: originEndpointId,
        riskLevel: 'local_effect',
        displaySummary: summary.isEmpty ? 'Agent permission request' : summary,
        policyReason: 'ACP session/request_permission',
        expiresAt: expiresAt,
        responseNonce: nonce,
        adapterCallbackTokenRef: token,
        adapterStyle: 'callback',
        requestedTools: List<String>.unmodifiable(tools),
        trustedEndpointCount: 1,
        status: SecureMeshApprovalStatus.pending,
      );
      final next = <SecureMeshApprovalRequest>[
        for (final item in secureMeshApprovalInbox)
          if (item.pendingOperationId != request.pendingOperationId) item,
        request,
      ];
      secureMeshApprovalInbox = List<SecureMeshApprovalRequest>.unmodifiable(
        next.length <= 24 ? next : next.sublist(next.length - 24),
      );
    }
    _setLocalizedStatusMessage(
      summary.isEmpty ? '智能体等待远程审批。' : '智能体等待审批：$summary',
      summary.isEmpty
          ? 'The agent is waiting for remote approval.'
          : 'The agent is waiting for approval: $summary',
    );
    statusCaption = 'Remote approval';
    _notifyStateChanged();
    await refreshSecureMeshApprovalInbox(includeResolved: false);
  }

  void _appendLiveConversationProcessEvent({
    required String agentId,
    required String turnId,
    required AgentDispatchEvent event,
  }) {
    final kind = event.kind.trim();
    if (kind.isEmpty || kind == 'dispatch.turn.started') {
      return;
    }
    final rawText =
        (event.payload['text'] ??
                event.payload['summary'] ??
                event.payload['status'] ??
                kind)
            .toString()
            .trim();
    final current = liveConversationMessagesByAgent[agentId] ?? const [];
    final eventIndex = current
        .where((message) => message.isStructuredEvent)
        .length;
    final messageId = '$turnId-process-$eventIndex';
    final role = kind.contains('error') || kind.contains('failed')
        ? 'error'
        : kind.contains('reason')
        ? 'reasoning'
        : kind.contains('tool') && kind.contains('result')
        ? 'tool_result'
        : kind.contains('tool')
        ? 'tool_call'
        : 'event';
    liveConversationMessagesByAgent = {
      ...liveConversationMessagesByAgent,
      agentId: List<AgentConversationMessage>.unmodifiable([
        ...current,
        AgentConversationMessage(
          id: messageId,
          role: role,
          text: rawText,
          createdAt: DateTime.now().toUtc().toIso8601String(),
          layer: AgentConversationSemanticLayer.execution,
          cardType: role.replaceAll('_', '-'),
          cardTitle: kind,
          stableIdentity: messageId,
        ),
      ]),
    };
  }

  void _clearLiveConversationProjection(String agentId) {
    if (!liveConversationMessagesByAgent.containsKey(agentId)) {
      return;
    }
    liveConversationMessagesByAgent = {
      for (final entry in liveConversationMessagesByAgent.entries)
        if (entry.key != agentId) entry.key: entry.value,
    };
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
      parentSessionId: existing?.parentSessionId ?? '',
      lineageRootId: existing?.lineageRootId ?? '',
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
    _setSelectedConversationSessionIdForAgent(agent.target, session.id);
  }
}
