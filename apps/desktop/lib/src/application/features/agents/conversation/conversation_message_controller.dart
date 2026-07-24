import 'dart:async';

import 'package:licoup/src/application/features/agents/conversation/conversation_live_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_relay_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

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
  Future<bool> sendConversationMessage(String text) async {
    final agent = selectedConversationAgent;
    final messageText = text.trim();
    if (agent == null || messageText.isEmpty || agentWorkspaceDisposed) {
      return false;
    }
    if (!selectedConversationIsOrchestration && !agent.canRelayRuntime) {
      lastError = agent.conversationSendGateReason;
      agentWorkspaceSetLocalizedStatusMessage(
        '${agent.label} could not start sending.',
        '${agent.label} could not start sending (discovery/binding: $lastError).',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return false;
    }
    if (selectedConversationIsOrchestration) {
      final turn = _captureConversationTurn(
        agent: agent,
        messageText: messageText,
        orchestration: true,
      );
      if (isSendingConversationMessage) {
        _enqueueConversationTurn(turn);
        return true;
      }
      lastError = '';
      await sendOrchestratedConversationMessage(messageText);
      if (lastError.isEmpty && !agentWorkspaceDisposed) {
        _scheduleNextConversationTurn();
      } else {
        conversationTurnQueue.clear();
      }
      return lastError.isEmpty;
    }
    final selectedSession = selectedConversationSession;
    if (selectedSession == null &&
        selectedNewConversationDraftToken.isEmpty &&
        selectedConversationSessionId.trim().isNotEmpty) {
      lastError = 'native_session_unresolved';
      agentWorkspaceSetLocalizedStatusMessage(
        'The native ${agent.label} session has not been resolved. Sending is disabled.',
        'The native ${agent.label} session has not been resolved. Sending is disabled.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return false;
    }
    if (selectedSession != null &&
        selectedSession.nativeSessionId.trim().isEmpty) {
      lastError = 'native_session_id_missing';
      agentWorkspaceSetLocalizedStatusMessage(
        'The ${agent.label} history is missing its native session ID. Sending is disabled.',
        'The ${agent.label} history is missing its native session ID. Sending is disabled.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return false;
    }
    final turn = _captureConversationTurn(
      agent: agent,
      messageText: messageText,
      session: selectedSession,
    );
    if (isSendingConversationMessage) {
      await _steerOrEnqueueConversationTurn(turn);
      return ConversationRuntimeResultPolicy.submissionConsumed(lastError);
    }
    await _sendConversationTurn(turn);
    return lastError.isEmpty;
  }

  ConversationQueuedTurn _captureConversationTurn({
    required TargetCandidate agent,
    required String messageText,
    AgentConversationSession? session,
    bool orchestration = false,
  }) {
    final newConversationDraftToken = newConversationDraftTokenFor(
      agent.target,
    );
    final startsNewConversation = newConversationDraftToken.isNotEmpty;
    final activeNativeSession = sendingConversationAgentId == agent.target
        ? sendingConversationNativeSessionId.trim()
        : '';
    final selectedNativeSession = startsNewConversation
        ? ''
        : session?.nativeSessionId.trim() ?? '';
    final nativeSessionId = selectedNativeSession.isNotEmpty
        ? selectedNativeSession
        : startsNewConversation
        ? ''
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
      newConversationDraftToken: newConversationDraftToken,
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
        'Steered the active ${turn.agent.label} reply through its native channel.',
        'Steered the active ${turn.agent.label} reply through its native channel.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (_steerFailureAllowsQueueFallback(result.failureCode)) {
      _enqueueConversationTurn(turn);
      return;
    }
    lastError = result.failureCode.isEmpty
        ? 'dispatch_steer_outcome_unknown'
        : result.failureCode;
    agentWorkspaceSetLocalizedStatusMessage(
      'The native steer outcome is unknown. The message was not resent to avoid duplication.',
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
          'Message queued (${conversationTurnQueue.length}/$maxPendingConversationTurns).',
          'Message queued (${conversationTurnQueue.length}/$maxPendingConversationTurns).',
        );
        break;
      case ConversationTurnEnqueueResult.full:
        lastError = 'conversation_turn_queue_full';
        agentWorkspaceSetLocalizedStatusMessage(
          'The pending message queue is full. Wait for the active reply to finish.',
          'The pending message queue is full. Wait for the active reply to finish.',
        );
        break;
      case ConversationTurnEnqueueResult.duplicate:
        lastError = 'conversation_turn_duplicate_ignored';
        agentWorkspaceSetLocalizedStatusMessage(
          'The duplicate pending message was ignored.',
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
      lastError = result.failureCode.isEmpty
          ? 'dispatch_cancel_failed'
          : result.failureCode;
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
      'Sending the message through the ${agent.label} runtime adapter.',
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
                'Receiving the ${agent.label} reply…',
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
              failureCode: ok ? '' : rawCode.toString(),
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
                      failureCode: 'dispatch_stream_incomplete',
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
          if (sessionId.isNotEmpty) {
            conversationMarkNativeSessionPending(agent.target, sessionId);
          }
          lastError = 'native_session_id_missing_from_result';
          recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            failureCode: lastError,
          );
          agentWorkspaceSetLocalizedStatusMessage(
            '${agent.label} did not return a native session ID. The result was rejected.',
            '${agent.label} did not return a native session ID. The result was rejected.',
          );
          statusCaption = 'Agent chat';
          return;
        }
        if (sessionId.isNotEmpty && returnedSessionId != sessionId) {
          setSelectedConversationSessionId(
            agent.target,
            conversationSessionLoadFailedSelectionId,
          );
          lastError = 'native_session_id_mismatch';
          recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            failureCode: lastError,
          );
          agentWorkspaceSetLocalizedStatusMessage(
            '${agent.label} returned a different native session. The result was rejected.',
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
          conversationMarkNativeSessionPending(agent.target, returnedSessionId);
          lastError = 'native_effective_settings_mismatch';
          recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            failureCode: lastError,
          );
          agentWorkspaceSetLocalizedStatusMessage(
            '${agent.label} did not confirm the requested native model settings. The result was rejected.',
            '${agent.label} did not confirm the requested native model settings. The result was rejected.',
          );
          statusCaption = 'Agent chat';
          return;
        }
      }
      if (result['ok'] != true) {
        final clientError = ConversationRuntimeResultPolicy.clientError(result);
        lastError = clientError.code.wireName;
        recordConversationTabSendOutcome(
          agentId: agent.target,
          ok: false,
          result: result,
          failureCode: lastError,
        );
        if (ConversationRuntimeResultPolicy.outcomeMayBeUnknown(clientError)) {
          if (sessionId.isNotEmpty) {
            conversationMarkNativeSessionPending(agent.target, sessionId);
          }
        }
        final localized = ClientApplicationStrings.forPreference(
          'system',
        ).conversationClientError(clientError);
        agentWorkspaceSetLocalizedStatusMessage(localized, localized);
        statusCaption = 'Agent chat';
        return;
      }
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
            ? 'Sent the ${agent.label} command through the E2EE mobile relay.'
            : 'Sent the message through the ${agent.label} runtime adapter.',
        sendThroughMobileRelay
            ? 'Sent the ${agent.label} command through the E2EE mobile relay.'
            : 'Sent the message through the ${agent.label} runtime adapter.',
      );

      if (!sendThroughMobileRelay) {
        // The streamed turn is authoritative for immediate interaction. Keep
        // it selected and usable, then reconcile provider history in the
        // background once the runtime has finished persisting its transcript.
        conversationCommitTurnBoundNativeReadback(
          agentId: agent.target,
          nativeSessionId: returnedSessionId,
          messages: liveConversationMessagesByAgent[agent.target] ?? const [],
          mergeWithSelectedSession: sessionId.isNotEmpty,
        );
        finishNewConversationDraft(
          agent.target,
          queuedTurn.newConversationDraftToken,
        );
        unawaited(
          reloadSelectedConversationSessionsAfterSend(
            agent.target,
            preferredNativeSessionId: returnedSessionId,
          ),
        );
        newConversationWorkingDirectories = {
          ...newConversationWorkingDirectories,
        }..remove(agent.target);
      } else {
        finishNewConversationDraft(
          agent.target,
          queuedTurn.newConversationDraftToken,
        );
        conversationClearLiveProjection(agent.target);
      }
      statusCaption = 'Agent chat';
      completedSuccessfully = true;
    } on AgentDispatchStreamException catch (error) {
      lastError = 'native_agent_${error.failureCode}';
      recordConversationTabSendOutcome(
        agentId: agent.target,
        ok: false,
        failureCode: lastError,
      );
      agentWorkspaceSetLocalizedStatusMessage(
        'The send did not complete. Your input was preserved.',
        'The send did not complete. Your input was preserved.',
      );
      statusCaption = 'Agent chat';
    } catch (_) {
      lastError = 'native_agent_transport_failed';
      recordConversationTabSendOutcome(
        agentId: agent.target,
        ok: false,
        failureCode: lastError,
      );
      agentWorkspaceSetLocalizedStatusMessage(
        'The send did not complete. Your input was preserved.',
        'The send did not complete. Your input was preserved.',
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
          'A queued message could not bind to the completed native session. The queue was stopped.',
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
  String runtimeAdapterFailureCode(Map<String, dynamic> result) {
    return ConversationRuntimeResultPolicy.clientError(result).code.wireName;
  }
}
