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
/// reasoning or tool execution. They render in a dedicated collapsible card.
final class ConversationLogTimelineItem extends ConversationTimelineItem {
  const ConversationLogTimelineItem(super.storageKey, this.events);

  final List<AgentConversationMessage> events;
}

/// One in-place card describing an agent runtime auto-update (e.g.
/// cursor-agent) blocking the turn. Stands alone: it must not render as a
/// process operation nor as a runtime log card.
final class ConversationRuntimeUpdateTimelineItem
    extends ConversationTimelineItem {
  const ConversationRuntimeUpdateTimelineItem(super.storageKey, this.message);

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
  var pendingEvents = <AgentConversationMessage>[];
  var pendingLogs = <AgentConversationMessage>[];
  var processAnchor = 'session-start';
  var messageIndex = 0;

  // One open blackboard card per live turn. All structured events of the
  // same turn (lifecycle stages + evidence operations) share one timeline
  // item whose storage key is derived from the turn id only, so the card is
  // pinned at its first-seen position and its content grows in place across
  // frames and across interleaved reply messages.
  String? activeTurnKey;
  String openTurnStorageKey = '';
  var openTurnIndex = -1;
  var openTurnEvents = <AgentConversationMessage>[];

  void closeTurnBatch() {
    if (openTurnIndex < 0) return;
    items[openTurnIndex] = ConversationProcessTimelineItem(
      openTurnStorageKey,
      List<AgentConversationMessage>.unmodifiable(openTurnEvents),
    );
    openTurnIndex = -1;
    openTurnEvents = <AgentConversationMessage>[];
    activeTurnKey = null;
  }

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
      if (isConversationRuntimeUpdateEvent(message)) {
        // Own timeline item: close the batches ahead of the card so it never
        // renders inside the process card nor the log rows. The open turn
        // batch itself stays open: the runtime-update card is separate and
        // later evidence still belongs to the same blackboard card.
        flushEvents();
        flushLogs();
        final identity = messageIdentity(message, messageIndex);
        items.add(
          ConversationRuntimeUpdateTimelineItem(
            stableStorageKey(
              'runtime-update',
              identity,
              collisionPosition: messageIndex,
            ),
            message,
          ),
        );
        continue;
      }
      final turnKey = liveTurnKeyOf(message);
      if (turnKey != null) {
        if (activeTurnKey != turnKey) {
          closeTurnBatch();
          flushEvents();
          flushLogs();
          activeTurnKey = turnKey;
          openTurnEvents = <AgentConversationMessage>[message];
          openTurnStorageKey = stableStorageKey(
            'turn-process',
            turnKey,
            collisionPosition: messageIndex,
          );
          openTurnIndex = items.length;
          items.add(
            ConversationProcessTimelineItem(
              openTurnStorageKey,
              List<AgentConversationMessage>.unmodifiable(openTurnEvents),
            ),
          );
        } else {
          openTurnEvents.add(message);
          items[openTurnIndex] = ConversationProcessTimelineItem(
            openTurnStorageKey,
            List<AgentConversationMessage>.unmodifiable(openTurnEvents),
          );
        }
        continue;
      }
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
  closeTurnBatch();
  flushEvents();
  flushLogs();
  return List.unmodifiable(items);
}

/// The live turn key of a structured event: the `turnId` prefix of its stable
/// identity (`live-<agent>-<micros>`). Evidence ids carry a numeric process
/// index suffix (`...-process-3`) that must be stripped before the turn id is
/// recovered; lifecycle ids end in `-lifecycle`. Messages that are not live
/// turn events (readback, other formats) return null and keep the legacy
/// anchor-batched behavior.
String? liveTurnKeyOf(AgentConversationMessage message) {
  if (!message.isStructuredEvent) return null;
  final identity = message.stableIdentity.trim();
  if (!identity.startsWith('live-')) return null;
  var tail = identity;
  final trailingDash = tail.lastIndexOf('-');
  if (trailingDash > 0 &&
      RegExp(r'^\d+$').hasMatch(tail.substring(trailingDash + 1))) {
    tail = tail.substring(0, trailingDash);
  }
  final turnDash = tail.lastIndexOf('-');
  if (turnDash <= 0) return null;
  return tail.substring(0, turnDash);
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
