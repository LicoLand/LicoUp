import 'package:licoup/src/application/features/agents/agent_product_names.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

/// Read-only local projection of a reply returned through Secure Mesh.
mixin AgentConversationRelayProjectionController on AgentWorkspaceCoordinator {
  void appendRelayConversationMessages({
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
        id: relayConversationMessageId(agent.target, 'user'),
        role: 'user',
        text: userText,
        createdAt: updatedAt,
      ),
      if (assistantText.trim().isNotEmpty)
        AgentConversationMessage(
          id: relayConversationMessageId(agent.target, 'assistant'),
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
          : agentProductLabel(agent.label),
      createdAt: existing?.createdAt ?? updatedAt,
      updatedAt: updatedAt,
      adapterId: 'mobile-relay-native-projection',
      sourceKind: 'native-mobile-relay',
      sourceClient: relaySourceClientId,
      sourceClientLabel: relaySourceClientLabel,
      native: true,
      readOnly: true,
      messageCount: messages.length,
      messages: List<AgentConversationMessage>.unmodifiable(messages),
    );
    conversationSessionsByAgent = {
      ...conversationSessionsByAgent,
      agent.target: insertConversationSessionByUpdatedAt(
        previous.where((item) => item.id != session.id).toList(growable: false),
        session,
      ),
    };
    setSelectedConversationSessionId(agent.target, session.id);
  }
}
