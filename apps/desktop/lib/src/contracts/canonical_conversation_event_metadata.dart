import 'dart:convert';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';

/// Fail-safe decoding for typed Canonical Conversation event metadata.
class CanonicalGroupEventMetadataParser {
  const CanonicalGroupEventMetadataParser._();

  static const Set<String> _lifecycleStages = {
    'submitted',
    'accepted',
    'processing',
    'responding',
    'completed',
    'failed',
  };

  static Map<String, dynamic>? eventMetadata(ClientConversationEvent event) {
    for (final part in event.parts) {
      if (part.kind != ConversationEventPartKind.metadata ||
          part.content.trim().isEmpty) {
        continue;
      }
      final decoded = _decodeObject(part.content);
      if (decoded != null) return decoded;
    }
    return null;
  }

  static String? lifecycleStage(ClientConversationEventPart part) {
    if (part.kind != ConversationEventPartKind.metadata) return null;
    final decoded = _decodeObject(part.content);
    if (decoded == null) return null;
    final stage = decoded['lifecycle']?.toString().trim() ?? '';
    return _lifecycleStages.contains(stage) ? stage : null;
  }

  static Map<String, dynamic>? _decodeObject(String content) {
    try {
      final decoded = jsonDecode(content);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on Object {
      return null;
    }
  }
}
