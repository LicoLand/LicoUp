import 'dart:async';

import 'package:flutter_client/src/application/features/agents/conversation/conversation_live_projection_controller.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_relay_projection_controller.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_session_controller.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:flutter_client/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_conversation_tab_activity.dart';
import 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

const _releaseConversationAcceptanceMode =
    bool.fromEnvironment('LICO_AGENT_CONVERSATION_RELEASE_LIVE')
    ? 'dispatch-lane-unified-1'
    : '';

/// Sends one native turn and coordinates only the state transitions around it.
mixin AgentConversationMessageController
    on
        AgentWorkspaceCoordinator,
        AgentConversationSessionController,
        AgentConversationLiveProjectionController,
        AgentConversationRelayProjectionController {
  Future<void> sendConversationMessage(String text) async {
    final agent = selectedConversationAgent;
    final messageText = text.trim();
    if (agent == null || messageText.isEmpty || agentWorkspaceDisposed) {
      return;
    }
    if (!selectedConversationIsOrchestration && !agent.canRelayRuntime) {
      final blocker = agent.conversationBlocker.trim();
      lastError = blocker.isEmpty
          ? 'native_conversation_parity_${agent.conversationReadiness}'
          : blocker;
      agentWorkspaceSetLocalizedStatusMessage(
        '${agent.label} 尚未通过原生对话一致性验收，发送已禁用。',
        '${agent.label} has not passed native conversation parity checks. Sending is disabled.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (selectedConversationIsOrchestration) {
      final turn = _captureConversationTurn(
        agent: agent,
        messageText: messageText,
        orchestration: true,
      );
      if (isSendingConversationMessage) {
        _enqueueConversationTurn(turn);
        return;
      }
      lastError = '';
      await sendOrchestratedConversationMessage(messageText);
      if (lastError.isEmpty && !agentWorkspaceDisposed) {
        _scheduleNextConversationTurn();
      } else {
        conversationTurnQueue.clear();
      }
      return;
    }
    final selectedSession = selectedConversationSession;
    if (selectedSession == null &&
        selectedConversationSessionId.trim().isNotEmpty) {
      lastError = 'native_session_unresolved';
      agentWorkspaceSetLocalizedStatusMessage(
        '${agent.label} 原生会话尚未解析，发送已禁用。',
        'The native ${agent.label} session has not been resolved. Sending is disabled.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (selectedSession != null &&
        selectedSession.nativeSessionId.trim().isEmpty) {
      lastError = 'native_session_id_missing';
      agentWorkspaceSetLocalizedStatusMessage(
        '${agent.label} 历史记录缺少原生会话标识，发送已禁用。',
        'The ${agent.label} history is missing its native session ID. Sending is disabled.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return;
    }
    final turn = _captureConversationTurn(
      agent: agent,
      messageText: messageText,
      session: selectedSession,
    );
    if (isSendingConversationMessage) {
      await _steerOrEnqueueConversationTurn(turn);
      return;
    }
    await _sendConversationTurn(turn);
  }

  ConversationQueuedTurn _captureConversationTurn({
    required TargetCandidate agent,
    required String messageText,
    AgentConversationSession? session,
    bool orchestration = false,
  }) {
    final activeNativeSession = sendingConversationAgentId == agent.target
        ? sendingConversationNativeSessionId.trim()
        : '';
    final selectedNativeSession = session?.nativeSessionId.trim() ?? '';
    final nativeSessionId = selectedNativeSession.isNotEmpty
        ? selectedNativeSession
        : activeNativeSession;
    final workingDirectory = session?.workingDirectory.trim().isNotEmpty == true
        ? session!.workingDirectory.trim()
        : (newConversationWorkingDirectories[agent.target] ?? '').trim();
    return ConversationQueuedTurn(
      submissionId: ++conversationTurnSubmissionSequence,
      agent: agent,
      text: messageText,
      session: session,
      nativeSessionId: nativeSessionId,
      workingDirectory: workingDirectory,
      model: selectedConversationModel,
      reasoningEffort: selectedConversationReasoningEffort,
      throughMobileRelay: agentWorkspaceMobileRuntime,
      orchestration: orchestration,
      awaitActiveSession:
          isSendingConversationMessage &&
          sendingConversationAgentId == agent.target &&
          nativeSessionId.isEmpty,
    );
  }

  Future<void> _steerOrEnqueueConversationTurn(
    ConversationQueuedTurn turn,
  ) async {
    final activeNativeSessionId = sendingConversationNativeSessionId.trim();
    final canSteer =
        turn.agent.supportsNativeInterruptSteer &&
        turn.agent.target == sendingConversationAgentId &&
        activeNativeSessionId.isNotEmpty &&
        turn.nativeSessionId == activeNativeSessionId &&
        !turn.throughMobileRelay;
    if (!canSteer) {
      _enqueueConversationTurn(turn);
      return;
    }
    final result = await conversationGateway.steer(
      agentId: turn.agent.target,
      text: turn.text,
      sessionId: turn.nativeSessionId,
      bind: AgentDispatchBind(
        sessionPath: turn.session?.sourcePath ?? '',
        workingDirectory: turn.workingDirectory,
        binaryPath: turn.agent.binaryPath ?? '',
        model: turn.model,
        reasoningEffort: turn.reasoningEffort,
      ),
    );
    if (agentWorkspaceDisposed) return;
    if (result.ok) {
      agentWorkspaceSetLocalizedStatusMessage(
        '已通过 ${turn.agent.label} 原生通道接入当前回复。',
        'Steered the active ${turn.agent.label} reply through its native channel.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (_steerFailureAllowsQueueFallback(result.errorCode)) {
      _enqueueConversationTurn(turn);
      return;
    }
    lastError = result.errorCode.isEmpty
        ? 'dispatch_steer_outcome_unknown'
        : result.errorCode;
    agentWorkspaceSetLocalizedStatusMessage(
      '原生接入结果不确定，未自动重发以避免重复消息。',
      'The native steer outcome is unknown. The message was not resent to avoid duplication.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyStateChanged();
  }

  bool _steerFailureAllowsQueueFallback(String code) {
    final normalized = code.trim();
    return normalized == 'dispatch_steer_unsupported' ||
        normalized == 'dispatch_steer_transport_unavailable' ||
        normalized == 'dispatch_steer_input_required' ||
        normalized.endsWith('_turn_not_active') ||
        normalized.endsWith('_session_unavailable');
  }

  void _enqueueConversationTurn(ConversationQueuedTurn turn) {
    final result = conversationTurnQueue.add(turn);
    switch (result) {
      case ConversationTurnEnqueueResult.accepted:
        lastError = '';
        agentWorkspaceSetLocalizedStatusMessage(
          '消息已加入待发送队列（${conversationTurnQueue.length}/$maxPendingConversationTurns）。',
          'Message queued (${conversationTurnQueue.length}/$maxPendingConversationTurns).',
        );
        break;
      case ConversationTurnEnqueueResult.full:
        lastError = 'conversation_turn_queue_full';
        agentWorkspaceSetLocalizedStatusMessage(
          '待发送队列已满，请等待当前回复完成。',
          'The pending message queue is full. Wait for the active reply to finish.',
        );
        break;
      case ConversationTurnEnqueueResult.duplicate:
        lastError = 'conversation_turn_duplicate_ignored';
        agentWorkspaceSetLocalizedStatusMessage(
          '重复的待发送消息已忽略。',
          'The duplicate pending message was ignored.',
        );
        break;
    }
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> cancelActiveConversationTurn() async {
    conversationTurnCancellationRequested = true;
    conversationTurnQueue.clear();
    final agentId = sendingConversationAgentId.trim();
    final sessionId = sendingConversationNativeSessionId.trim();
    if (!isSendingConversationMessage || agentId.isEmpty || sessionId.isEmpty) {
      return;
    }
    final result = await conversationGateway.cancel(
      agentId: agentId,
      sessionId: sessionId,
    );
    if (agentWorkspaceDisposed) return;
    if (!result.ok) {
      lastError = result.errorCode.isEmpty
          ? 'dispatch_cancel_failed'
          : result.errorCode;
    }
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> _sendConversationTurn(ConversationQueuedTurn queuedTurn) async {
    final agent = queuedTurn.agent;
    final messageText = queuedTurn.text;
    final selectedSession = queuedTurn.session;
    var completedSuccessfully = false;
    isSendingConversationMessage = true;
    conversationTurnCancellationRequested = false;
    sendingConversationAgentId = agent.target;
    sendingConversationSessionId = selectedSession?.id.trim() ?? '';
    sendingConversationNativeSessionId = queuedTurn.nativeSessionId;
    final liveTurnId =
        'live-${agent.target}-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    conversationStartLiveProjection(
      agentId: agent.target,
      turnId: liveTurnId,
      userText: messageText,
    );
    lastError = '';
    setConversationTabActivity(agent.target, AgentConversationTabActivity.none);
    agentWorkspaceSetLocalizedStatusMessage(
      '正在通过 ${agent.label} 运行时适配器发送消息。',
      'Sending the message through the ${agent.label} runtime adapter.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyActiveConversationChanged();
    agentWorkspaceNotifyStateChanged();
    conversationAttentionContextChanged();
    try {
      final sessionId = queuedTurn.nativeSessionId;
      final workingDirectory = queuedTurn.workingDirectory;
      final sendThroughMobileRelay = queuedTurn.throughMobileRelay;
      late final Map<String, dynamic> result;
      if (sendThroughMobileRelay) {
        result = await mobileConversationGateway.send(
          agentId: agent.target,
          text: messageText,
          sessionId: sessionId,
          model: queuedTurn.model,
          reasoningEffort: queuedTurn.reasoningEffort,
        );
      } else {
        var streamedText = '';
        AgentDispatchTurnResult? turn;
        await for (final event in conversationGateway.sendStreaming(
          agentId: agent.target,
          text: messageText,
          sessionId: sessionId,
          bind: AgentDispatchBind(
            sessionPath: selectedSession?.sourcePath ?? '',
            workingDirectory: workingDirectory,
            binaryPath: agent.binaryPath ?? '',
            model: queuedTurn.model,
            reasoningEffort: queuedTurn.reasoningEffort,
            acceptanceMode: _releaseConversationAcceptanceMode,
          ),
          conversationReadiness: agent.conversationReadiness,
        )) {
          if (agentWorkspaceDisposed) return;
          if (event.kind == 'agent.message.chunk' ||
              event.kind == 'agent.message.completed') {
            final chunk = (event.payload['text'] ?? '').toString();
            if (chunk.isNotEmpty) {
              streamedText =
                  ConversationRuntimeResultPolicy.mergeProgressiveText(
                    streamedText,
                    chunk,
                    completed: event.kind == 'agent.message.completed',
                  );
              conversationUpsertLiveReply(
                agentId: agent.target,
                turnId: liveTurnId,
                text: streamedText,
              );
              agentWorkspaceSetLocalizedStatusMessage(
                '正在接收 ${agent.label} 回复…',
                'Receiving the ${agent.label} reply…',
              );
              statusCaption = streamedText.length > 80
                  ? '${streamedText.substring(0, 80)}…'
                  : streamedText;
              agentWorkspaceNotifyStateChanged();
            }
          } else if (event.kind == 'agent.approval.needed') {
            await conversationHandleNativeApprovalNeeded(
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
            conversationAppendLiveProcessEvent(
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
      if (agentWorkspaceDisposed) return;
      final returnedSessionId = sendThroughMobileRelay
          ? secureAgentRelayNativeSessionId(result)
          : (result['nativeSessionId'] ??
                    result['threadId'] ??
                    result['sessionId'] ??
                    '')
                .toString()
                .trim();
      if (returnedSessionId.isNotEmpty) {
        sendingConversationNativeSessionId = returnedSessionId;
        conversationTurnQueue.bindAwaitingSession(
          agentId: agent.target,
          nativeSessionId: returnedSessionId,
        );
      }
      if (result['ok'] == true) {
        if (returnedSessionId.isEmpty) {
          preparingNewConversation = false;
          if (sessionId.isNotEmpty) {
            conversationMarkNativeSessionPending(agent.target, sessionId);
          } else {
            setSelectedConversationSessionId(
              agent.target,
              conversationSessionLoadFailedSelectionId,
            );
          }
          lastError = 'native_session_id_missing_from_result';
          recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            errorCode: lastError,
          );
          agentWorkspaceSetLocalizedStatusMessage(
            '${agent.label} 未返回原生会话标识，结果已拒绝。',
            '${agent.label} did not return a native session ID. The result was rejected.',
          );
          statusCaption = 'Agent chat';
          return;
        }
        if (sessionId.isNotEmpty && returnedSessionId != sessionId) {
          preparingNewConversation = false;
          setSelectedConversationSessionId(
            agent.target,
            conversationSessionLoadFailedSelectionId,
          );
          lastError = 'native_session_id_mismatch';
          recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            errorCode: lastError,
          );
          agentWorkspaceSetLocalizedStatusMessage(
            '${agent.label} 返回了不同的原生会话，结果已拒绝。',
            '${agent.label} returned a different native session. The result was rejected.',
          );
          statusCaption = 'Agent chat';
          return;
        }
        if (!ConversationRuntimeResultPolicy.effectiveSettingsMatch(
          result,
          throughMobileRelay: sendThroughMobileRelay,
          requestedModel: queuedTurn.model,
          requestedReasoningEffort: queuedTurn.reasoningEffort,
        )) {
          preparingNewConversation = false;
          conversationMarkNativeSessionPending(agent.target, returnedSessionId);
          lastError = 'native_effective_settings_mismatch';
          recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            errorCode: lastError,
          );
          agentWorkspaceSetLocalizedStatusMessage(
            '${agent.label} 未确认请求的原生模型设置，结果已拒绝。',
            '${agent.label} did not confirm the requested native model settings. The result was rejected.',
          );
          statusCaption = 'Agent chat';
          return;
        }
      }
      if (result['ok'] != true) {
        lastError = runtimeAdapterErrorCode(result);
        recordConversationTabSendOutcome(
          agentId: agent.target,
          ok: false,
          result: result,
          errorCode: lastError,
        );
        if (ConversationRuntimeResultPolicy.outcomeMayBeUnknown(lastError)) {
          preparingNewConversation = false;
          if (sessionId.isNotEmpty) {
            conversationMarkNativeSessionPending(agent.target, sessionId);
          } else {
            setSelectedConversationSessionId(
              agent.target,
              conversationSessionLoadFailedSelectionId,
            );
          }
        }
        agentWorkspaceSetLocalizedStatusMessage(
          '${agent.label} 运行时适配器返回失败。',
          'The ${agent.label} runtime adapter returned a failure.',
        );
        statusCaption = 'Agent chat';
        return;
      }
      preparingNewConversation = false;
      if (sendThroughMobileRelay) {
        final receivedAt = DateTime.now().toUtc().toIso8601String();
        appendRelayConversationMessages(
          agent: agent,
          userText: messageText,
          assistantText: secureAgentRelayReplyText(result),
          sessionId: returnedSessionId,
          updatedAt: receivedAt,
        );
      }
      recordConversationTabSendOutcome(agentId: agent.target, ok: true);
      agentWorkspaceSetLocalizedStatusMessage(
        sendThroughMobileRelay
            ? '已通过移动中转端到端加密发送 ${agent.label} 命令。'
            : '已通过 ${agent.label} 运行时适配器发送消息。',
        sendThroughMobileRelay
            ? 'Sent the ${agent.label} command through the E2EE mobile relay.'
            : 'Sent the message through the ${agent.label} runtime adapter.',
      );

      var readbackCompleted = true;
      if (!sendThroughMobileRelay) {
        try {
          await reloadSelectedConversationSessionsAfterSend(
            agent.target,
            preferredNativeSessionId: returnedSessionId,
          );
          readbackCompleted = conversationPendingNativeSessionId(
            agent.target,
          ).isEmpty;
          conversationClearLiveProjection(agent.target);
        } catch (_) {
          readbackCompleted = false;
          lastError = 'native_session_readback_failed';
          agentWorkspaceSetLocalizedStatusMessage(
            '消息已发送，但原生会话回读尚未完成；发送保持禁用。',
            'The message was sent, but native session readback is not complete. Sending remains disabled.',
          );
        }
        newConversationWorkingDirectories = {
          ...newConversationWorkingDirectories,
        }..remove(agent.target);
      } else {
        conversationClearLiveProjection(agent.target);
      }
      statusCaption = 'Agent chat';
      completedSuccessfully = sendThroughMobileRelay || readbackCompleted;
    } catch (_) {
      lastError = 'native_agent_transport_failed';
      recordConversationTabSendOutcome(
        agentId: agent.target,
        ok: false,
        errorCode: lastError,
      );
      agentWorkspaceSetLocalizedStatusMessage(
        '${agent.label} 运行时适配器发送失败。',
        'The ${agent.label} runtime adapter failed to send the message.',
      );
      statusCaption = 'Agent chat';
    } finally {
      isSendingConversationMessage = false;
      sendingConversationAgentId = '';
      sendingConversationSessionId = '';
      sendingConversationNativeSessionId = '';
      if (!agentWorkspaceDisposed) {
        agentWorkspaceNotifyConversationStructureChanged();
        agentWorkspaceNotifyStateChanged();
        conversationAttentionContextChanged();
      }
      if (completedSuccessfully &&
          !conversationTurnCancellationRequested &&
          !agentWorkspaceDisposed) {
        _scheduleNextConversationTurn();
      } else if (!conversationTurnQueue.isEmpty) {
        conversationTurnQueue.clear();
      }
    }
  }

  void _scheduleNextConversationTurn() {
    if (conversationTurnDrainScheduled ||
        conversationTurnQueue.isEmpty ||
        agentWorkspaceDisposed) {
      return;
    }
    conversationTurnDrainScheduled = true;
    scheduleMicrotask(() async {
      conversationTurnDrainScheduled = false;
      if (agentWorkspaceDisposed || isSendingConversationMessage) return;
      final next = conversationTurnQueue.removeFirst();
      if (next == null) return;
      if (next.awaitActiveSession) {
        conversationTurnQueue.clear();
        lastError = 'queued_conversation_session_unresolved';
        agentWorkspaceSetLocalizedStatusMessage(
          '待发送消息无法绑定已完成的原生会话，队列已停止。',
          'A queued message could not bind to the completed native session. The queue was stopped.',
        );
        statusCaption = 'Agent chat';
        agentWorkspaceNotifyStateChanged();
        return;
      }
      if (next.orchestration) {
        lastError = '';
        await sendOrchestratedConversationMessage(next.text);
        if (lastError.isEmpty && !agentWorkspaceDisposed) {
          _scheduleNextConversationTurn();
        } else {
          conversationTurnQueue.clear();
        }
        return;
      }
      await _sendConversationTurn(next);
    });
  }

  @override
  String runtimeAdapterErrorCode(Map<String, dynamic> result) {
    return ConversationRuntimeResultPolicy.errorCode(result);
  }
}
