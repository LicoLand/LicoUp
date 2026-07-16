import 'agent_conversation_context_projection.dart';
import 'agent_conversation_message.dart';
import 'agent_conversation_structured_projection.dart';

export 'agent_conversation_context_projection.dart'
    show isInternalConversationRole, visibleAgentConversationTitle;
export 'agent_conversation_structured_projection.dart'
    show
        conversationCardCollapsedByDefault,
        defaultConversationCardSubtitle,
        defaultConversationCardTitle,
        defaultConversationCardType,
        sanitizeStructuredLabel,
        stableConversationIdentity;

String visibleConversationMessageText(
  String role,
  String text, {
  required AgentConversationMessageKind kind,
  String agentId = '',
  String adapterId = '',
  String sourceClient = '',
  String sourceTool = '',
  String hostApp = '',
  bool providerSummary = false,
}) {
  if (structuredConversationMessageKind(kind)) {
    return visibleStructuredConversationText(
      kind,
      text,
      providerSummary: providerSummary,
    );
  }
  return visibleUnstructuredConversationMessageText(
    role,
    text,
    agentId: agentId,
    adapterId: adapterId,
    sourceClient: sourceClient,
    sourceTool: sourceTool,
    hostApp: hostApp,
  );
}
