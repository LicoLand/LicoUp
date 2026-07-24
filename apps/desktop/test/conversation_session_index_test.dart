import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';

void main() {
  test('sorts newest first and replaces duplicate native sessions', () {
    final sessions = sortConversationSessionsByUpdatedAt([
      _session('old-id', 'native-shared', '2026-01-01T00:00:00Z'),
      _session('other', 'native-other', '2026-01-02T00:00:00Z'),
      _session('new-id', 'native-shared', '2026-01-03T00:00:00Z'),
    ]);

    expect(sessions.map((session) => session.id), ['new-id', 'other']);
  });

  test('uses stable id ordering when timestamps are equal', () {
    final left = _session('a', 'native-a', '2026-01-01T00:00:00Z');
    final right = _session('b', 'native-b', '2026-01-01T00:00:00Z');

    expect(compareConversationSessionUpdatedAt(left, right), lessThan(0));
  });
}

AgentConversationSession _session(
  String id,
  String nativeId,
  String updatedAt,
) => AgentConversationSession(
  id: id,
  agentId: 'codex',
  title: id,
  createdAt: updatedAt,
  updatedAt: updatedAt,
  nativeSessionId: nativeId,
  messages: const [],
);
