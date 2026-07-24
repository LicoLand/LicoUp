import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';

const int maxRenderedConversationProcessOperations = 128;
const int maxTraversedConversationProcessNodes = 4096;

final class ConversationProcessProjection {
  const ConversationProcessProjection({
    required this.events,
    required this.renderTruncated,
    required this.totalOperations,
    required this.countTruncated,
    required this.issues,
    required this.startedAt,
    required this.endedAt,
  });

  final List<AgentConversationMessage> events;
  final bool renderTruncated;
  final int totalOperations;
  final bool countTruncated;
  final int issues;
  final DateTime? startedAt;
  final DateTime? endedAt;
}

ConversationProcessProjection projectConversationProcessEvents(
  Iterable<AgentConversationMessage> events,
) {
  final flattened = <AgentConversationMessage>[];
  final pending = events.toList(growable: false).reversed.toList();
  final visited = <AgentConversationMessage>{};
  var totalOperations = 0;
  var issues = 0;
  var traversed = 0;
  var sourceTreeTruncated = false;
  DateTime? startedAt;
  DateTime? endedAt;
  while (pending.isNotEmpty &&
      traversed < maxTraversedConversationProcessNodes) {
    final event = pending.removeLast();
    if (!visited.add(event)) continue;
    traversed += 1;
    if (event.childMessagesTruncated) sourceTreeTruncated = true;
    if (event.isStructuredEvent) {
      totalOperations += 1;
      if (event.kind == AgentConversationMessageKind.error) issues += 1;
      final timestamp = DateTime.tryParse(event.createdAt);
      if (timestamp != null) {
        if (startedAt == null || timestamp.isBefore(startedAt)) {
          startedAt = timestamp;
        }
        if (endedAt == null || timestamp.isAfter(endedAt)) {
          endedAt = timestamp;
        }
      }
      if (flattened.length < maxRenderedConversationProcessOperations) {
        flattened.add(event);
      }
    }
    for (final child in event.childMessages.reversed) {
      pending.add(child);
    }
  }
  return ConversationProcessProjection(
    events: List.unmodifiable(flattened),
    renderTruncated:
        totalOperations > flattened.length ||
        pending.isNotEmpty ||
        sourceTreeTruncated,
    totalOperations: totalOperations,
    countTruncated: pending.isNotEmpty || sourceTreeTruncated,
    issues: issues,
    startedAt: startedAt,
    endedAt: endedAt,
  );
}

List<String> uniqueConversationProcessOperationKeys(
  List<AgentConversationMessage> operations,
) {
  final bases = operations
      .map(
        (message) => message.id.trim().isNotEmpty
            ? message.id.trim()
            : 'projected-${message.stableIdentity.trim().isNotEmpty ? message.stableIdentity.trim() : stableConversationTimelineIdentity('${message.createdAt}|${message.role}|${message.cardType}')}',
      )
      .toList(growable: false);
  final totals = <String, int>{};
  for (final base in bases) {
    totals.update(base, (value) => value + 1, ifAbsent: () => 1);
  }
  return List<String>.generate(bases.length, (index) {
    final base = bases[index];
    if (totals[base] == 1) return base;
    final message = operations[index];
    final identity = message.stableIdentity.trim().isNotEmpty
        ? message.stableIdentity.trim()
        : '${message.createdAt}|${message.role}|${message.cardType}|$index';
    return '$base-${stableConversationTimelineIdentity(identity)}';
  }, growable: false);
}
