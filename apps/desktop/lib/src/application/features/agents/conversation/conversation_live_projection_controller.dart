import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_privacy_projection.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

/// Ephemeral message/process projection for an in-flight native turn.
mixin AgentConversationLiveProjectionController on AgentWorkspaceCoordinator {
  void conversationStartLiveProjection({
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
        AgentConversationMessage(
          id: '$turnId-lifecycle',
          role: 'event',
          text: 'submitted',
          createdAt: now,
          layer: AgentConversationSemanticLayer.execution,
          cardType: 'lifecycle',
          cardTitle: 'lifecycle.submitted',
          cardSubtitle: 'submitted',
          stableIdentity: '$turnId-lifecycle',
        ),
      ]),
    };
  }

  void conversationUpsertLiveLifecycle({
    required String agentId,
    required String turnId,
    required String stage,
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
  }) {
    final normalizedStage = stage.trim().toLowerCase();
    if (normalizedStage.isEmpty) return;
    final messageId = '$turnId-lifecycle';
    final current = liveConversationMessagesByAgent[agentId] ?? const [];
    final previous = current
        .where((message) => message.id == messageId)
        .firstOrNull;
    const orderedStages = [
      'submitted',
      'accepted',
      'processing',
      'responding',
      'completed',
    ];
    final observedStages =
        previous?.cardSubtitle
            .split(',')
            .map((value) => value.trim())
            .where(orderedStages.contains)
            .toSet() ??
        <String>{};
    if (orderedStages.contains(normalizedStage)) {
      observedStages.add(normalizedStage);
    }
    final lifecycleMessage = AgentConversationMessage(
      id: messageId,
      role: normalizedStage == 'failed' ? 'error' : 'event',
      text: normalizedStage,
      createdAt:
          previous?.createdAt ?? DateTime.now().toUtc().toIso8601String(),
      layer: AgentConversationSemanticLayer.execution,
      cardType: 'lifecycle',
      cardTitle: 'lifecycle.$normalizedStage',
      cardSubtitle: orderedStages.where(observedStages.contains).join(','),
      stableIdentity: messageId,
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    );
    liveConversationMessagesByAgent = {
      ...liveConversationMessagesByAgent,
      agentId: List<AgentConversationMessage>.unmodifiable([
        if (previous == null) ...current,
        if (previous == null) lifecycleMessage,
        if (previous != null)
          for (final message in current)
            if (message.id == messageId) lifecycleMessage else message,
      ]),
    };
  }

  void conversationUpsertLiveReply({
    required String agentId,
    required String turnId,
    required String text,
    String participantAgentId = '',
    String participantLabel = '',
    String participantRole = '',
  }) {
    final messageId = '$turnId-assistant';
    final current = liveConversationMessagesByAgent[agentId] ?? const [];
    final previous = current
        .where((message) => message.id == messageId)
        .firstOrNull;
    final now = DateTime.now().toUtc().toIso8601String();
    final visibleText = visibleConversationMessageText(
      'assistant',
      text,
      kind: AgentConversationMessageKind.assistant,
      agentId: participantAgentId,
    );
    if (visibleText.isEmpty) {
      liveConversationMessagesByAgent = {
        ...liveConversationMessagesByAgent,
        agentId: List<AgentConversationMessage>.unmodifiable([
          for (final message in current)
            if (message.id != messageId) message,
        ]),
      };
      return;
    }
    liveConversationMessagesByAgent = {
      ...liveConversationMessagesByAgent,
      agentId: List<AgentConversationMessage>.unmodifiable([
        for (final message in current)
          if (message.id != messageId) message,
        AgentConversationMessage(
          id: messageId,
          role: 'assistant',
          text: visibleText,
          createdAt: previous?.createdAt ?? now,
          stableIdentity: messageId,
          participantAgentId: participantAgentId,
          participantLabel: participantLabel,
          participantRole: participantRole,
        ),
      ]),
    };
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
    required String agentId,
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
      ]),
    };
  }

  void conversationClearLiveProjection(String agentId) {
    if (!liveConversationMessagesByAgent.containsKey(agentId)) {
      return;
    }
    liveConversationMessagesByAgent = {
      for (final entry in liveConversationMessagesByAgent.entries)
        if (entry.key != agentId) entry.key: entry.value,
    };
  }
}
