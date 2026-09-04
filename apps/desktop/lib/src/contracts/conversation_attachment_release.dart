import 'package:licoup/src/contracts/agent_conversation_attachment.dart';

/// Releases platform-owned attachment resources after Application use.
abstract interface class ConversationAttachmentRelease {
  Future<void> releaseAttachments(Iterable<ConversationAttachment> attachments);
}
