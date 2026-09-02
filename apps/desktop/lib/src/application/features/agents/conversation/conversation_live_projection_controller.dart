import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_privacy_projection.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

/// Ephemeral message/process projection for an in-flight native turn.
///
/// One [ConversationTurnProcessState] per conversation scope is the blackboard
/// of that conversation's active turn: stream events only advance the state
/// machine, and the live message list is re-derived from the state on every
/// transition. The live messages are part of the owning conversation's message
/// stream; other conversations have no live entries of their own. The
/// frontend card is bound to the turn id, so it stays pinned in the flow and
/// only its content advances.
mixin AgentConversationLiveProjectionController on AgentWorkspaceCoordinator {
  void conversationStartLiveProjection({
    required String scopeKey,
    required String turnId,
    required String userText,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    conversationTurnProcessStateByScope = {
      ...conversationTurnProcessStateByScope,
      scopeKey: ConversationTurnProcessState(
        turnId: turnId,
        userText: userText,
        createdAt: now,
        scopeKey: scopeKey,
      ),
    };
    _projectConversationTurnMessages(scopeKey);
  }

  void conversationUpsertLiveLifecycle({
    required String scopeKey,
    required String turnId,
    required String stage,
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
  }) {
    final normalizedStage = stage.trim().toLowerCase();
    if (normalizedStage.isEmpty) return;
    final state = conversationTurnProcessStateByScope[scopeKey];
    if (state == null || state.turnId != turnId) return;
    state.recordParticipant(
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    );
    state.advanceStage(normalizedStage);
    _projectConversationTurnMessages(scopeKey);
  }

  /// One in-place card per turn describing a cursor-agent auto-update that
  /// blocks the turn (stable id, same position, only text/terminal change).
  void conversationUpsertLiveRuntimeUpdate({
    required String scopeKey,
    required String turnId,
    String phase = '',
    String version = '',
    String terminal = '',
    String hint = '',
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
  }) {
    final state = conversationTurnProcessStateByScope[scopeKey];
    if (state == null || state.turnId != turnId) return;
    final phaseLabel = switch (phase.trim()) {
      'preparing' => '准备中',
      'downloading' => '下载中',
      'installing' => '安装中',
      _ => '',
    };
    final subtitle = switch (terminal.trim()) {
      'completed' => 'Cursor Agent 更新完成${version.isEmpty ? '' : ' · $version'}',
      'interrupted' => 'Cursor Agent 更新中断${hint.isEmpty ? '' : ' · $hint'}',
      _ =>
        'Cursor Agent 正在更新${version.isEmpty ? '' : ' $version'}'
            '${phaseLabel.isEmpty ? '' : ' · $phaseLabel'}',
    };
    final updateMessage = AgentConversationMessage(
      id: '$turnId-runtime-update',
      role: 'event',
      text: terminal.isEmpty ? phase.trim() : terminal.trim(),
      createdAt:
          state.runtimeUpdate?.createdAt ??
          DateTime.now().toUtc().toIso8601String(),
      layer: AgentConversationSemanticLayer.execution,
      cardType: 'runtime-update',
      cardTitle: 'runtime.update',
      cardSubtitle: subtitle,
      stableIdentity: '$turnId-runtime-update',
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    );
    state.setRuntimeUpdate(updateMessage);
    _projectConversationTurnMessages(scopeKey);
  }

  /// Whether the reply landed on the current turn blackboard. False when the
  /// scope has no live turn or the turn id belongs to a replaced turn (a
  /// stale stream event or an old handoff projection); callers must not
  /// report dropped content as projected.
  bool conversationUpsertLiveReply({
    required String scopeKey,
    required String turnId,
    required String text,
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
  }) {
    final state = conversationTurnProcessStateByScope[scopeKey];
    if (state == null) return false;
    final participantKey = state.participantReplyKey(
      turnId: turnId,
      participantAgentId: participantAgentId,
      participantRole: participantRole,
    );
    if (participantKey == null) return false;
    final visibleText = visibleConversationMessageText(
      'assistant',
      text,
      kind: AgentConversationMessageKind.assistant,
      agentId: participantAgentId,
    );
    if (state.isPrimaryReplyKey(participantKey)) {
      state.recordParticipant(
        participantAgentId: participantAgentId,
        participantLabel: participantLabel,
        participantRole: participantRole,
      );
    }
    state.setReplyText(
      visibleText,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      participantKey: participantKey,
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    );
    _projectConversationTurnMessages(scopeKey);
    return true;
  }

  Future<void> conversationHandleNativeApprovalNeeded({
    required String agentId,
    required AgentDispatchEvent event,
  }) async {
    setConversationTabActivity(
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
    agentWorkspaceSetLocalizedStatusMessage(
      summary.isEmpty ? '智能体等待远程审批。' : '智能体等待审批：$summary',
      summary.isEmpty
          ? 'The agent is waiting for remote approval.'
          : 'The agent is waiting for approval: $summary',
    );
    statusCaption = 'Remote approval';
    agentWorkspaceNotifyStateChanged();
    await refreshSecureMeshApprovalInbox(includeResolved: false);
  }

  void conversationAppendLiveProcessEvent({
    required String scopeKey,
    required String turnId,
    required AgentDispatchEvent event,
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
  }) {
    final kind = event.kind.trim();
    if (kind.isEmpty || kind == 'dispatch.turn.started') {
      return;
    }
    final state = conversationTurnProcessStateByScope[scopeKey];
    if (state == null || state.turnId != turnId) return;
    final rawText =
        (event.payload['text'] ??
                event.payload['summary'] ??
                event.payload['status'] ??
                kind)
            .toString()
            .trim();
    final role = kind.contains('error') || kind.contains('failed')
        ? 'error'
        : kind.contains('reason')
        ? 'reasoning'
        : kind.contains('tool') && kind.contains('result')
        ? 'tool_result'
        : kind.contains('tool')
        ? 'tool_call'
        : 'event';
    final messageId = '$turnId-process-${state.evidence.length}';
    state.appendEvidence(
      AgentConversationMessage(
        id: messageId,
        role: role,
        text: rawText,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        layer: AgentConversationSemanticLayer.execution,
        cardType: role.replaceAll('_', '-'),
        cardTitle: kind,
        stableIdentity: messageId,
        participantAgentId:
            (event.payload['participantAgentId'] ?? participantAgentId)
                .toString()
                .trim(),
        participantLabel:
            (event.payload['participantLabel'] ?? participantLabel)
                .toString()
                .trim(),
        participantRole: (event.payload['participantRole'] ?? participantRole)
            .toString()
            .trim(),
      ),
    );
    _projectConversationTurnMessages(scopeKey);
  }

  void conversationClearLiveProjection(String scopeKey) {
    final normalized = scopeKey.trim();
    if (normalized.isEmpty) return;
    conversationTurnProcessStateByScope = {
      for (final entry in conversationTurnProcessStateByScope.entries)
        if (entry.key != normalized) entry.key: entry.value,
    };
    liveConversationMessagesByScope = {
      for (final entry in liveConversationMessagesByScope.entries)
        if (entry.key != normalized) entry.key: entry.value,
    };
  }

  /// Re-derive the live message list from the turn blackboard: user message,
  /// lifecycle stages card, optional runtime-update card, evidence
  /// operations, then the streamed reply. The messages are a projection of
  /// the state, never a second source of truth.
  void _projectConversationTurnMessages(String scopeKey) {
    final state = conversationTurnProcessStateByScope[scopeKey];
    if (state == null) {
      return;
    }
    final messages = <AgentConversationMessage>[
      AgentConversationMessage(
        id: '${state.turnId}-user',
        role: 'user',
        text: state.userText,
        createdAt: state.createdAt,
        stableIdentity: '${state.turnId}-user',
      ),
      AgentConversationMessage(
        id: '${state.turnId}-lifecycle',
        role: state.stage == ConversationTurnProcessStage.failed
            ? 'error'
            : 'event',
        text: state.stage.id,
        createdAt: state.createdAt,
        layer: AgentConversationSemanticLayer.execution,
        cardType: 'lifecycle',
        cardTitle: 'lifecycle.${state.stage.id}',
        cardSubtitle: state.observedStages.join(','),
        stableIdentity: '${state.turnId}-lifecycle',
        participantAgentId: state.participantAgentId,
        participantLabel: state.participantLabel,
        participantRole: state.participantRole,
      ),
    ];
    final runtimeUpdate = state.runtimeUpdate;
    if (runtimeUpdate != null) {
      messages.add(runtimeUpdate);
    }
    messages.addAll(state.evidence);
    // One assistant message per participant: the turn's own participant first
    // (plain `-assistant` identity), then peer replies and handoff bubbles in
    // arrival order, each with a stable per-participant identity.
    for (final reply in state.replies) {
      final primary = state.isPrimaryReplyKey(reply.key);
      final participantIdentity = primary
          ? '${state.turnId}-assistant'
          : '${state.turnId}-assistant-${reply.participantAgentId.trim()}-${reply.participantRole.trim()}';
      messages.add(
        AgentConversationMessage(
          id: participantIdentity,
          role: 'assistant',
          text: reply.text,
          createdAt: reply.createdAt.isEmpty
              ? DateTime.now().toUtc().toIso8601String()
              : reply.createdAt,
          stableIdentity: participantIdentity,
          participantAgentId: reply.participantAgentId,
          participantLabel: reply.participantLabel,
          participantRole: reply.participantRole,
        ),
      );
    }
    liveConversationMessagesByScope = {
      ...liveConversationMessagesByScope,
      scopeKey: List<AgentConversationMessage>.unmodifiable(messages),
    };
  }
}
