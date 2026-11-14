import 'package:presentation_contract/presentation_contract.dart';

sealed class ConversationEffect {
  const ConversationEffect({this.trace});

  final TraceContext? trace;
}

final class ConversationActionRejected extends ConversationEffect {
  const ConversationActionRejected({
    required this.conversationId,
    required this.stage,
    required this.reasonCode,
    super.trace,
  });

  final String conversationId;
  final String stage;
  final String reasonCode;
}

final class ConversationAttachmentSelectionRejected extends ConversationEffect {
  const ConversationAttachmentSelectionRejected(
    this.conversationId,
    this.reasonCode, {
    super.trace,
  });

  final String conversationId;
  final String reasonCode;
}

final class ConversationAttachmentSelectionRequested
    extends ConversationEffect {
  const ConversationAttachmentSelectionRequested(
    this.conversationId, {
    super.trace,
  });

  final String conversationId;
}

final class CanonicalConversationGroupCreated extends ConversationEffect {
  const CanonicalConversationGroupCreated(this.conversationId, {super.trace});

  final String conversationId;
}

/// Emitted once a conversation-profile persona is registered and its direct
/// canonical Conversation is selected.
final class ConversationProfileCreated extends ConversationEffect {
  const ConversationProfileCreated(this.conversationId, {super.trace});

  final String conversationId;
}
