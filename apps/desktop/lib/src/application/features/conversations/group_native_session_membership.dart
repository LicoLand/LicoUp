import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';

typedef GroupNativeSessionIdentity = ({String agentId, String nativeSessionId});

/// A group's own history, populated exclusively by exact bound reads.
/// Ordinary Agent browse catalogs are neither an input nor a write destination.
class GroupNativeSessionMembership {
  String conversationId = '';
  int generation = 0;
  bool loading = false;
  Set<GroupNativeSessionIdentity> identities = const {};
  Set<GroupNativeSessionIdentity> failedIdentities = const {};
  final Map<GroupNativeSessionIdentity, AgentConversationSession> _sessions =
      {};
  Map<String, List<AgentConversationSession>> sessionsByAgent = const {};

  void select(String id) {
    if (conversationId == id) {
      return;
    }
    conversationId = id;
    generation++;
    loading = false;
    identities = const {};
    failedIdentities = const {};
    _sessions.clear();
    sessionsByAgent = const {};
  }

  void synchronize(ClientConversation conversation) {
    select(conversation.group ? conversation.id : '');
    final next = <GroupNativeSessionIdentity>{
      if (conversation.group)
        for (final reference in conversation.nativeSessionReferences)
          if (reference.agentId.isNotEmpty &&
              reference.nativeSessionId.isNotEmpty)
            (
              agentId: reference.agentId,
              nativeSessionId: reference.nativeSessionId,
            ),
    };
    if (next.length == identities.length && identities.containsAll(next)) {
      return;
    }
    identities = Set.unmodifiable(next);
    failedIdentities = Set.unmodifiable(failedIdentities.intersection(next));
    generation++;
    loading = false;
    _sessions.removeWhere((identity, _) => !identities.contains(identity));
    _publish();
  }

  Iterable<GroupNativeSessionIdentity> get missing =>
      identities.where((identity) => !_sessions.containsKey(identity));

  AgentConversationSession? resolve(String agentId, String sessionId) {
    final exact = _sessions[(agentId: agentId, nativeSessionId: sessionId)];
    if (exact != null) {
      return exact;
    }
    for (final session
        in sessionsByAgent[agentId] ?? const <AgentConversationSession>[]) {
      if (session.id == sessionId) {
        return session;
      }
    }
    return null;
  }

  bool put(
    int requestGeneration,
    GroupNativeSessionIdentity identity,
    AgentConversationSession session,
  ) {
    if (requestGeneration != generation ||
        !identities.contains(identity) ||
        session.agentId != identity.agentId ||
        session.nativeSessionId != identity.nativeSessionId) {
      return false;
    }
    _sessions[identity] = session;
    failedIdentities = Set.unmodifiable(
      {...failedIdentities}..remove(identity),
    );
    sessionsByAgent = Map.unmodifiable({
      ...sessionsByAgent,
      identity.agentId: List<AgentConversationSession>.unmodifiable(
        insertConversationSessionByUpdatedAt(
          sessionsByAgent[identity.agentId] ?? const [],
          session,
        ),
      ),
    });
    return true;
  }

  void failed(int requestGeneration, GroupNativeSessionIdentity identity) {
    if (requestGeneration == generation && identities.contains(identity)) {
      failedIdentities = Set.unmodifiable({...failedIdentities, identity});
    }
  }

  void _publish() {
    final byAgent = <String, List<AgentConversationSession>>{};
    for (final session in _sessions.values) {
      byAgent.putIfAbsent(session.agentId, () => []).add(session);
    }
    sessionsByAgent = Map.unmodifiable({
      for (final entry in byAgent.entries)
        entry.key: List<AgentConversationSession>.unmodifiable(
          sortConversationSessionsByUpdatedAt(entry.value),
        ),
    });
  }
}
