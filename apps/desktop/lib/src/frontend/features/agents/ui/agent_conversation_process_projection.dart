import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';

final class ConversationProcessProjection {
  const ConversationProcessProjection({
    required this.events,
    required this.totalOperations,
    required this.issues,
    required this.startedAt,
    required this.endedAt,
  });

  final List<AgentConversationMessage> events;
  final int totalOperations;
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
  DateTime? startedAt;
  DateTime? endedAt;
  while (pending.isNotEmpty) {
    final event = pending.removeLast();
    if (!visited.add(event)) continue;
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
      flattened.add(event);
    }
    for (final child in event.childMessages.reversed) {
      pending.add(child);
    }
  }
  return ConversationProcessProjection(
    events: List.unmodifiable(flattened),
    totalOperations: totalOperations,
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
