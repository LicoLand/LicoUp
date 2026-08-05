import 'dart:async';

import 'package:licoup/src/application/features/agents/conversation/conversation_live_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_relay_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_working_directory_fallback.dart';
import 'package:licoup/src/platform/agents/group_conversation_store.dart';
import 'package:licoup/src/application/features/agents/group_conversation/group_conversation_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

const _releaseConversationAcceptanceMode =
    bool.fromEnvironment('LICO_AGENT_CONVERSATION_RELEASE_LIVE')
    ? 'dispatch-lane-unified-1'
    : '';
const _liveReplyPublishInterval = Duration(milliseconds: 32);

/// Sends one native turn and coordinates only the state transitions around it.
mixin AgentConversationMessageController
    on
        AgentWorkspaceCoordinator,
        AgentOrchestrationPolicyController,
        GroupConversationController,
        AgentConversationSessionController,
        AgentConversationLiveProjectionController,
        AgentConversationRelayProjectionController {
  Future<bool> sendConversationMessage(String text) async {
    var agent = selectedConversationAgent;
    var conversationOwnerAgentId = agent?.target ?? '';
    var participantRole = '';
    final messageText = text.trim();
    if (agent == null || messageText.isEmpty || agentWorkspaceDisposed) {
      return false;
    }
    if (selectedConversationIsOrchestration) {
      await ensureGroupConversationReady();
      conversationOwnerAgentId = agentOrchestrationTargetId;
      final planned = GroupConversationStore.planTurn(
        roster: groupConversationRoster,
        userText: messageText,
      );
      if (planned.isNotEmpty) {
        final dispatcher = planned.first;
        participantRole = dispatcher.role == PlannedTurnRole.dispatcher
            ? 'main-agent'
            : 'peer-agent';
        agent =
            groupConversationTargetFor(dispatcher.agentId) ??
            agentOrchestrationManagerTarget;
      } else {
        participantRole = 'main-agent';
        agent = agentOrchestrationManagerTarget;
      }
      if (agent == null) {
        lastError = 'main_agent_unavailable';
        agentWorkspaceSetLocalizedStatusMessage(
          '请先选择一个可用的主智能体。',
          'Select an available main agent first.',
        );
        statusCaption = 'Main agent';
        agentWorkspaceNotifyStateChanged();
        return false;
      }
    }
    if (!agent.canRelayRuntime) {
      lastError = agent.conversationSendGateReason;
      agentWorkspaceSetLocalizedStatusMessage(
        '${agent.label} could not start sending.',
        '${agent.label} could not start sending (discovery/binding: $lastError).',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return false;
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
    final plannedOrchestrationTurns = selectedConversationIsOrchestration
        ? GroupConversationStore.planTurn(
            roster: groupConversationRoster,
            userText: messageText,
          )
        : const <PlannedAgentTurn>[];
    if (selectedConversationIsOrchestration) {
      for (final plannedTurn in plannedOrchestrationTurns.skip(1)) {
        final peerAgent = groupConversationTargetFor(plannedTurn.agentId);
        if (peerAgent == null || !peerAgent.canRelayRuntime) continue;
        conversationTurnQueue.add(
          _captureConversationTurn(
            agent: peerAgent,
            messageText: messageText,
            session: selectedSession,
            conversationOwnerAgentId: conversationOwnerAgentId,
            participantRole: 'peer-agent',
            modelOverride: _conversationModelForAgent(peerAgent),
            reasoningEffortOverride: _conversationReasoningForAgent(peerAgent),
          ),
        );
      }
    }
    final turn = _captureConversationTurn(
      agent: agent,
      messageText: messageText,
      session: selectedSession,
      conversationOwnerAgentId: conversationOwnerAgentId,
      participantRole: participantRole,
      modelOverride: selectedConversationIsOrchestration
          ? effectiveAgentOrchestrationPolicy.commanderModelName
          : null,
      reasoningEffortOverride: selectedConversationIsOrchestration
          ? effectiveAgentOrchestrationPolicy.commanderReasoningEffort
          : null,
    );
    if (isSendingConversationMessage) {
      await _steerOrEnqueueConversationTurn(turn);
      return ConversationRuntimeResultPolicy.submissionConsumed(lastError);
    }
    await _sendConversationTurn(turn);
    return lastError.isEmpty;
  }

  String _orchestrationConversationWorkingDirectory({
    required TargetCandidate agent,
    AgentConversationSession? session,
  }) {
    final sessionDirectory = session?.workingDirectory.trim() ?? '';
    if (isUsableLocalConversationWorkingDirectory(sessionDirectory)) {
      return sessionDirectory;
    }
    final draftDirectory =
        (newConversationWorkingDirectories[agent.target] ?? '').trim();
    if (isUsableLocalConversationWorkingDirectory(draftDirectory)) {
      return draftDirectory;
    }
    final historicalDirectory = historicalConversationWorkingDirectory(
      conversationSessionsByAgent[agent.target] ?? const [],
    );
    if (historicalDirectory.isNotEmpty) {
      return historicalDirectory;
    }
    final remoteDirectory = agent.remoteWorkingDirectory.trim();
    if (isUsableLocalConversationWorkingDirectory(remoteDirectory)) {
      return remoteDirectory;
    }
    return localConversationWorkingDirectoryFallback(agentId: agent.target);
  }

  ConversationQueuedTurn _captureConversationTurn({
    required TargetCandidate agent,
    required String messageText,
    AgentConversationSession? session,
    required String conversationOwnerAgentId,
    required String participantRole,
    String? modelOverride,
    String? reasoningEffortOverride,
  }) {
    final newConversationDraftToken = newConversationDraftTokenFor(
      conversationOwnerAgentId,
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
    // Keep send-path resolution identical to the composer capsule. For the
    // selected local agent that means session cwd → draft → historical cwd →
    // target → client-owned fallback. Orchestration still resolves against the
    // manager agent because the selected working-directory getter is blank.
    final workingDirectory = selectedConversationIsOrchestration
        ? _orchestrationConversationWorkingDirectory(
            agent: agent,
            session: session,
          )
        : selectedConversationWorkingDirectory;
    final model = (modelOverride ?? '').trim().isNotEmpty
        ? modelOverride!.trim()
        : selectedConversationModel;
    final reasoningEffort = (reasoningEffortOverride ?? '').trim().isNotEmpty
        ? reasoningEffortOverride!.trim()
        : selectedConversationReasoningEffort;
    return ConversationQueuedTurn(
      submissionId: ++conversationTurnSubmissionSequence,
      agent: agent,
      text: messageText,
      session: session,
      nativeSessionId: nativeSessionId,
      workingDirectory: workingDirectory,
      model: model,
      reasoningEffort: reasoningEffort,
      throughMobileRelay: agentWorkspaceMobileRuntime,
      licoProfile: selectedConversationLicoProfile,
      conversationOwnerAgentId: conversationOwnerAgentId,
      participantLabel: agent.label,
      participantRole: participantRole,
      newConversationDraftToken: newConversationDraftToken,
      awaitActiveSession:
          isSendingConversationMessage &&
          sendingConversationAgentId == agent.target &&
          nativeSessionId.isEmpty,
    );
  }

  String _conversationModelForAgent(TargetCandidate agent) {
    final selected = (conversationModelsByAgent[agent.target] ?? '').trim();
    if (selected.isNotEmpty) return selected;
    return (agent.modelCatalog['defaultModel'] ?? '').toString().trim();
  }

  String _conversationReasoningForAgent(TargetCandidate agent) {
    return (conversationReasoningEffortsByAgent[agent.target] ?? '').trim();
  }

  Future<void> _steerOrEnqueueConversationTurn(
    ConversationQueuedTurn turn,
  ) async {
    final activeNativeSessionId = sendingConversationNativeSessionId.trim();
    final activeTurnId = sendingConversationTurnId.trim();
    final canSteer =
        turn.agent.supportsNativeInterruptSteer &&
        turn.agent.target == sendingConversationAgentId &&
        activeNativeSessionId.isNotEmpty &&
        activeTurnId.isNotEmpty &&
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
      turnId: activeTurnId,
      bind: AgentDispatchBind(
        sessionPath: turn.session?.sourcePath ?? '',
        workingDirectory: turn.workingDirectory,
        binaryPath: turn.agent.binaryPath ?? '',
        model: turn.model,
        reasoningEffort: turn.reasoningEffort,
        licoProfile: turn.licoProfile,
        runtimeConnection: turn.agent.runtimeConnection,
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

  /// Explicit, user-consented runtime authorization. The only path that may
  /// open the vendor OAuth flow; a send must never launch it implicitly.
  Future<void> authorizeSelectedConversationRuntime() async {
    final agent = selectedConversationAgent;
    if (agent == null ||
        agentWorkspaceDisposed ||
        isAuthorizingConversationRuntime) {
      return;
    }
    final agentId = agent.target;
    if (conversationSendErrorFor(agentId) != 'antigravity_auth_required') {
      return;
    }
    isAuthorizingConversationRuntime = true;
    agentWorkspaceSetLocalizedStatusMessage(
      '正在打开 ${agent.label} 授权流程，请在浏览器中完成登录。',
      'Opening the ${agent.label} authorization flow. Complete the sign-in in the browser.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyStateChanged();
    try {
      final result = await agentWorkspaceAuthorizeRuntime(
        agentId,
        binaryPath: agent.binaryPath ?? '',
      );
      if (agentWorkspaceDisposed) return;
      final authorized = result['ok'] == true && result['authorized'] == true;
      if (authorized) {
        clearConversationSendError(agentId);
        setConversationTabActivity(agentId, AgentConversationTabActivity.none);
        agentWorkspaceSetLocalizedStatusMessage(
          '${agent.label} 授权完成，请重新发送消息。',
          '${agent.label} authorization completed. Send your message again.',
        );
      } else {
        agentWorkspaceSetLocalizedStatusMessage(
          '${agent.label} 授权未完成，完成登录后重试。',
          '${agent.label} authorization did not complete. Finish the sign-in and try again.',
        );
      }
    } catch (_) {
      if (agentWorkspaceDisposed) return;
      agentWorkspaceSetLocalizedStatusMessage(
        '${agent.label} 授权流程未能完成。',
        'The ${agent.label} authorization flow could not be completed.',
      );
    } finally {
      statusCaption = 'Agent chat';
      if (!agentWorkspaceDisposed) {
        isAuthorizingConversationRuntime = false;
        agentWorkspaceNotifyStateChanged();
      }
    }
  }

  Future<void> _sendConversationTurn(ConversationQueuedTurn queuedTurn) async {
    final agent = queuedTurn.agent;
    final conversationOwnerAgentId =
        queuedTurn.conversationOwnerAgentId.trim().isEmpty
        ? agent.target
        : queuedTurn.conversationOwnerAgentId.trim();
    final orchestrationOwned = isAgentOrchestrationTargetId(
      conversationOwnerAgentId,
    );
    final messageText = queuedTurn.text;
    final selectedSession = queuedTurn.session;
    var completedSuccessfully = false;
    isSendingConversationMessage = true;
    conversationTurnCancellationRequested = false;
    sendingConversationAgentId = agent.target;
    sendingConversationSessionId = selectedSession?.id.trim() ?? '';
    sendingConversationNativeSessionId = queuedTurn.nativeSessionId;
    sendingConversationTurnId = '';
    _discardPendingLiveReply();
    final liveTurnId =
        'live-${agent.target}-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    conversationStartLiveProjection(
      agentId: conversationOwnerAgentId,
      turnId: liveTurnId,
      userText: messageText,
    );
    var lifecycleStage = 'submitted';
    void publishLifecycle(String stage) {
      const stageRank = <String, int>{
        'submitted': 0,
        'accepted': 1,
        'processing': 2,
        'responding': 3,
        'completed': 4,
      };
      if (agentWorkspaceDisposed || lifecycleStage == 'failed') return;
      if (stage == 'failed') {
        lifecycleStage = stage;
      } else {
        final nextRank = stageRank[stage];
        final currentRank = stageRank[lifecycleStage];
        if (nextRank == null ||
            currentRank == null ||
            nextRank <= currentRank) {
          return;
        }
        lifecycleStage = stage;
      }
      conversationUpsertLiveLifecycle(
        agentId: conversationOwnerAgentId,
        turnId: liveTurnId,
        stage: stage,
        participantAgentId: agent.target,
        participantLabel: queuedTurn.participantLabel,
        participantRole: queuedTurn.participantRole,
      );
      agentWorkspaceNotifyLiveConversationChanged();
    }

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
        final streamedTextByParticipant = <String, String>{};
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
            licoProfile: queuedTurn.licoProfile,
            acceptanceMode: _releaseConversationAcceptanceMode,
            runtimeConnection: agent.runtimeConnection,
          ),
        )) {
          if (agentWorkspaceDisposed) return;
          final eventSessionId = event.sessionId.trim();
          final eventTurnId = event.turnId.trim();
          if (eventSessionId.isNotEmpty) {
            sendingConversationNativeSessionId = eventSessionId;
          }
          if (eventTurnId.isNotEmpty) {
            sendingConversationTurnId = eventTurnId;
          }
          if (event.kind == 'dispatch.turn.bound' ||
              event.kind == 'agent.turn.accepted') {
            publishLifecycle('accepted');
            continue;
          }
          if (event.kind == 'agent.turn.processing') {
            publishLifecycle('processing');
            continue;
          }
          if (event.kind.contains('reason') ||
              event.kind.contains('tool') ||
              event.kind.contains('plan')) {
            publishLifecycle('processing');
          }
          if (event.kind == 'agent.message.chunk' ||
              event.kind == 'agent.message.completed') {
            if (event.kind == 'agent.message.chunk') {
              publishLifecycle('responding');
            }
            final chunk = (event.payload['text'] ?? '').toString();
            if (chunk.isNotEmpty) {
              final participantAgentId =
                  (event.payload['participantAgentId'] ?? agent.target)
                      .toString()
                      .trim();
              final participantLabel =
                  (event.payload['participantLabel'] ??
                          queuedTurn.participantLabel)
                      .toString()
                      .trim();
              final participantRole =
                  (event.payload['participantRole'] ??
                          queuedTurn.participantRole)
                      .toString()
                      .trim();
              final participantKey =
                  '$participantAgentId\u0000$participantRole';
              final participantText =
                  ConversationRuntimeResultPolicy.mergeProgressiveText(
                    streamedTextByParticipant[participantKey] ?? '',
                    chunk,
                    completed: event.kind == 'agent.message.completed',
                  );
              streamedTextByParticipant[participantKey] = participantText;
              if (participantAgentId == agent.target) {
                streamedText = participantText;
              }
              final participantTurnId = participantAgentId == agent.target
                  ? liveTurnId
                  : '$liveTurnId-participant-$participantAgentId';
              _queueLiveReplyPublish(
                agentId: conversationOwnerAgentId,
                turnId: participantTurnId,
                text: participantText,
                participantAgentId: participantAgentId,
                participantLabel: participantLabel,
                participantRole: participantRole,
                immediate: event.kind == 'agent.message.completed',
              );
            }
          } else if (event.kind == 'agent.approval.needed') {
            _flushPendingLiveReply();
            await conversationHandleNativeApprovalNeeded(
              agentId: agent.target,
              event: event,
            );
          } else if (event.kind == 'dispatch.turn.completed' ||
              event.kind == 'dispatch.turn.failed') {
            final raw = Map<String, dynamic>.from(event.payload);
            final ok = raw['ok'] == true;
            publishLifecycle(ok ? 'completed' : 'failed');
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
            if (ok && streamedText.trim().isEmpty) {
              final terminalText = (raw['text'] ?? '').toString().trim();
              if (terminalText.isNotEmpty) {
                streamedText = terminalText;
                _queueLiveReplyPublish(
                  agentId: conversationOwnerAgentId,
                  turnId: liveTurnId,
                  text: streamedText,
                  participantAgentId: agent.target,
                  participantLabel: queuedTurn.participantLabel,
                  participantRole: queuedTurn.participantRole,
                  immediate: true,
                );
              }
            }
            if (!ok) {
              // A bounded driver failure must also close the live turn in the
              // transcript; otherwise its process card spins forever.
              final failedTurn = turn;
              final failureText = failedTurn.errorMessage.trim().isNotEmpty
                  ? failedTurn.errorMessage.trim()
                  : failedTurn.failureCode;
              conversationAppendLiveProcessEvent(
                agentId: conversationOwnerAgentId,
                turnId: liveTurnId,
                participantAgentId: agent.target,
                participantLabel: queuedTurn.participantLabel,
                participantRole: queuedTurn.participantRole,
                event: AgentDispatchEvent(
                  kind: 'dispatch.turn.failed',
                  sessionId: event.sessionId,
                  turnId: event.turnId,
                  payload: <String, dynamic>{
                    'text': failedTurn.status.trim().isNotEmpty
                        ? '$failureText (${failedTurn.status.trim()})'
                        : failureText,
                  },
                ),
              );
              agentWorkspaceNotifyLiveConversationChanged();
            }
          } else {
            _flushPendingLiveReply();
            conversationAppendLiveProcessEvent(
              agentId: conversationOwnerAgentId,
              turnId: liveTurnId,
              event: event,
              participantAgentId: agent.target,
              participantLabel: queuedTurn.participantLabel,
              participantRole: queuedTurn.participantRole,
            );
            agentWorkspaceNotifyLiveConversationChanged();
          }
        }
        _flushPendingLiveReply();
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
        publishLifecycle('failed');
        final clientError = ConversationRuntimeResultPolicy.clientError(result);
        lastError = ConversationRuntimeResultPolicy.surfacedFailureCode(result);
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
      publishLifecycle('completed');
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
        final projectionSaved = await conversationCommitTurnBoundNativeReadback(
          agentId: conversationOwnerAgentId,
          nativeSessionId: returnedSessionId,
          messages:
              liveConversationMessagesByAgent[conversationOwnerAgentId] ??
              const [],
          mergeWithSelectedSession: sessionId.isNotEmpty,
          workingDirectory: workingDirectory,
          localSessionId: orchestrationOwned
              ? selectedSession?.id.trim() ?? ''
              : '',
          locallyOwned: orchestrationOwned,
        );
        final committedLocalSessionId = orchestrationOwned
            ? selectedConversationSessionId.trim()
            : '';
        if (!projectionSaved) {
          agentWorkspaceSetLocalizedStatusMessage(
            '消息已发送，但本地会话记录保存失败。',
            'The message was sent, but its local conversation record could not be saved.',
          );
        }
        finishNewConversationDraft(
          conversationOwnerAgentId,
          queuedTurn.newConversationDraftToken,
        );
        if (orchestrationOwned && committedLocalSessionId.isNotEmpty) {
          unawaited(
            reloadDualConversationSessionsAfterSend(
              ownerAgentId: conversationOwnerAgentId,
              localSessionId: committedLocalSessionId,
              nativeAgentId: agent.target,
              nativeSessionId: returnedSessionId,
              nativeAgentLabel: queuedTurn.participantLabel,
            ),
          );
        } else {
          unawaited(
            reloadSelectedConversationSessionsAfterSend(
              agent.target,
              preferredNativeSessionId: returnedSessionId,
            ),
          );
        }
        newConversationWorkingDirectories =
            {...newConversationWorkingDirectories}
              ..remove(agent.target)
              ..remove(conversationOwnerAgentId);
      } else {
        finishNewConversationDraft(
          conversationOwnerAgentId,
          queuedTurn.newConversationDraftToken,
        );
        conversationClearLiveProjection(conversationOwnerAgentId);
      }
      statusCaption = 'Agent chat';
      completedSuccessfully = true;
    } on AgentDispatchStreamException catch (error) {
      publishLifecycle('failed');
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
      publishLifecycle('failed');
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
      _flushPendingLiveReply();
      isSendingConversationMessage = false;
      sendingConversationAgentId = '';
      sendingConversationSessionId = '';
      sendingConversationNativeSessionId = '';
      sendingConversationTurnId = '';
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

  void _queueLiveReplyPublish({
    required String agentId,
    required String turnId,
    required String text,
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
    bool immediate = false,
  }) {
    if (pendingConversationLiveReplyText.isNotEmpty &&
        (pendingConversationLiveReplyAgentId != agentId ||
            pendingConversationLiveReplyTurnId != turnId)) {
      _flushPendingLiveReply();
    }
    pendingConversationLiveReplyAgentId = agentId;
    pendingConversationLiveReplyTurnId = turnId;
    pendingConversationLiveReplyText = text;
    pendingConversationLiveReplyParticipantAgentId = participantAgentId;
    pendingConversationLiveReplyParticipantLabel = participantLabel;
    pendingConversationLiveReplyParticipantRole = participantRole;
    if (immediate) {
      _flushPendingLiveReply();
      return;
    }
    if (conversationLiveReplyPublishTimer != null) return;
    conversationLiveReplyPublishTimer = Timer(_liveReplyPublishInterval, () {
      conversationLiveReplyPublishTimer = null;
      _flushPendingLiveReply();
    });
  }

  void _flushPendingLiveReply() {
    conversationLiveReplyPublishTimer?.cancel();
    conversationLiveReplyPublishTimer = null;
    final agentId = pendingConversationLiveReplyAgentId;
    final turnId = pendingConversationLiveReplyTurnId;
    final text = pendingConversationLiveReplyText;
    final participantAgentId = pendingConversationLiveReplyParticipantAgentId;
    final participantLabel = pendingConversationLiveReplyParticipantLabel;
    final participantRole = pendingConversationLiveReplyParticipantRole;
    _discardPendingLiveReply();
    if (agentWorkspaceDisposed ||
        agentId.isEmpty ||
        turnId.isEmpty ||
        text.isEmpty) {
      return;
    }
    conversationUpsertLiveReply(
      agentId: agentId,
      turnId: turnId,
      text: text,
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    );
    agentWorkspaceNotifyLiveConversationChanged();
  }

  void _discardPendingLiveReply() {
    conversationLiveReplyPublishTimer?.cancel();
    conversationLiveReplyPublishTimer = null;
    pendingConversationLiveReplyAgentId = '';
    pendingConversationLiveReplyTurnId = '';
    pendingConversationLiveReplyText = '';
    pendingConversationLiveReplyParticipantAgentId = '';
    pendingConversationLiveReplyParticipantLabel = '';
    pendingConversationLiveReplyParticipantRole = '';
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
      await _sendConversationTurn(next);
    });
  }

  @override
  String runtimeAdapterFailureCode(Map<String, dynamic> result) {
    return ConversationRuntimeResultPolicy.surfacedFailureCode(result);
  }
}
