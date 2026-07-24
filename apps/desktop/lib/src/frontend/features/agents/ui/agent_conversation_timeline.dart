import 'package:licoup/src/contracts/agent_conversation_models.dart';

sealed class ConversationTimelineItem {
  const ConversationTimelineItem(this.storageKey);

  final String storageKey;
}

final class ConversationMessageTimelineItem extends ConversationTimelineItem {
  const ConversationMessageTimelineItem(super.storageKey, this.message);

  final AgentConversationMessage message;
}

final class ConversationProcessTimelineItem extends ConversationTimelineItem {
  const ConversationProcessTimelineItem(super.storageKey, this.events);

  final List<AgentConversationMessage> events;
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
  var pendingEvents = <AgentConversationMessage>[];
  var processAnchor = 'session-start';
  var messageIndex = 0;

  String messageIdentity(AgentConversationMessage message, int sourceIndex) {
    if (message.stableIdentity.trim().isNotEmpty) {
      return message.stableIdentity.trim();
    }
    final immutableIdentity = [
      message.id.trim(),
      message.createdAt,
      message.role,
      message.cardType,
    ].join('|');
    return immutableIdentity.replaceAll('|', '').isNotEmpty
        ? stableConversationTimelineIdentity(immutableIdentity)
        : 'position-$sourceIndex';
  }

  String stableStorageKey(
    String kind,
    String sourceIdentity, {
    int collisionPosition = 0,
  }) {
    final base =
        'conversation-timeline-$kind-${stableConversationTimelineIdentity('$sessionScope|$kind|$sourceIdentity')}';
    if (usedStorageKeys.add(base)) return base;
    final disambiguated =
        '$base-${stableConversationTimelineIdentity('$sourceIdentity|$collisionPosition')}';
    usedStorageKeys.add(disambiguated);
    return disambiguated;
  }

  if (historyTruncated || messageTreeTruncated) {
    items.add(
      ConversationTruncationTimelineItem(
        stableStorageKey('truncation', 'source-boundary'),
        historyTruncated: historyTruncated,
        messageTreeTruncated: messageTreeTruncated,
      ),
    );
  }

  void flushEvents() {
    if (pendingEvents.isEmpty) return;
    items.add(
      ConversationProcessTimelineItem(
        stableStorageKey(
          'process',
          processAnchor,
          collisionPosition: messageIndex,
        ),
        List<AgentConversationMessage>.unmodifiable(pendingEvents),
      ),
    );
    pendingEvents = <AgentConversationMessage>[];
  }

  for (final message in messages) {
    if (message.isStructuredEvent) {
      pendingEvents.add(message);
      continue;
    }
    flushEvents();
    final identity = messageIdentity(message, messageIndex);
    items.add(
      ConversationMessageTimelineItem(
        stableStorageKey('message', identity, collisionPosition: messageIndex),
        message,
      ),
    );
    processAnchor = identity;
    messageIndex += 1;
  }
  flushEvents();
  return List.unmodifiable(items);
}

String stableConversationTimelineIdentity(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}
