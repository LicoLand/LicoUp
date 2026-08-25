import 'dart:async';

import 'package:licoup/src/application/features/agents/conversation/conversation_live_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_relay_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_working_directory_fallback.dart';
import 'package:licoup/src/application/features/agents/conversation/cursor_ide_cli_handoff.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
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
  bool _reattachingActiveConversationTurn = false;
  String _persistentTurnHandle = '';
  String _persistentConversationId = '';
  int _persistentTurnCursor = 0;

  void _capturePersistentTurn(AgentDispatchEvent event) {
    final handle = (event.payload['turnHandle'] ?? '').toString().trim();
    final conversationId = (event.payload['conversationId'] ?? '')
        .toString()
        .trim();
    final cursor = event.payload['cursor'];
    if (handle.isNotEmpty) _persistentTurnHandle = handle;
    if (conversationId.isNotEmpty) {
      _persistentConversationId = conversationId;
    }
    if (cursor is int && cursor > _persistentTurnCursor) {
      _persistentTurnCursor = cursor;
    }
  }

  void _clearPersistentTurn() {
    _persistentTurnHandle = '';
    _persistentConversationId = '';
    _persistentTurnCursor = 0;
  }

  @override
  Future<bool> reattachActiveConversationTurn(
    String agentId,
    String sessionId,
  ) async {
    if (_reattachingActiveConversationTurn ||
        isSendingConversationMessage ||
        agentWorkspaceDisposed ||
        agentWorkspaceMobileRuntime ||
        conversationGateway is! PersistentAgentConversationGateway) {
      return false;
    }
    final persistent =
        conversationGateway as PersistentAgentConversationGateway;
    final selected = selectedConversationSession;
    final nativeSessionId = selected?.nativeSessionId.trim() ?? '';
    final scopedSession = nativeSessionId.isNotEmpty
        ? nativeSessionId
        : sessionId.trim();
    late final List<Map<String, dynamic>> active;
    try {
      active = await persistent.activeTurns(
        agentId: agentId,
        sessionId: scopedSession,
      );
    } on Object {
      return false;
    }
    if (active.length != 1 || agentWorkspaceDisposed) return false;
    final turn = active.single;
    final handle = (turn['turnHandle'] ?? '').toString().trim();
    final conversationId = (turn['conversationId'] ?? '').toString().trim();
    if (handle.isEmpty || conversationId.isEmpty) return false;

    _reattachingActiveConversationTurn = true;
    _persistentTurnHandle = handle;
    _persistentConversationId = conversationId;
    _persistentTurnCursor = 0;
    isSendingConversationMessage = true;
    sendingConversationAgentId = agentId;
    sendingConversationSessionId = sessionId;
    sendingConversationNativeSessionId = (turn['sessionId'] ?? scopedSession)
        .toString()
        .trim();
    sendingConversationTurnId = (turn['turnId'] ?? '').toString().trim();
    final scopeKey = conversationComposerScopeKey;
    agentWorkspaceNotifyStateChanged();
    var attached = false;
    try {
      await for (final event in persistent.attachActiveTurn(
        turnHandle: handle,
        conversationId: conversationId,
        afterCursor: _persistentTurnCursor,
      )) {
        attached = true;
        _capturePersistentTurn(event);
        final eventSession = event.sessionId.trim();
        final eventTurn = event.turnId.trim();
        if (eventSession.isNotEmpty) {
          sendingConversationNativeSessionId = eventSession;
        }
        if (eventTurn.isNotEmpty) sendingConversationTurnId = eventTurn;
        conversationApplyDelta(
          scopeKey: scopeKey,
          event: event,
          participantAgentId: agentId,
          participantLabel: selectedConversationAgent?.label ?? agentId,
        );
        final terminal = event.payload['terminalTransition'];
        if (terminal is Map && terminal['kind'] == 'failed') {
          lastError = (terminal['code'] ?? '').toString();
        }
      }
    } on AgentDispatchStreamException {
      // Observer disconnect is detach. The persisted native terminal remains
      // the only failure authority and is recovered by the normal reload.
    } on Object {
      // Same rule for an untyped transport closure: do not invent failure.
    } finally {
      _reattachingActiveConversationTurn = false;
      isSendingConversationMessage = false;
      sendingConversationAgentId = '';
      sendingConversationSessionId = '';
      sendingConversationNativeSessionId = '';
      sendingConversationTurnId = '';
      _clearPersistentTurn();
      agentWorkspaceNotifyStateChanged();
    }
    if (attached && !agentWorkspaceDisposed) {
      await refreshConversationCatalogInternal(agentId, foreground: true);
    }
    return attached;
  }

  Future<bool> sendConversationMessage(
    String text, {
    List<String> allowedTools = const <String>[],
    List<ConversationAttachment>? attachmentOverride,
  }) async {
    // Merge the per-agent remembered allowlist so allow-and-remember tools
    // are auto-approved on every send.
    final remembered = conversationToolAllowlistFor(
      selectedConversationAgentId,
    );
    if (remembered.isNotEmpty) {
      allowedTools = List<String>.unmodifiable({
        ...allowedTools,
        ...remembered,
      });
    }
    final agent = selectedConversationAgent;
    final conversationOwnerAgentId = agent?.target ?? '';
    const participantRole = '';
    final messageText = text.trim();
    final attachments = List<ConversationAttachment>.unmodifiable(
      attachmentOverride ?? conversationComposerAttachments,
    );
    if (agent == null ||
        (messageText.isEmpty && attachments.isEmpty) ||
        agentWorkspaceDisposed) {
      return false;
    }
    if (attachments.isNotEmpty &&
        !selectedConversationSupportsImageAttachments) {
      lastError = 'attachment_transport_unsupported';
      agentWorkspaceSetLocalizedStatusMessage(
        '当前运行时不支持图片附件，未发送消息。',
        'This runtime does not support image attachments, so the message was not sent.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return false;
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
    final resumeSession = selectedSession;
    if (resumeSession != null &&
        resumeSession.nativeSessionId.trim().isEmpty &&
        newConversationDraftTokenFor(conversationOwnerAgentId).isEmpty) {
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
      session: resumeSession,
      conversationOwnerAgentId: conversationOwnerAgentId,
      participantRole: participantRole,
      allowedTools: allowedTools,
      attachments: attachments,
    );
    if (_conversationWorkingDirectoryUnavailable(turn)) {
      lastError = 'conversation_working_directory_unavailable';
      agentWorkspaceSetLocalizedStatusMessage(
        '所选工作目录当前不可用，未发送消息；请重新选择工作空间后再试。',
        'The selected working directory is not usable right now, so the message was not sent. Choose the workspace again.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyStateChanged();
      return false;
    }
    // The message is committed to dispatch: clear only this conversation's
    // composer draft, leaving every other conversation's draft untouched.
    clearConversationComposerDraft();
    if (isSendingConversationMessage) {
      await _steerOrEnqueueConversationTurn(turn);
      return ConversationRuntimeResultPolicy.submissionConsumed(lastError);
    }
    await _sendConversationTurn(turn);
    return lastError.isEmpty;
  }

  /// Resend the last permission-denied turn with the denied tool allowed
  /// (`--allowedTools`). When [remember] is true the tool is persisted to the
  /// agent allowlist first, so future sends auto-approve it.
  Future<bool> retryDeniedConversationTurn({bool remember = false}) async {
    final tool = pendingPermissionRetryTool.trim();
    final text = pendingPermissionRetryText.trim();
    final agentId = pendingPermissionRetryAgentId.trim();
    final attachments = pendingPermissionRetryAttachments;
    if (tool.isEmpty || (text.isEmpty && attachments.isEmpty)) {
      return false;
    }
    if (remember && agentId.isNotEmpty) {
      rememberConversationToolAllowlist(agentId, tool);
      unawaited(_persistConversationToolAllowlists());
    }
    pendingPermissionRetryAgentId = '';
    pendingPermissionRetryTool = '';
    pendingPermissionRetryText = '';
    pendingPermissionRetryAttachments = const [];
    agentWorkspaceNotifyStateChanged();
    return sendConversationMessage(
      text,
      allowedTools: [tool],
      attachmentOverride: attachments,
    );
  }

  /// Dismiss the permission-denied retry card without resending.
  void dismissDeniedConversationTurn() {
    if (pendingPermissionRetryTool.isEmpty) return;
    pendingPermissionRetryAgentId = '';
    pendingPermissionRetryTool = '';
    pendingPermissionRetryText = '';
    pendingPermissionRetryAttachments = const [];
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> _persistConversationToolAllowlists() async {
    try {
      await agentToolAllowlistRepository.save(
        agentWorkspacePortableData,
        conversationToolAllowlistsByAgent,
      );
    } on Object {
      // A failed allowlist write must never block a retry.
    }
  }

  ConversationQueuedTurn _captureConversationTurn({
    required TargetCandidate agent,
    required String messageText,
    AgentConversationSession? session,
    required String conversationOwnerAgentId,
    required String participantRole,
    String? modelOverride,
    String? reasoningEffortOverride,
    List<String> allowedTools = const <String>[],
    List<ConversationAttachment> attachments = const <ConversationAttachment>[],
  }) {
    final newConversationDraftToken = newConversationDraftTokenFor(
      conversationOwnerAgentId,
    );
    final startsNewConversation = newConversationDraftToken.isNotEmpty;
    final ideHandoff = shouldInjectCursorIdeCliHandoff(
      agentId: agent.target,
      session: session,
      handedOffComposerIds: cursorIdeCliHandoffComposerIds,
    );
    final ideHandoffComposerId = ideHandoff
        ? session!.nativeSessionId.trim()
        : '';
    final outboundText = ideHandoff
        ? buildIdeToCliHandoffPrompt(session: session!, userText: messageText)
        : messageText;
    final activeNativeSession = sendingConversationAgentId == agent.target
        ? sendingConversationNativeSessionId.trim()
        : '';
    final selectedNativeSession = startsNewConversation || ideHandoff
        ? ''
        : session?.nativeSessionId.trim() ?? '';
    final nativeSessionId = selectedNativeSession.isNotEmpty
        ? selectedNativeSession
        : startsNewConversation || ideHandoff
        ? ''
        : activeNativeSession;
    // Keep send-path resolution identical to the composer capsule. For the
    // selected local agent that means session cwd → draft → historical cwd →
    // target → client-owned fallback.
    final workingDirectory = selectedConversationWorkingDirectory;
    final explicitlySelectedModel = selectedConversationModel;
    final selectedModel =
        const {'kilo-code', 'opencode'}.contains(agent.target) &&
            explicitlySelectedModel.isEmpty
        ? (agent.modelCatalog['defaultModel'] ?? '').toString().trim()
        : explicitlySelectedModel;
    final model = (modelOverride ?? '').trim().isNotEmpty
        ? modelOverride!.trim()
        : selectedModel;
    final reasoningEffort = (reasoningEffortOverride ?? '').trim().isNotEmpty
        ? reasoningEffortOverride!.trim()
        : selectedConversationReasoningEffort;
    return ConversationQueuedTurn(
      submissionId: ++conversationTurnSubmissionSequence,
      agent: agent,
      text: outboundText,
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
      ideHandoffComposerId: ideHandoffComposerId,
      allowedTools: allowedTools,
      scopeKey: conversationComposerScopeKey,
      attachments: attachments,
    );
  }

  /// Whether the resolved turn working directory cannot be used for the
  /// process start and would silently fall back to a default instead.
  ///
  /// The user's explicit bind is only validated as boundable at pick time, so
  /// a directory that disappeared (or a path the native process cannot see)
  /// would otherwise reach the driver, which silently substitutes the
  /// client-owned `agent-workspace` fallback. Fail the send visibly instead.
  /// Session, historical, remote, and fallback resolution already guarantee a
  /// usable or client-owned directory, so only the explicit bind can trip here.
  bool _conversationWorkingDirectoryUnavailable(ConversationQueuedTurn turn) {
    if (turn.throughMobileRelay ||
        turn.agent.hasValidVirtualMachineConnection) {
      return false;
    }
    final directory = turn.workingDirectory.trim();
    if (directory.isEmpty || isClientOwnedAgentWorkspace(directory)) {
      return false;
    }
    return !isUsableLocalConversationWorkingDirectory(directory);
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
    final canSteerWithoutAttachments = canSteer && turn.attachments.isEmpty;
    if (!canSteerWithoutAttachments) {
      _enqueueConversationTurn(turn);
      return;
    }
    final persistent = conversationGateway is PersistentAgentConversationGateway
        ? conversationGateway as PersistentAgentConversationGateway
        : null;
    final result =
        persistent != null &&
            _persistentTurnHandle.isNotEmpty &&
            _persistentConversationId.isNotEmpty
        ? await persistent.steerActiveTurn(
            turnHandle: _persistentTurnHandle,
            conversationId: _persistentConversationId,
            text: turn.text,
          )
        : await conversationGateway.steer(
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
    if (!isSendingConversationMessage || agentId.isEmpty) {
      return;
    }
    final persistent = conversationGateway is PersistentAgentConversationGateway
        ? conversationGateway as PersistentAgentConversationGateway
        : null;
    final result =
        persistent != null &&
            _persistentTurnHandle.isNotEmpty &&
            _persistentConversationId.isNotEmpty
        ? await persistent.cancelActiveTurn(
            turnHandle: _persistentTurnHandle,
            conversationId: _persistentConversationId,
          )
        : sessionId.isEmpty
        ? const AgentDispatchCancelResult(
            ok: false,
            status: 'unavailable',
            failureCode: 'dispatch_cancel_session_missing',
          )
        : await conversationGateway.cancel(
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

  Future<void> _sendConversationTurn(ConversationQueuedTurn initialTurn) async {
    var queuedTurn = initialTurn;
    final conversationOwnerAgentId =
        queuedTurn.conversationOwnerAgentId.trim().isEmpty
        ? queuedTurn.agent.target
        : queuedTurn.conversationOwnerAgentId.trim();
    final messageText = queuedTurn.text;
    final selectedSession = queuedTurn.session;
    var completedSuccessfully = false;
    isSendingConversationMessage = true;
    conversationTurnCancellationRequested = false;
    sendingConversationAgentId = queuedTurn.agent.target;
    sendingConversationSessionId = selectedSession?.id.trim() ?? '';
    sendingConversationNativeSessionId = queuedTurn.nativeSessionId;
    sendingConversationTurnId = '';
    _clearPersistentTurn();
    var firstTerminalFailureCode = '';

    statusCaption = 'Agent chat';
    agentWorkspaceNotifyActiveConversationChanged();
    agentWorkspaceNotifyStateChanged();
    conversationAttentionContextChanged();
    try {
      while (true) {
        final agent = queuedTurn.agent;
        sendingConversationAgentId = agent.target;
        sendingConversationSessionId = selectedSession?.id.trim() ?? '';
        sendingConversationNativeSessionId = queuedTurn.nativeSessionId;
        sendingConversationTurnId = '';
        _clearPersistentTurn();
        lastError = '';
        setConversationTabActivity(
          agent.target,
          AgentConversationTabActivity.none,
        );
        agentWorkspaceSetLocalizedStatusMessage(
          'Sending the message through the ${agent.label} runtime adapter.',
          'Sending the message through the ${agent.label} runtime adapter.',
        );
        statusCaption = 'Agent chat';
        agentWorkspaceNotifyStateChanged();
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
              // Native permission requests remain interactive. The shared
              // one-shot route resumes the same turn after an explicit user
              // decision; dispatch must never auto-allow them.
              permissionMode: '',
              allowedTools: queuedTurn.allowedTools,
              runtimeConnection: agent.runtimeConnection,
            ),
            attachments: queuedTurn.attachments,
          )) {
            // Closing the UI only detaches its projection. The native host
            // still owns this turn and must keep draining it to completion.
            // Returning here would cancel the Dart subscription and close the
            // transport that carries the already accepted Agent work.
            if (agentWorkspaceDisposed) continue;
            _capturePersistentTurn(event);
            final eventSessionId = event.sessionId.trim();
            final eventTurnId = event.turnId.trim();
            if (eventSessionId.isNotEmpty) {
              sendingConversationNativeSessionId = eventSessionId;
            }
            if (eventTurnId.isNotEmpty) {
              sendingConversationTurnId = eventTurnId;
            }
            conversationApplyDelta(
              scopeKey: queuedTurn.scopeKey,
              event: event,
              participantAgentId: agent.target,
              participantLabel: queuedTurn.participantLabel,
              participantRole: queuedTurn.participantRole,
            );
            final terminalTransition = event.payload['terminalTransition'];
            if (terminalTransition is Map) {
              final terminalKind = (terminalTransition['kind'] ?? '')
                  .toString();
              if (terminalKind == 'failed') {
                final code = (terminalTransition['code'] ?? '')
                    .toString()
                    .trim();
                if (firstTerminalFailureCode.isEmpty && code.isNotEmpty) {
                  firstTerminalFailureCode = code;
                }
              }
            }
            if (event.kind == 'dispatch.turn.bound' ||
                event.kind == 'agent.turn.accepted' ||
                event.kind == 'agent.turn.processing') {
              continue;
            }
            if (event.kind == 'agent.message.chunk' ||
                event.kind == 'agent.message.completed') {
              final chunk = (event.payload['text'] ?? '').toString();
              if (chunk.isNotEmpty) {
                final participantAgentId =
                    (event.payload['participantAgentId'] ?? agent.target)
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
              }
            } else if (event.kind == 'permission.denied') {
              final toolName = (event.payload['toolName'] ?? '')
                  .toString()
                  .trim();
              if (toolName.isNotEmpty) {
                pendingPermissionRetryAgentId = agent.target;
                pendingPermissionRetryTool = toolName;
                pendingPermissionRetryText = queuedTurn.text;
                pendingPermissionRetryAttachments = queuedTurn.attachments;
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
              // Defer lifecycle `failed` until quota fallback is ruled out so a
              // later Daily Conversation capsule can still advance the turn.
              final nested = raw['error'];
              final rawCode = nested is Map
                  ? (nested['code'] ?? '')
                  : (raw['code'] ?? '');
              if (!ok && firstTerminalFailureCode.isEmpty) {
                firstTerminalFailureCode = rawCode.toString().trim();
              }
              turn = AgentDispatchTurnResult(
                ok: ok,
                sessionId: event.sessionId,
                turnId: event.turnId,
                status: (raw['turnStatus'] ?? raw['status'] ?? '').toString(),
                failureCode: ok ? '' : rawCode.toString(),
                errorMessage: ok
                    ? ''
                    : (nested is Map ? (nested['message'] ?? '') : '')
                          .toString(),
                raw: raw,
              );
              if (ok && streamedText.trim().isEmpty) {
                final terminalText = (raw['text'] ?? '').toString().trim();
                if (terminalText.isNotEmpty) {
                  streamedText = terminalText;
                }
              }
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
        if (agentWorkspaceDisposed) {
          // The turn has reached a terminal native result. The disposed UI no
          // longer projects it, but returning here must not reclassify the
          // completed Agent work as a transport failure.
          completedSuccessfully = result['ok'] == true;
          break;
        }
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
            break;
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
            break;
          }
          if (!ConversationRuntimeResultPolicy.effectiveSettingsMatch(
            result,
            throughMobileRelay: sendThroughMobileRelay,
            requestedModel: queuedTurn.model,
            requestedReasoningEffort: queuedTurn.reasoningEffort,
          )) {
            conversationMarkNativeSessionPending(
              agent.target,
              returnedSessionId,
            );
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
            break;
          }
        }
        if (result['ok'] != true) {
          final clientError = ConversationRuntimeResultPolicy.clientError(
            result,
          );
          lastError = ConversationRuntimeResultPolicy.surfacedFailureCode(
            result,
          );
          recordConversationTabSendOutcome(
            agentId: agent.target,
            ok: false,
            result: result,
            failureCode: lastError,
          );
          if (ConversationRuntimeResultPolicy.outcomeMayBeUnknown(
            clientError,
          )) {
            if (sessionId.isNotEmpty) {
              conversationMarkNativeSessionPending(agent.target, sessionId);
            }
          }
          final localized = ClientApplicationStrings.forPreference(
            'system',
          ).conversationClientError(clientError);
          agentWorkspaceSetLocalizedStatusMessage(localized, localized);
          statusCaption = 'Agent chat';
          break;
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
        final handedOffComposerId = queuedTurn.ideHandoffComposerId.trim();
        if (handedOffComposerId.isNotEmpty) {
          cursorIdeCliHandoffComposerIds.add(handedOffComposerId);
        }
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
          final projectionSaved =
              await conversationCommitTurnBoundNativeReadback(
                agentId: conversationOwnerAgentId,
                nativeSessionId: returnedSessionId,
                messages: conversationStateHolder.messagesFor(
                  queuedTurn.scopeKey,
                ),
                mergeWithSelectedSession: sessionId.isNotEmpty,
                workingDirectory: workingDirectory,
                sourcePath: selectedSession?.sourcePath.trim() ?? '',
              );
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
          unawaited(
            reloadSelectedConversationSessionsAfterSend(
              agent.target,
              preferredNativeSessionId: returnedSessionId,
            ),
          );
          newConversationWorkingDirectories =
              {...newConversationWorkingDirectories}
                ..remove(agent.target)
                ..remove(conversationOwnerAgentId);
        } else {
          finishNewConversationDraft(
            conversationOwnerAgentId,
            queuedTurn.newConversationDraftToken,
          );
        }
        statusCaption = 'Agent chat';
        clearConversationComposerAttachmentsForScope(queuedTurn.scopeKey);
        completedSuccessfully = true;
        break;
      }
    } on AgentDispatchStreamException catch (error) {
      lastError = firstTerminalFailureCode.isNotEmpty
          ? firstTerminalFailureCode
          : 'native_agent_${error.failureCode}';
      recordConversationTabSendOutcome(
        agentId: queuedTurn.agent.target,
        ok: false,
        failureCode: lastError,
      );
      agentWorkspaceSetLocalizedStatusMessage(
        'The send did not complete. Your input was preserved.',
        'The send did not complete. Your input was preserved.',
      );
      statusCaption = 'Agent chat';
    } catch (_) {
      lastError = firstTerminalFailureCode.isNotEmpty
          ? firstTerminalFailureCode
          : 'native_agent_transport_failed';
      recordConversationTabSendOutcome(
        agentId: queuedTurn.agent.target,
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
      sendingConversationTurnId = '';
      _clearPersistentTurn();
      if (!agentWorkspaceDisposed) {
        agentWorkspaceNotifyConversationStructureChanged();
        agentWorkspaceNotifyStateChanged();
        conversationAttentionContextChanged();
      }
      if (agentWorkspaceDisposed) {
        // Disposal already cleared the queue; nothing to drain or report.
      } else if (completedSuccessfully ||
          conversationTurnCancellationRequested) {
        // A completed turn drains its follow-ups. A cancelled turn stops only
        // itself: the cancel already cleared the queue, so anything enqueued
        // afterwards is new user intent and must still drain instead of being
        // discarded by the cancelled turn's teardown.
        _scheduleNextConversationTurn();
      } else if (!conversationTurnQueue.isEmpty) {
        // The turn failed. Pending messages cannot keep sending on a session
        // whose last turn did not complete, so the queue is dropped — but
        // never silently: the user must see exactly how many messages were
        // discarded.
        final droppedCount = conversationTurnQueue.length;
        conversationTurnQueue.clear();
        agentWorkspaceSetLocalizedStatusMessage(
          '发送未完成，队列中的 $droppedCount 条消息已丢弃。',
          'The send did not complete. $droppedCount queued '
              '${droppedCount == 1 ? 'message was' : 'messages were'} dropped.',
        );
        statusCaption = 'Agent chat';
        agentWorkspaceNotifyStateChanged();
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
      await _sendConversationTurn(next);
    });
  }

  @override
  String runtimeAdapterFailureCode(Map<String, dynamic> result) {
    return ConversationRuntimeResultPolicy.surfacedFailureCode(result);
  }
}
