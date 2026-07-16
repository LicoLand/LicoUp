import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_message_blocks/role_blocks.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_message_blocks/subagent.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_render_adapter.dart';

class AgentConversationMessageBlock extends StatelessWidget {
  const AgentConversationMessageBlock({
    super.key,
    required this.message,
    required this.adapter,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    if (message.isSubagentCard) {
      return AgentConversationSubagentCardBlock(
        message: message,
        adapter: adapter,
      );
    }
    return switch (message.kind) {
      AgentConversationMessageKind.user => AgentConversationUserMessageBlock(
        message: message,
        adapter: adapter,
      ),
      AgentConversationMessageKind.assistant =>
        adapter.assistantLayout == AgentAssistantLayout.bubble
            ? AgentConversationAssistantBubbleBlock(
                message: message,
                adapter: adapter,
              )
            : AgentConversationAssistantDocumentBlock(
                message: message,
                adapter: adapter,
              ),
      AgentConversationMessageKind.toolCall ||
      AgentConversationMessageKind.toolResult ||
      AgentConversationMessageKind.reasoning ||
      AgentConversationMessageKind.metadata ||
      AgentConversationMessageKind.error ||
      AgentConversationMessageKind.event => throw StateError(
        'Structured events must be rendered by the process timeline.',
      ),
      AgentConversationMessageKind.subagent =>
        AgentConversationSubagentCardBlock(message: message, adapter: adapter),
    };
  }
}
