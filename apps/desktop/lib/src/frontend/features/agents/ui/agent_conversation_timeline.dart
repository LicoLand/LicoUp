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

/// Provider runtime records that are useful for inspection but are not agent
/// reasoning or tool execution. They intentionally render below the visual
/// hierarchy of a process item.
final class ConversationLogTimelineItem extends ConversationTimelineItem {
  const ConversationLogTimelineItem(super.storageKey, this.events);

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
  var pendingLogs = <AgentConversationMessage>[];
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

  void flushLogs() {
    if (pendingLogs.isEmpty) return;
    items.add(
      ConversationLogTimelineItem(
        stableStorageKey('log', processAnchor, collisionPosition: messageIndex),
        List<AgentConversationMessage>.unmodifiable(pendingLogs),
      ),
    );
    pendingLogs = <AgentConversationMessage>[];
  }

  for (final message in messages) {
    if (message.isStructuredEvent) {
      if (isConversationRuntimeLogEvent(message)) {
        pendingLogs.add(message);
        continue;
      }
      pendingEvents.add(message);
      continue;
    }
    flushEvents();
    flushLogs();
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
  flushLogs();
  return List.unmodifiable(items);
}

bool isConversationRuntimeLogEvent(AgentConversationMessage message) {
  if (message.cardType.trim().toLowerCase() == 'lifecycle') return false;
  return message.kind == AgentConversationMessageKind.event ||
      message.kind == AgentConversationMessageKind.metadata;
}

String stableConversationTimelineIdentity(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}
