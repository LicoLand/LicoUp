import 'package:licoup/src/contracts/agent_conversation_projection_repository.dart';
import 'package:licoup/src/contracts/agent_conversation_session.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';

final class PlatformAgentConversationProjectionStore
    implements AgentConversationProjectionRepository {
  const PlatformAgentConversationProjectionStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'agent-conversation-projections.json';
  static const _schemaVersion = 1;
  static const _maxAgents = 32;
  static const _maxSessionsPerAgent = 100;
  static const _maxMessagesPerSession = 200;

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<Map<String, List<AgentConversationSession>>> load(
    Object portableData,
  ) async {
    final decoded = await _jsonStore.read(portableData, _fileName);
    if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
      return const {};
    }
    final rawSessions = decoded['sessionsByAgent'];
    if (rawSessions is! Map) return const {};

    final restored = <String, List<AgentConversationSession>>{};
    for (final entry in rawSessions.entries.take(_maxAgents)) {
      final agentId = entry.key.toString().trim();
      if (agentId.isEmpty || agentId.length > 128 || entry.value is! List) {
        continue;
      }
      final sessions = <AgentConversationSession>[];
      for (final item in (entry.value as List).take(_maxSessionsPerAgent)) {
        if (item is! Map) continue;
        try {
          final session = AgentConversationSession.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (session.id.trim().isNotEmpty &&
              session.agentId.trim() == agentId) {
            sessions.add(session);
          }
        } on Object {
          // A malformed local record must not block the remaining projections.
        }
      }
      if (sessions.isNotEmpty) {
        restored[agentId] = List.unmodifiable(sessions);
      }
    }
    return Map.unmodifiable(restored);
  }

  @override
  Future<void> save(
    Object portableData,
    Map<String, List<AgentConversationSession>> sessionsByAgent,
  ) {
    final entries = sessionsByAgent.entries
        .where((entry) => entry.key.trim().isNotEmpty && entry.value.isNotEmpty)
        .take(_maxAgents);
    return _jsonStore.write(portableData, _fileName, {
      'schemaVersion': _schemaVersion,
      'sessionsByAgent': {
        for (final entry in entries)
          entry.key: [
            for (final session in entry.value.take(_maxSessionsPerAgent))
              _boundedSessionJson(session),
          ],
      },
    }, lock: true);
  }

  Map<String, dynamic> _boundedSessionJson(AgentConversationSession session) {
    final json = session.toJson();
    final messages = session.messages;
    if (messages.length <= _maxMessagesPerSession) return json;

    final firstUserIndex = messages.indexWhere((message) {
      final role = message.role.trim().toLowerCase();
      return role == 'user' || role == 'human';
    });
    final retainFirstUser =
        firstUserIndex >= 0 &&
        firstUserIndex < messages.length - _maxMessagesPerSession;
    final retained = <dynamic>[
      if (retainFirstUser) messages[firstUserIndex].toJson(),
      ...messages
          .skip(
            messages.length -
                _maxMessagesPerSession +
                (retainFirstUser ? 1 : 0),
          )
          .map((message) => message.toJson()),
    ];
    return {
      ...json,
      'messages': retained,
      'messageCount': retained.length,
      'historyTruncated': true,
    };
  }
}
