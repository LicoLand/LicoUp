import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_recent_participants.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';

void main() {
  test(
    'recent participants initialize once, promote by event, and hot-append',
    () {
      final order = ClientConversationRecentParticipants();
      final conversation = _localConversation();
      final initialEvents = [
        _message(1, 1),
        _message(2, 2),
        _message(3, 6),
        _message(4, 2),
        _message(5, 7),
        _message(6, 4),
        _availability(7, 3),
      ];

      expect(
        order.applySnapshot(
          conversation: conversation,
          events: initialEvents,
          availableLocalAgentIds: const ['agent-8'],
        ),
        isTrue,
      );
      expect(order.agentIds, [
        'agent-4',
        'agent-7',
        'agent-2',
        'agent-6',
        'agent-1',
        'agent-3',
        'agent-5',
        'agent-8',
      ]);

      final withNewMessage = [...initialEvents, _message(8, 6)];
      expect(
        order.applySnapshot(
          conversation: conversation,
          events: withNewMessage,
          availableLocalAgentIds: const ['agent-8'],
        ),
        isTrue,
      );
      expect(order.agentIds, [
        'agent-6',
        'agent-4',
        'agent-7',
        'agent-2',
        'agent-1',
        'agent-3',
        'agent-5',
        'agent-8',
      ]);

      expect(
        order.applySnapshot(
          conversation: conversation,
          events: withNewMessage,
          availableLocalAgentIds: const ['agent-8', 'agent-9'],
        ),
        isTrue,
      );
      expect(order.agentIds.last, 'agent-9');
      expect(order.agentIds.toSet(), hasLength(order.agentIds.length));

      expect(
        order.applySnapshot(
          conversation: conversation,
          events: withNewMessage,
          availableLocalAgentIds: const ['agent-8', 'agent-9'],
        ),
        isFalse,
      );
    },
  );
}

ClientConversation _localConversation() => ClientConversation.fromJson({
  'id': 'lico-group-default',
  'title': 'Local',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': 1,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 8,
  'eventCount': 8,
  'memberships': [
    _membership(
      id: 'membership:owner',
      principalId: 'human:local',
      kind: 'human',
      label: 'Local User',
      access: 'owner',
    ),
    for (var index = 1; index <= 7; index += 1)
      _membership(
        id: 'membership:agent-$index',
        principalId: 'agent:agent-$index',
        kind: 'agent',
        label: 'Agent $index',
        agentId: 'agent-$index',
      ),
  ],
});

ClientConversationEvent _message(int sequence, int agentIndex) =>
    ClientConversationEvent.fromJson({
      'id': 'event:$sequence',
      'conversationId': 'lico-group-default',
      'sequence': sequence,
      'authorMembershipId': 'membership:agent-$agentIndex',
      'kind': 'message',
      'createdAtUnixMs': sequence,
      'finalized': true,
      'parts': <Map<String, dynamic>>[],
    });

ClientConversationEvent _availability(int sequence, int agentIndex) =>
    ClientConversationEvent.fromJson({
      'id': 'event:$sequence',
      'conversationId': 'lico-group-default',
      'sequence': sequence,
      'authorMembershipId': 'membership:agent-$agentIndex',
      'kind': 'availability',
      'createdAtUnixMs': sequence,
      'finalized': true,
      'parts': <Map<String, dynamic>>[],
    });

Map<String, dynamic> _membership({
  required String id,
  required String principalId,
  required String kind,
  required String label,
  String agentId = '',
  String access = 'member',
}) => {
  'id': id,
  'conversationId': 'lico-group-default',
  'principal': {
    'id': principalId,
    'kind': kind,
    'displayName': label,
    if (agentId.isNotEmpty) 'agentId': agentId,
    'createdAtUnixMs': 1,
  },
  'access': access,
  'status': 'active',
  'joinedAtUnixMs': 1,
};
