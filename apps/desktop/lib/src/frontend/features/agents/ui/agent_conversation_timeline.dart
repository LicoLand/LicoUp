import 'package:licoup/src/contracts/agent_conversation_models.dart';

sealed class ConversationTimelineItem {
  const ConversationTimelineItem(this.storageKey);

  final String storageKey;
}

final class ConversationMessageTimelineItem extends ConversationTimelineItem {
  const ConversationMessageTimelineItem(super.storageKey, this.message);

  final AgentConversationMessage message;
}

/// An actual turn failure remains readable in the conversation. Execution
/// records are inspected through the bubble menu instead of inline cards.
final class ConversationFailureTimelineItem extends ConversationTimelineItem {
  const ConversationFailureTimelineItem(super.storageKey, this.message);

  final AgentConversationMessage message;
}

/// Membership and availability are conversation facts, not execution logs.
final class ConversationNoticeTimelineItem extends ConversationTimelineItem {
  const ConversationNoticeTimelineItem(super.storageKey, this.message);
  final AgentConversationMessage message;
}

final class ConversationTruncationTimelineItem
    extends ConversationTimelineItem {
  const ConversationTruncationTimelineItem(
    super.storageKey, {
    required this.historyTruncated,
    required this.messageTreeTruncated,
  });

  final bool historyTruncated;
  final bool messageTreeTruncated;
}

List<ConversationTimelineItem> buildConversationTimelineItems(
  List<AgentConversationMessage> messages,
  String sessionScope, {
  bool historyTruncated = false,
  bool messageTreeTruncated = false,
}) {
  final items = <ConversationTimelineItem>[];
  final usedStorageKeys = <String>{};
  String storageKey(String kind, String identity, int position) {
    final base =
        'conversation-timeline-$kind-${stableConversationTimelineIdentity('$sessionScope|$kind|$identity')}';
    return usedStorageKeys.add(base) ? base : '$base-$position';
  }

  if (historyTruncated || messageTreeTruncated) {
    items.add(
      ConversationTruncationTimelineItem(
        storageKey('truncation', 'source-boundary', 0),
        historyTruncated: historyTruncated,
        messageTreeTruncated: messageTreeTruncated,
      ),
    );
  }
  for (var index = 0; index < messages.length; index += 1) {
    final message = messages[index];
    if (message.cardType == 'lifecycle') continue;
    final failure = message.kind == AgentConversationMessageKind.error;
    final notice =
        message.cardType == 'membership-changed' ||
        message.cardType == 'availability';
    if (message.isStructuredEvent && !failure && !notice) continue;
    final identity = message.stableIdentity.trim().isNotEmpty
        ? message.stableIdentity.trim()
        : '${message.id}|${message.createdAt}|${message.role}|${message.cardType}';
    final key = storageKey(
      failure
          ? 'failure'
          : notice
          ? 'notice'
          : 'message',
      identity,
      index,
    );
    items.add(
      failure
          ? ConversationFailureTimelineItem(key, message)
          : notice
          ? ConversationNoticeTimelineItem(key, message)
          : ConversationMessageTimelineItem(key, message),
    );
  }
  return List.unmodifiable(items);
}

/// The native turn key of a structured delta projection. Evidence ids carry a
/// numeric process suffix and lifecycle ids carry a lifecycle suffix; both are
/// stripped without requiring a Flutter-fabricated `live-*` identity.
String? liveTurnKeyOf(AgentConversationMessage message) {
  if (!message.isStructuredEvent) return null;
  final identity = message.stableIdentity.trim();
  if (identity.isEmpty) return null;
  if (message.cardType.trim().toLowerCase() == 'lifecycle' &&
      identity.endsWith('-lifecycle')) {
    return identity.substring(0, identity.length - '-lifecycle'.length);
  }
  final process = RegExp(r'^(.*)-process-\d+$').firstMatch(identity);
  if (process != null) return process.group(1);
  return null;
}

bool isConversationRuntimeLogEvent(AgentConversationMessage message) {
  if (message.cardType.trim().toLowerCase() == 'lifecycle') return false;
  return message.kind == AgentConversationMessageKind.event ||
      message.kind == AgentConversationMessageKind.metadata;
}

bool isConversationRuntimeUpdateEvent(AgentConversationMessage message) {
  return message.cardType.trim().toLowerCase() == 'runtime-update';
}

String stableConversationTimelineIdentity(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}
