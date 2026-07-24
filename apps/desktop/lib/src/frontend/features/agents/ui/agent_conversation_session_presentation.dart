import 'package:licoup/src/contracts/agent_conversation_session.dart';

String conversationSessionRelativeUpdatedAtLabel(
  AgentConversationSession session,
) {
  final rawUpdatedAt = session.updatedAt.trim().isEmpty
      ? session.createdAt.trim()
      : session.updatedAt.trim();
  final updatedAt = DateTime.tryParse(rawUpdatedAt)?.toLocal();
  if (updatedAt == null) {
    return rawUpdatedAt;
  }
  final diff = DateTime.now().difference(updatedAt);
  if (diff.inMinutes < 1) {
    return 'now';
  }
  if (diff.inHours < 1) {
    return '${diff.inMinutes}m';
  }
  if (diff.inDays < 1) {
    return '${diff.inHours}h';
  }
  if (diff.inDays < 7) {
    return '${diff.inDays}d';
  }
  return '${updatedAt.month}/${updatedAt.day}';
}
