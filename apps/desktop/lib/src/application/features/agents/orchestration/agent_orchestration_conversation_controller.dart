import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_dispatch_models.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_presentation.dart';
import 'package:flutter_client/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_flags.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/routing/routing_dispatch_plan.dart';

/// Local orchestration session and streaming message projection.
mixin AgentOrchestrationConversationController
    on
        AgentWorkspaceCoordinator,
        AgentOrchestrationPolicyController,
        AgentOrchestrationPresentation {
  @override
  void ensureOrchestrationConversationSession() {
    if (!kRoutingModuleIncluded || !selectedConversationIsOrchestration) {
      return;
    }
    final existing =
        conversationSessionsByAgent[agentOrchestrationTargetId] ?? const [];
    if (existing.isNotEmpty) {
      selectedConversationSessionId =
          selectedConversationSessionId.trim().isEmpty
          ? existing.first.id
          : selectedConversationSessionId;
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final session = AgentConversationSession(
      id: 'default-orchestration-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      agentId: agentOrchestrationTargetId,
      title: '默认智能体编排',
      createdAt: now,
      updatedAt: now,
      adapterId: 'lico-local-orchestrator',
      sourceKind: 'local-orchestration',
      native: false,
      readOnly: false,
      messageCount: 0,
      messages: const [],
    );
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      agentOrchestrationTargetId: [session],
    };
    selectedConversationSessionId = session.id;
  }

  @override
  String get activeOrchestrationTaskId {
    final selected = selectedConversationSession;
    if (selected?.agentId == agentOrchestrationTargetId) {
      return selected!.id;
    }
    final sessions =
        conversationSessionsByAgent[agentOrchestrationTargetId] ?? const [];
    return sessions.isEmpty ? '' : sessions.first.id;
  }

  String beginOrchestrationConversationTurn(String userText) {
    final turnId =
        'orchestration-turn-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    updateOrchestrationConversation(
      userText: userText,
      update: (messages, now) => [
        ...messages,
        AgentConversationMessage(
          id: '$turnId-user',
          role: 'user',
          text: userText,
          createdAt: now,
        ),
      ],
    );
    return turnId;
  }

  void upsertOrchestrationAssistantReply({
    required String messageId,
    required RoutingDispatchRoute route,
    required String text,
  }) {
    if (text.trim().isEmpty) return;
    updateOrchestrationConversation(
      update: (messages, now) {
        final existing = messages.where((message) => message.id == messageId);
        final createdAt = existing.isEmpty ? now : existing.first.createdAt;
        return [
          for (final message in messages)
            if (message.id != messageId) message,
          AgentConversationMessage(
            id: messageId,
            role: 'assistant',
            text: text,
            createdAt: createdAt,
            cardSubtitle: route.agentLabel,
            stableIdentity: messageId,
          ),
        ];
      },
    );
    agentWorkspaceSetLocalizedStatusMessage(
      '正在接收 ${route.agentLabel} 回复…',
      'Receiving the ${route.agentLabel} reply…',
    );
    statusCaption = text.length > 80 ? '${text.substring(0, 80)}…' : text;
    agentWorkspaceNotifyStateChanged();
  }

  void publishOrchestrationStreamActivity({
    required String turnId,
    required RoutingDispatchRoute route,
    required AgentDispatchEvent event,
  }) {
    final kind = event.kind.trim();
    if (kind.isEmpty || kind == 'dispatch.lane.event') return;
    final messageId = '$turnId-${route.agentId}-activity-$kind';
    updateOrchestrationConversation(
      update: (messages, now) => [
        for (final message in messages)
          if (message.id != messageId) message,
        AgentConversationMessage(
          id: messageId,
          role: 'event',
          text: '${route.agentLabel} · $kind',
          createdAt: now,
          layer: AgentConversationSemanticLayer.execution,
          cardType: 'event',
          cardTitle: route.agentLabel,
          cardSubtitle: kind,
          stableIdentity: messageId,
        ),
      ],
    );
  }

  void appendOrchestrationExecutionStatus({
    required String turnId,
    required RoutingDispatchPlan plan,
    required List<OrchestrationDispatchOutcome> outcomes,
    required List<RoutingDispatchSkip> skipped,
  }) {
    final text = orchestrationStatusMessage(
      plan: plan,
      outcomes: outcomes,
      skipped: skipped,
    );
    updateOrchestrationConversation(
      update: (messages, now) => [
        ...messages,
        AgentConversationMessage(
          id: '$turnId-status',
          role: 'event',
          text: text,
          createdAt: now,
          layer: AgentConversationSemanticLayer.execution,
          cardType: 'event',
          cardTitle: 'Agent orchestration',
          stableIdentity: '$turnId-status',
        ),
      ],
    );
  }

  void updateOrchestrationConversation({
    String userText = '',
    required List<AgentConversationMessage> Function(
      List<AgentConversationMessage> messages,
      String now,
    )
    update,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final previous =
        conversationSessionsByAgent[agentOrchestrationTargetId] ?? const [];
    final selectedSession = preparingNewConversation
        ? null
        : selectedConversationSession;
    final existing = selectedSession?.agentId == agentOrchestrationTargetId
        ? selectedSession
        : previous.isNotEmpty
        ? previous.first
        : null;
    final sessionId =
        existing?.id ??
        'default-orchestration-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final messages = update(existing?.messages ?? const [], now);
    final session = AgentConversationSession(
      id: sessionId,
      nativeSessionId: sessionId,
      agentId: agentOrchestrationTargetId,
      title: orchestrationSessionTitle(userText, existing),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      adapterId: 'lico-local-orchestrator',
      sourceKind: 'local-orchestration',
      native: false,
      readOnly: false,
      messageCount: messages.length,
      messages: List.unmodifiable(messages),
    );
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      agentOrchestrationTargetId: insertConversationSessionByUpdatedAt(
        previous.where((item) => item.id != session.id).toList(growable: false),
        session,
      ),
    };
    selectedConversationSessionId = session.id;
    preparingNewConversation = false;
  }
}
