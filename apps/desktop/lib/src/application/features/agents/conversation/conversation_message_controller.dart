import 'dart:async';

import 'package:licoup/src/application/features/agents/conversation/composer_agent_mention_parsing.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_live_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_relay_projection_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_working_directory_fallback.dart';
import 'package:licoup/src/application/features/agents/conversation/cursor_ide_cli_handoff.dart';
import 'package:licoup/src/application/features/agents/group_conversation/group_conversation_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/platform/agents/group_conversation_store.dart';
import 'package:licoup/src/platform/agents/subagent_handoff_store.dart';
import 'package:licoup/src/platform/agents/agent_conversation_projection_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

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
  final Set<String> _projectedHandoffDispatchIds = <String>{};

  Future<bool> sendConversationMessage(
    String text, {
    List<String> allowedTools = const <String>[],
  }) async {
    // Merge the per-agent remembered allowlist so allow-and-remember tools
    // are auto-approved on every send.
    final remembered = conversationToolAllowlistFor(selectedConversationAgentId);
    if (remembered.isNotEmpty) {
      allowedTools = List<String>.unmodifiable({
        ...allowedTools,
        ...remembered,
      });
    }
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
      final mentionCatalog = <({String id, String label})>[];
      final mentionKeys = <String>{};
      void putMention(String agentId, String label) {
        final id = agentId.trim();
        final resolved = label.trim().isNotEmpty ? label.trim() : id;
        if (id.isEmpty || resolved.isEmpty) return;
        final key = '$id\u0000$resolved';
        if (!mentionKeys.add(key)) return;
        mentionCatalog.add((id: id, label: resolved));
      }

      for (final participant in groupConversationRoster.participants) {
        if (participant.kind != GroupParticipantKind.agent) continue;
        putMention(participant.agentId ?? '', participant.displayName);
      }
      final policy = effectiveAgentOrchestrationPolicy;
      for (final agentId in [
        policy.commanderAgentId,
        ...policy.dailyConversationAgentIds,
        ...policy.codeEngineeringAgentIds,
      ]) {
        final target = groupConversationTargetFor(agentId);
        putMention(agentId, agentId);
        putMention(agentId, target?.label ?? '');
        putMention(agentId, agentProductDisplayName(agentId) ?? '');
        if (target != null) {
          putMention(agentId, agentProductLabel(target.label));
        }
      }
      final mentionedIds = parseComposerAgentMentionIds(
        text: messageText,
        agents: mentionCatalog,
      );
      final planned = mentionedIds.isEmpty
          ? GroupConversationStore.planTurn(
              roster: groupConversationRoster,
              userText: messageText,
            )
          : GroupConversationStore.planTurn(
              roster: groupConversationRoster,
              userText: messageText,
              policy: TurnTakingPolicy.mentionOnly,
              selectedAgentIds: mentionedIds,
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
      // Subagent MCP is required only for the plain-send main agent so it can
      // hand off peers. @mention peer turns receive the user text directly.
      if (mentionedIds.isEmpty) {
        final mcpReady = await _ensureSubagentMcpReadyForSend(agent);
        if (!mcpReady) {
          return false;
        }
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
      final roomBinding = selectedConversationIsOrchestration
          ? groupConversationBindingFor(agent.target)
          : null;
      if (roomBinding == null || !roomBinding.hasResumeHandle) {
        lastError = 'native_session_unresolved';
        agentWorkspaceSetLocalizedStatusMessage(
          'The native ${agent.label} session has not been resolved. Sending is disabled.',
          'The native ${agent.label} session has not been resolved. Sending is disabled.',
        );
        statusCaption = 'Agent chat';
        agentWorkspaceNotifyStateChanged();
        return false;
      }
    }
    final resumeSession = selectedConversationIsOrchestration
        ? _resolveGroupResumeSession(
            dispatcher: agent,
            selectedSession: selectedSession,
          )
        : selectedSession;
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
    final plainSendPolicy = effectiveAgentOrchestrationPolicy;
    final turn = _captureConversationTurn(
      agent: agent,
      messageText: messageText,
      session: resumeSession,
      conversationOwnerAgentId: conversationOwnerAgentId,
      participantRole: participantRole,
      modelOverride: selectedConversationIsOrchestration
          ? plainSendPolicy.plainSendModelName
          : null,
      reasoningEffortOverride: selectedConversationIsOrchestration
          ? plainSendPolicy.plainSendReasoningEffort
          : null,
      allowedTools: allowedTools,
    );
    if (isSendingConversationMessage) {
      await _steerOrEnqueueConversationTurn(turn);
      return ConversationRuntimeResultPolicy.submissionConsumed(lastError);
    }
    await _sendConversationTurn(turn);
    if (selectedConversationIsOrchestration && lastError.isEmpty) {
      unawaited(projectSubagentHandoffPeerBubbles());
    }
    return lastError.isEmpty;
  }

  /// Resend the last permission-denied turn with the denied tool allowed
  /// (`--allowedTools`). When [remember] is true the tool is persisted to the
  /// agent allowlist first, so future sends auto-approve it.
  Future<bool> retryDeniedConversationTurn({bool remember = false}) async {
    final tool = pendingPermissionRetryTool.trim();
    final text = pendingPermissionRetryText.trim();
    final agentId = pendingPermissionRetryAgentId.trim();
    if (tool.isEmpty || text.isEmpty) {
      return false;
    }
    if (remember && agentId.isNotEmpty) {
      rememberConversationToolAllowlist(agentId, tool);
      unawaited(_persistConversationToolAllowlists());
    }
    pendingPermissionRetryAgentId = '';
    pendingPermissionRetryTool = '';
    pendingPermissionRetryText = '';
    agentWorkspaceNotifyStateChanged();
    return sendConversationMessage(text, allowedTools: [tool]);
  }

  /// Dismiss the permission-denied retry card without resending.
  void dismissDeniedConversationTurn() {
    if (pendingPermissionRetryTool.isEmpty) return;
    pendingPermissionRetryAgentId = '';
    pendingPermissionRetryTool = '';
    pendingPermissionRetryText = '';
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> _persistConversationToolAllowlists() async {
    try {
      const store = AgentToolAllowlistStore();
      await store.save(
        agentWorkspacePortableData,
        conversationToolAllowlistsByAgent,
      );
    } on Object {
      // A failed allowlist write must never block a retry.
    }
  }

  /// Prefer the room's last returned main/subagent conversation when the local
  /// orchestration projection has no usable native resume handle yet.
  AgentConversationSession? _resolveGroupResumeSession({
    required TargetCandidate dispatcher,
    required AgentConversationSession? selectedSession,
  }) {
    if (newConversationDraftTokenFor(agentOrchestrationTargetId).isNotEmpty) {
      return selectedSession;
    }
    final selectedNative = selectedSession?.nativeSessionId.trim() ?? '';
    final selectedPath = selectedSession?.sourcePath.trim() ?? '';
    if (selectedNative.isNotEmpty) {
      final binding = groupConversationBindingFor(dispatcher.target);
      if (binding == null ||
          !binding.hasResumeHandle ||
          (binding.nativeSessionId.isNotEmpty &&
              binding.nativeSessionId != selectedNative)) {
        // Selected local group session wins when it already names a native id.
        return selectedSession;
      }
      if (selectedPath.isEmpty && binding.sourcePath.isNotEmpty) {
        return _sessionWithGroupBinding(selectedSession, binding);
      }
      return selectedSession;
    }
    final binding = groupConversationBindingFor(dispatcher.target);
    if (binding == null || !binding.hasResumeHandle) {
      return selectedSession;
    }
    return _sessionWithGroupBinding(selectedSession, binding);
  }

  AgentConversationSession _sessionWithGroupBinding(
    AgentConversationSession? selectedSession,
    GroupAgentSessionBinding binding,
  ) {
    final now = DateTime.now().toUtc().toIso8601String();
    return AgentConversationSession(
      id: selectedSession?.id.trim().isNotEmpty == true
          ? selectedSession!.id
          : (groupConversationLastLocalSessionId.trim().isNotEmpty
                ? groupConversationLastLocalSessionId.trim()
                : 'lico-group-resume'),
      agentId: selectedSession?.agentId.trim().isNotEmpty == true
          ? selectedSession!.agentId
          : agentOrchestrationTargetId,
      title: selectedSession?.title ?? '',
      createdAt: selectedSession?.createdAt ?? now,
      updatedAt: selectedSession?.updatedAt ?? now,
      messages: selectedSession?.messages ?? const [],
      nativeSessionId: binding.nativeSessionId.isNotEmpty
          ? binding.nativeSessionId
          : selectedSession?.nativeSessionId ?? '',
      adapterId: selectedSession?.adapterId ?? 'lico-orchestration',
      sourceKind: selectedSession?.sourceKind ?? 'lico-owned-orchestration',
      sourceClient: selectedSession?.sourceClient ?? 'licoup',
      sourceClientLabel: selectedSession?.sourceClientLabel ?? 'LicoUp',
      sourcePath: binding.sourcePath.isNotEmpty
          ? binding.sourcePath
          : selectedSession?.sourcePath ?? '',
      workingDirectory: binding.workingDirectory.isNotEmpty
          ? binding.workingDirectory
          : selectedSession?.workingDirectory ?? '',
      native: false,
      readOnly: false,
      messageCount: selectedSession?.messageCount ?? 0,
      sourceMessageCount: selectedSession?.sourceMessageCount ?? 0,
    );
  }

  /// Project LicoUp-owned subordinate handoffs into the group mirror as peer
  /// bubbles. MCP tool payloads stay path-only; this reads local handoff state.
  Future<void> projectSubagentHandoffPeerBubbles() async {
    if (!selectedConversationIsOrchestration || agentWorkspaceDisposed) {
      return;
    }
    final portable = agentWorkspacePortableData;
    if (portable is! PortableDataRoot) return;
    final ownerId = agentOrchestrationTargetId.trim();
    if (ownerId.isEmpty) return;
    final handoffs = await SubagentHandoffStore.list(portable);
    var changed = false;
    for (final handoff in handoffs) {
      if (handoff.dispatchId.isEmpty || handoff.agentId.isEmpty) continue;
      final key = '${handoff.dispatchId}\u0000${handoff.state}';
      if (_projectedHandoffDispatchIds.contains(key)) continue;
      if (handoff.state != 'running' &&
          handoff.state != 'completed' &&
          handoff.state != 'failed') {
        continue;
      }
      final peer = groupConversationTargetFor(handoff.agentId);
      final label = (peer?.label.trim().isNotEmpty ?? false)
          ? peer!.label.trim()
          : handoff.agentId;
      var text = switch (handoff.state) {
        'running' => 'Working on LicoUp handoff ${handoff.dispatchId}…',
        'failed' =>
          'LicoUp handoff ${handoff.dispatchId} failed'
              '${handoff.errorCode == null || handoff.errorCode!.isEmpty ? '' : ' (${handoff.errorCode})'}.',
        _ => 'LicoUp handoff ${handoff.dispatchId} finished.',
      };
      final path = handoff.conversationPath?.trim() ?? '';
      var peerNativeSessionId = '';
      var peerWorkingDirectory = '';
      if (path.isNotEmpty &&
          (handoff.state == 'completed' || handoff.state == 'running')) {
        try {
          final sessions = await conversationGateway.loadSessions(
            agentId: handoff.agentId,
            limit: 4,
          );
          for (final session in sessions) {
            if (session.sourcePath.trim() != path) continue;
            peerNativeSessionId = session.nativeSessionId.trim().isNotEmpty
                ? session.nativeSessionId.trim()
                : session.id.trim();
            peerWorkingDirectory = session.workingDirectory.trim();
            if (handoff.state == 'completed') {
              for (final message in session.messages.reversed) {
                if (message.role == 'assistant' &&
                    message.text.trim().isNotEmpty) {
                  text = message.text.trim();
                  break;
                }
              }
            }
            break;
          }
        } catch (_) {
          // Keep the redacted handoff status text.
        }
      }
      if (path.isNotEmpty || peerNativeSessionId.isNotEmpty) {
        unawaited(
          rememberGroupAgentSession(
            agentId: handoff.agentId,
            nativeSessionId: peerNativeSessionId,
            sourcePath: path,
            workingDirectory: peerWorkingDirectory,
          ),
        );
      }
      final mainPath = handoff.mainConversationPath?.trim() ?? '';
      if (mainPath.isNotEmpty && handoff.managerAgentId.trim().isNotEmpty) {
        unawaited(
          rememberGroupAgentSession(
            agentId: handoff.managerAgentId,
            sourcePath: mainPath,
          ),
        );
      }
      conversationUpsertLiveReply(
        agentId: ownerId,
        turnId: 'handoff-${handoff.dispatchId}',
        text: text,
        participantAgentId: handoff.agentId,
        participantLabel: label,
        participantRole: 'peer-agent',
      );
      _projectedHandoffDispatchIds.add(key);
      changed = true;
    }
    if (changed) {
      agentWorkspaceNotifyLiveConversationChanged();
    }
  }

  Future<bool> _ensureSubagentMcpReadyForSend(TargetCandidate agent) async {
    final agentId = agent.target.trim();
    if (agentId.isEmpty) return false;
    final binaryPath = agent.binaryPath?.trim() ?? '';
    try {
      final status = await agentService.subagentMcpStatus(
        agentId: agentId,
        binaryPath: binaryPath.isEmpty ? null : binaryPath,
      );
      if (status['ok'] == true && status['ready'] == true) {
        messagingNotificationCenter.dismiss('subagent-mcp-$agentId');
        return true;
      }
      final state = status['state']?.toString() ?? '';
      if (state == 'unsupported') {
        // Handoffs unavailable; inbound user turns still proceed.
        lastError = '';
        agentWorkspacePublishNotification(
          id: 'subagent-mcp-$agentId',
          messageChinese:
              '主智能体（$agentId）不支持 Subagent MCP，无法通过 handoff 调度同伴；普通发送仍会继续。',
          messageEnglish:
              'Main agent ($agentId) does not support Subagent MCP, so peer handoffs are unavailable; plain send continues.',
          tone: MessagingNotificationTone.warning,
          code: 'subagent_mcp_unsupported',
        );
        statusCaption = 'Subagent MCP';
        agentWorkspaceNotifyStateChanged();
        return true;
      }
      lastError = 'subagent_mcp_required';
      agentWorkspacePublishNotification(
        id: 'subagent-mcp-$agentId',
        messageChinese: '请先为日常对话主智能体（$agentId）安装 Subagent MCP。',
        messageEnglish:
            'Install Subagent MCP for the Daily Conversation main agent ($agentId) first.',
        tone: MessagingNotificationTone.warning,
        code: 'subagent_mcp_required',
      );
    } catch (_) {
      lastError = 'subagent_mcp_required';
      agentWorkspacePublishNotification(
        id: 'subagent-mcp-$agentId',
        messageChinese: '请先为日常对话主智能体（$agentId）安装 Subagent MCP。',
        messageEnglish:
            'Install Subagent MCP for the Daily Conversation main agent ($agentId) first.',
        tone: MessagingNotificationTone.warning,
        code: 'subagent_mcp_required',
      );
    }
    statusCaption = 'Subagent MCP';
    agentWorkspaceNotifyStateChanged();
    return false;
  }

  String _orchestrationConversationWorkingDirectory({
    required TargetCandidate agent,
    AgentConversationSession? session,
  }) {
    // Keep send-path resolution identical to the composer capsule: user bind
    // first, then session provenance, then historical / remote / fallback.
    final draftDirectory =
        (newConversationWorkingDirectories[agent.target] ?? '').trim();
    if (isBoundableConversationWorkingDirectory(draftDirectory)) {
      return draftDirectory;
    }
    final sessionDirectory = session?.workingDirectory.trim() ?? '';
    if (isUsableLocalConversationWorkingDirectory(sessionDirectory)) {
      return sessionDirectory;
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
    List<String> allowedTools = const <String>[],
  }) {
    final newConversationDraftToken = newConversationDraftTokenFor(
      conversationOwnerAgentId,
    );
    final startsNewConversation = newConversationDraftToken.isNotEmpty;
    final ideHandoff =
        !selectedConversationIsOrchestration &&
        shouldInjectCursorIdeCliHandoff(
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
    final selectedNativeSession =
        startsNewConversation || ideHandoff
        ? ''
        : session?.nativeSessionId.trim() ?? '';
    final nativeSessionId = selectedNativeSession.isNotEmpty
        ? selectedNativeSession
        : startsNewConversation || ideHandoff
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
    );
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

  Future<void> _sendConversationTurn(ConversationQueuedTurn initialTurn) async {
    var queuedTurn = initialTurn;
    final conversationOwnerAgentId =
        queuedTurn.conversationOwnerAgentId.trim().isEmpty
        ? queuedTurn.agent.target
        : queuedTurn.conversationOwnerAgentId.trim();
    final orchestrationOwned = isAgentOrchestrationTargetId(
      conversationOwnerAgentId,
    );
    final messageText = queuedTurn.text;
    final selectedSession = queuedTurn.session;
    var completedSuccessfully = false;
    isSendingConversationMessage = true;
    conversationTurnCancellationRequested = false;
    sendingConversationAgentId = queuedTurn.agent.target;
    sendingConversationSessionId = selectedSession?.id.trim() ?? '';
    sendingConversationNativeSessionId = queuedTurn.nativeSessionId;
    sendingConversationTurnId = '';
    _discardPendingLiveReply();
    final liveTurnId =
        'live-${queuedTurn.agent.target}-${DateTime.now().toUtc().microsecondsSinceEpoch}';
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
        participantAgentId: queuedTurn.agent.target,
        participantLabel: queuedTurn.participantLabel,
        participantRole: queuedTurn.participantRole,
      );
      agentWorkspaceNotifyLiveConversationChanged();
    }

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
            // Auto mode: skip native permission prompts so agent turns run
            // without interaction (developer-mandated; approvals are surfaced
            // honestly when the runtime still reports denials).
            permissionMode: 'bypassPermissions',
            allowedTools: queuedTurn.allowedTools,
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
          } else if (event.kind == 'permission.denied') {
            _flushPendingLiveReply();
            final toolName = (event.payload['toolName'] ?? '').toString().trim();
            if (toolName.isNotEmpty) {
              pendingPermissionRetryAgentId = agent.target;
              pendingPermissionRetryTool = toolName;
              pendingPermissionRetryText = queuedTurn.text;
            }
            conversationAppendLiveProcessEvent(
              agentId: conversationOwnerAgentId,
              turnId: liveTurnId,
              event: event,
              participantAgentId: agent.target,
              participantLabel: queuedTurn.participantLabel,
              participantRole: queuedTurn.participantRole,
            );
            agentWorkspaceNotifyLiveConversationChanged();
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
            // Defer lifecycle `failed` until quota fallback is ruled out so a
            // later Daily Conversation capsule can still advance the turn.
            if (ok) {
              publishLifecycle('completed');
            }
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
              // Surface the driver failure in the transcript; the outer loop
              // may still walk Daily Conversation fallback capsules.
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
          } else if (event.kind == 'agent.runtime.updating') {
            // cursor-agent auto-update blocking the turn: one in-place card.
            conversationUpsertLiveRuntimeUpdate(
              agentId: conversationOwnerAgentId,
              turnId: liveTurnId,
              phase: (event.payload['phase'] ?? '').toString(),
              version: (event.payload['version'] ?? '').toString(),
              participantAgentId: agent.target,
              participantLabel: queuedTurn.participantLabel,
              participantRole: queuedTurn.participantRole,
            );
            agentWorkspaceNotifyLiveConversationChanged();
          } else if (event.kind == 'agent.runtime.update.completed') {
            conversationUpsertLiveRuntimeUpdate(
              agentId: conversationOwnerAgentId,
              turnId: liveTurnId,
              version: (event.payload['version'] ?? '').toString(),
              terminal: 'completed',
              participantAgentId: agent.target,
              participantLabel: queuedTurn.participantLabel,
              participantRole: queuedTurn.participantRole,
            );
            agentWorkspaceNotifyLiveConversationChanged();
          } else if (event.kind == 'agent.runtime.update.interrupted') {
            conversationUpsertLiveRuntimeUpdate(
              agentId: conversationOwnerAgentId,
              turnId: liveTurnId,
              version: (event.payload['version'] ?? '').toString(),
              terminal: 'interrupted',
              hint: (event.payload['hint'] ?? '').toString(),
              participantAgentId: agent.target,
              participantLabel: queuedTurn.participantLabel,
              participantRole: queuedTurn.participantRole,
            );
            agentWorkspaceNotifyLiveConversationChanged();
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
          break;
        }
      }
      if (result['ok'] != true) {
        final fallbackTurn = orchestrationOwned
            ? _orchestrationDailyQuotaFallbackTurn(
                failedResult: result,
                failedTurn: queuedTurn,
              )
            : null;
        if (fallbackTurn != null) {
          final fallbackLabel = fallbackTurn.model.trim().isEmpty
              ? fallbackTurn.agent.label
              : '${fallbackTurn.agent.label} · ${fallbackTurn.model.trim()}';
          conversationAppendLiveProcessEvent(
            agentId: conversationOwnerAgentId,
            turnId: liveTurnId,
            participantAgentId: fallbackTurn.agent.target,
            participantLabel: fallbackTurn.participantLabel,
            participantRole: fallbackTurn.participantRole,
            event: AgentDispatchEvent(
              kind: 'dispatch.turn.fallback',
              sessionId: sessionId,
              turnId: sendingConversationTurnId,
              payload: <String, dynamic>{
                'text':
                    'Quota or capacity limit reached; trying $fallbackLabel.',
              },
            ),
          );
          agentWorkspaceNotifyLiveConversationChanged();
          queuedTurn = fallbackTurn;
          lifecycleStage = 'submitted';
          continue;
        }
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
        break;
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
      final handedOffComposerId = queuedTurn.ideHandoffComposerId.trim();
      if (handedOffComposerId.isNotEmpty) {
        cursorIdeCliHandoffComposerIds.add(handedOffComposerId);
      }
      if (queuedTurn.promoteToCurrentConversationOnSuccess) {
        final policy = effectiveAgentOrchestrationPolicy;
        await saveAgentOrchestrationPolicy(
          policy.copyWith(
            commanderAgentId: agent.target,
            commanderModelName: queuedTurn.model,
            commanderReasoningEffort: queuedTurn.reasoningEffort,
          ),
        );
        final fallbackLabel = queuedTurn.model.trim().isEmpty
            ? agent.label
            : '${agent.label} · ${queuedTurn.model.trim()}';
        agentWorkspaceSetLocalizedStatusMessage(
          '额度不足，已切换当前对话到 $fallbackLabel。',
          'Quota exhausted; Current Conversation switched to $fallbackLabel.',
        );
      } else {
        agentWorkspaceSetLocalizedStatusMessage(
          sendThroughMobileRelay
              ? 'Sent the ${agent.label} command through the E2EE mobile relay.'
              : 'Sent the message through the ${agent.label} runtime adapter.',
          sendThroughMobileRelay
              ? 'Sent the ${agent.label} command through the E2EE mobile relay.'
              : 'Sent the message through the ${agent.label} runtime adapter.',
        );
      }

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
          sourcePath: selectedSession?.sourcePath.trim() ?? '',
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
        if (orchestrationOwned) {
          var resumeSourcePath = selectedSession?.sourcePath.trim() ?? '';
          for (final native
              in conversationSessionsByAgent[agent.target] ?? const []) {
            final nativeId = native.nativeSessionId.trim().isNotEmpty
                ? native.nativeSessionId.trim()
                : native.id.trim();
            if (nativeId != returnedSessionId) continue;
            if (native.sourcePath.trim().isNotEmpty) {
              resumeSourcePath = native.sourcePath.trim();
            }
            break;
          }
          unawaited(
            rememberGroupAgentSession(
              agentId: agent.target,
              nativeSessionId: returnedSessionId,
              sourcePath: resumeSourcePath,
              workingDirectory: workingDirectory,
              localOrchestrationSessionId: committedLocalSessionId,
            ),
          );
        }
        if (orchestrationOwned && committedLocalSessionId.isNotEmpty) {
          unawaited(
            reloadDualConversationSessionsAfterSend(
              ownerAgentId: conversationOwnerAgentId,
              localSessionId: committedLocalSessionId,
              nativeAgentId: agent.target,
              nativeSessionId: returnedSessionId,
              nativeAgentLabel: queuedTurn.participantLabel,
            ).then((mirrored) async {
              if (!mirrored || agentWorkspaceDisposed) return;
              final mirroredSession = selectedConversationSession;
              final path = mirroredSession?.sourcePath.trim() ?? '';
              if (path.isEmpty) return;
              await rememberGroupAgentSession(
                agentId: agent.target,
                nativeSessionId: returnedSessionId,
                sourcePath: path,
                workingDirectory: workingDirectory,
                localOrchestrationSessionId: committedLocalSessionId,
              );
            }),
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
      break;
      }
    } on AgentDispatchStreamException catch (error) {
      publishLifecycle('failed');
      lastError = 'native_agent_${error.failureCode}';
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
      publishLifecycle('failed');
      lastError = 'native_agent_transport_failed';
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

  /// Next Daily Conversation capsule after a quota/capacity failure, or null.
  ConversationQueuedTurn? _orchestrationDailyQuotaFallbackTurn({
    required Map<String, dynamic> failedResult,
    required ConversationQueuedTurn failedTurn,
  }) {
    if (!ConversationRuntimeResultPolicy.isQuotaOrCapacityFailure(
      failedResult,
    )) {
      return null;
    }
    final attempted = <String>{
      ...failedTurn.dailyQuotaFallbackAttemptedKeys,
      _dailyQuotaFallbackKey(failedTurn.agent.target, failedTurn.model),
    };
    final policy = effectiveAgentOrchestrationPolicy;
    for (final capsule
        in policy.dailyConversationFallbackCandidatesAfterCurrent()) {
      final key = _dailyQuotaFallbackKey(capsule.agentId, capsule.modelName);
      if (attempted.contains(key)) continue;
      final agent = groupConversationTargetFor(capsule.agentId.trim());
      if (agent == null || !agent.canRelayRuntime) {
        attempted.add(key);
        continue;
      }
      final sameAgent = agent.target == failedTurn.agent.target;
      return ConversationQueuedTurn(
        submissionId: failedTurn.submissionId,
        agent: agent,
        text: failedTurn.text,
        session: failedTurn.session,
        nativeSessionId: sameAgent ? failedTurn.nativeSessionId : '',
        workingDirectory: failedTurn.workingDirectory,
        model: capsule.modelName.trim(),
        reasoningEffort: capsule.reasoningEffort.trim(),
        throughMobileRelay: failedTurn.throughMobileRelay,
        licoProfile: failedTurn.licoProfile,
        conversationOwnerAgentId: failedTurn.conversationOwnerAgentId,
        participantLabel: agent.label,
        participantRole: 'main-agent',
        newConversationDraftToken: failedTurn.newConversationDraftToken,
        awaitActiveSession: false,
        promoteToCurrentConversationOnSuccess: true,
        dailyQuotaFallbackAttemptedKeys: attempted,
      );
    }
    return null;
  }

  static String _dailyQuotaFallbackKey(String agentId, String model) {
    return '${agentId.trim()}\u0000${model.trim()}';
  }
}
