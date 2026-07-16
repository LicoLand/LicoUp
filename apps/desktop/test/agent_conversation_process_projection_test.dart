import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_process_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('process projection bounds rendering while retaining totals', () {
    final events = [
      for (var index = 0; index < 140; index++)
        AgentConversationMessage(
          id: 'event-$index',
          role: index == 139 ? 'error' : 'event',
          cardType: index == 139 ? 'error' : 'event',
          text: 'safe event',
          createdAt: DateTime.utc(
            2026,
            1,
            1,
          ).add(Duration(seconds: index)).toIso8601String(),
        ),
    ];

    final projection = projectConversationProcessEvents(events);

    expect(projection.events, hasLength(128));
    expect(projection.totalOperations, 140);
    expect(projection.renderTruncated, isTrue);
    expect(projection.countTruncated, isFalse);
    expect(projection.issues, 1);
    expect(
      projection.endedAt?.difference(projection.startedAt!).inSeconds,
      139,
    );
    expect(() => projection.events.add(events.first), throwsUnsupportedError);
  });

  test('operation keys disambiguate duplicate native identities', () {
    const first = AgentConversationMessage(
      id: 'duplicate',
      role: 'event',
      cardType: 'event',
      text: 'first',
      createdAt: '2026-01-01T00:00:00Z',
      stableIdentity: 'stable-one',
    );
    const second = AgentConversationMessage(
      id: 'duplicate',
      role: 'event',
      cardType: 'event',
      text: 'second',
      createdAt: '2026-01-01T00:00:01Z',
      stableIdentity: 'stable-two',
    );

    final keys = uniqueConversationProcessOperationKeys(const [first, second]);

    expect(keys, hasLength(2));
    expect(keys.toSet(), hasLength(2));
    expect(keys.every((key) => key.startsWith('duplicate-')), isTrue);
  });
}
