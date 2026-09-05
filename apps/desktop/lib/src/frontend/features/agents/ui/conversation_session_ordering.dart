import 'package:licoup/src/contracts/agent_conversation_models.dart';

/// Presentation ordering for native history rows. Native identity stays
/// untouched; duplicate adapter rows are collapsed only by native session id.
List<AgentConversationSession> sortConversationSessionsByUpdatedAt(
  Iterable<AgentConversationSession> sessions,
) {
  final byId = <String, AgentConversationSession>{};
  final byNativeId = <String, String>{};
  for (final session in sessions) {
    if (session.id.isEmpty) continue;
    final nativeId = session.nativeSessionId.trim();
    if (nativeId.isNotEmpty) {
      final previousId = byNativeId[nativeId];
      if (previousId != null && previousId != session.id) {
        byId.remove(previousId);
      }
      byNativeId[nativeId] = session.id;
    }
    byId[session.id] = session;
  }
  final ordered = byId.values.toList(growable: false);
  // Precompute one sort key per session: parsing timestamps inside the
  // comparator would cost O(N log N) date parses per sort.
  final sortTimeBySession = <AgentConversationSession, int>{
    for (final session in ordered)
      session: conversationSessionSortTime(session),
  };
  ordered.sort((left, right) {
    final time = sortTimeBySession[right]!.compareTo(sortTimeBySession[left]!);
    return time != 0 ? time : left.id.compareTo(right.id);
  });
  return List<AgentConversationSession>.unmodifiable(ordered);
}

int conversationSessionSortTime(AgentConversationSession session) =>
    (DateTime.tryParse(session.updatedAt) ??
            DateTime.tryParse(session.createdAt) ??
            DateTime.fromMillisecondsSinceEpoch(0))
        .toUtc()
        .millisecondsSinceEpoch;
