import 'dart:convert';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';

/// Projection-layer parser for Canonical Conversation event metadata.
///
/// Display-layer widgets must not run `jsonDecode` on event part content;
/// they consume the typed projections produced here. All parsing is
/// fail-safe: malformed or absent metadata yields `null` rather than
/// throwing into the render path.
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

  /// Decode the first well-formed metadata part of [event] into a map, or
  /// return `null` when no metadata part parses to a JSON object.
  static Map<String, dynamic>? eventMetadata(ClientConversationEvent event) {
    for (final part in event.parts) {
      if (part.kind != ConversationEventPartKind.metadata ||
          part.content.trim().isEmpty) {
        continue;
      }
      final decoded = _decodeObject(part.content);
      if (decoded != null) {
        return decoded;
      }
    }
    return null;
  }

  /// Extract a recognized lifecycle stage from a metadata part, or `null`
  /// when the part is not a lifecycle metadata projection.
  static String? lifecycleStage(ClientConversationEventPart part) {
    if (part.kind != ConversationEventPartKind.metadata) {
      return null;
    }
    final decoded = _decodeObject(part.content);
    if (decoded == null) {
      return null;
    }
    final stage = decoded['lifecycle']?.toString().trim() ?? '';
    return _lifecycleStages.contains(stage) ? stage : null;
  }

  static Map<String, dynamic>? _decodeObject(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // fall through
    } on Object {
      // fall through
    }
    return null;
  }
}
