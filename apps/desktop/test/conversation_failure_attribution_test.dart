import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/conversation/conversation_projection_producer.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'canonical projection keeps event identity, author, and causality',
    () async {
      final controller = ClientController(
        agentService: FakeAgentService(),
        conversationNativePort: _AttributionPort(),
      );
      addTearDown(controller.dispose);
      await controller.clientConversationController.initialize();
      await controller.clientConversationController.selectConversation(
        'conversation:alpha',
      );
      final producer = ConversationProjectionProducer(controller);
      addTearDown(producer.close);

      final events = producer.canonicalEvents.current.events;
      expect(events.map((event) => event.id), [
        'event:alpha-1',
        'event:alpha-diagnostic',
      ]);
      final message = events.first;
      expect(message.authorMembershipId, 'membership:owner');
      expect(message.authorLabel, 'Local User');
      expect(message.causationId, isEmpty);
      expect(message.createdAtUnixMs, 10);
      final diagnostic = events.last;
      expect(diagnostic.authorMembershipId, 'membership:codex');
      expect(diagnostic.authorLabel, 'Codex');
      expect(diagnostic.causationId, 'event:alpha-1');
      expect(diagnostic.correlationId, 'turn:alpha');
      expect(diagnostic.createdAtUnixMs, 11);
    },
  );

  test(
    'a failure attributed to another conversation never paints on the selected one',
    () async {
      final controller = ClientController(
        agentService: FakeAgentService(),
        conversationNativePort: _AttributionPort(),
      );
      addTearDown(controller.dispose);
      await controller.clientConversationController.initialize();
      await controller.clientConversationController.selectConversation(
        'conversation:alpha',
      );
      final producer = ConversationProjectionProducer(controller);
      addTearDown(producer.close);

      final owner = controller.clientConversationController;
      owner.surfaceFailure(
        'archive',
        'archive_denied',
        conversationId: 'conversation:beta',
      );
      var canonical = producer.canonicalEvents.current;
      expect(canonical.notice, isNull);
      expect(canonical.phase, PresentationPhase.ready);
      expect(canonical.failureStage, isEmpty);
      expect(canonical.failureRef, isEmpty);
      expect(producer.tabActivity.current.unreadCount, 0);
      expect(producer.tabActivity.current.requiresAttention, isFalse);

      owner.surfaceFailure(
        'send',
        'transport_failed',
        conversationId: 'conversation:alpha',
      );
      canonical = producer.canonicalEvents.current;
      expect(canonical.notice?.reasonCode, 'transport_failed');
      expect(canonical.phase, PresentationPhase.failed);
      expect(canonical.failureStage, 'send');
      expect(producer.tabActivity.current.unreadCount, 1);
      expect(producer.tabActivity.current.requiresAttention, isTrue);
    },
  );

  test(
    'an unattributed failure stays global and visible on the selection',
    () async {
      final port = _AttributionPort();
      final controller = ClientController(
        agentService: FakeAgentService(),
        conversationNativePort: port,
      );
      addTearDown(controller.dispose);
      await controller.clientConversationController.initialize();
      final producer = ConversationProjectionProducer(controller);
      addTearDown(producer.close);

      port.failListCode = 'catalog_unavailable';
      await controller.clientConversationController.refresh();
      expect(
        controller.clientConversationController.failureConversationId,
        isEmpty,
      );
      final canonical = producer.canonicalEvents.current;
      expect(canonical.notice?.reasonCode, 'catalog_unavailable');
      expect(canonical.phase, PresentationPhase.failed);

      // A catalog read has no originating Conversation: even with an active
      // selection the failure stays global instead of binding to it, and it
      // survives a selection change.
      await controller.clientConversationController.selectConversation(
        'conversation:alpha',
      );
      var selected = producer.canonicalEvents.current;
      expect(selected.conversationId, 'conversation:alpha');
      expect(selected.notice?.reasonCode, 'catalog_unavailable');

      await controller.clientConversationController.refresh();
      expect(
        controller.clientConversationController.failureConversationId,
        isEmpty,
      );
      selected = producer.canonicalEvents.current;
      expect(selected.notice?.reasonCode, 'catalog_unavailable');
      expect(selected.phase, PresentationPhase.failed);

      await controller.clientConversationController.selectConversation(
        'conversation:beta',
      );
      selected = producer.canonicalEvents.current;
      expect(selected.conversationId, 'conversation:beta');
      expect(selected.notice?.reasonCode, 'catalog_unavailable');
    },
  );

  test(
    'a rejected canonical action attributes to the originating conversation',
    () async {
      final controller = ClientController(
        agentService: FakeAgentService(),
        conversationNativePort: _AttributionPort(),
      );
      addTearDown(controller.dispose);
      await controller.clientConversationController.initialize();
      await controller.clientConversationController.selectConversation(
        'conversation:alpha',
      );
      final composition = ConversationFeatureComposition(controller);
      addTearDown(composition.close);

      final rejections = <ConversationActionRejected>[];
      final subscription = composition.binding.effects.effects.listen((effect) {
        if (effect is ConversationActionRejected) rejections.add(effect);
      });
      addTearDown(subscription.cancel);

      composition.binding.intents.send(
        const DeleteCanonicalConversationMessage('event:missing'),
      );
      await _settleUntil(() => rejections.isNotEmpty);
      expect(rejections.single.conversationId, 'conversation:alpha');
      expect(rejections.single.stage, 'canonical-delete');
    },
  );
}

Future<void> _settleUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 80; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('conversation effect did not land');
}

/// Serves two canonical group Conversations; `conversation:alpha` carries a
/// local-owner message and an agent-authored diagnostic child so identity,
/// author, and edit/delete causality are observable through the projection.
final class _AttributionPort implements ClientConversationNativePort {
  String failListCode = '';

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = command.payload;
    final action = request['action'];
    if (action == 'conversation.list' && failListCode.isNotEmpty) {
      return {
        'ok': false,
        'error': {'code': failListCode},
      };
    }
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => [
          _summary('conversation:alpha', eventCount: 2),
          _summary('conversation:beta', eventCount: 0),
        ],
        'conversation.get' => _conversation(
          (request['conversationId'] ?? '').toString(),
        ),
        'conversation.events.page' => _eventPage(
          (request['conversationId'] ?? '').toString(),
        ),
        _ => const <String, dynamic>{},
      },
    };
  }
}

Map<String, dynamic> _summary(String id, {required int eventCount}) => {
  'id': id,
  'title': id,
  'archived': false,
  'pinned': false,
  'isGroup': true,
  'revision': 1,
  'updatedAtUnixMs': 10,
  'membershipCount': 2,
  'eventCount': eventCount,
};

Map<String, dynamic> _conversation(String id) => {
  'id': id,
  'title': id,
  'archived': false,
  'pinned': false,
  'isGroup': true,
  'revision': 1,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 10,
  'eventCount': id == 'conversation:alpha' ? 2 : 0,
  'memberships': [
    _membership(
      id: 'membership:owner',
      principalId: 'human:local',
      kind: 'human',
      label: 'Local User',
      access: 'owner',
      conversationId: id,
    ),
    _membership(
      id: 'membership:codex',
      principalId: 'agent:codex',
      kind: 'agent',
      label: 'Codex',
      agentId: 'codex',
      conversationId: id,
    ),
  ],
};

Map<String, dynamic> _membership({
  required String id,
  required String principalId,
  required String kind,
  required String label,
  required String conversationId,
  String agentId = '',
  String access = 'member',
}) => {
  'id': id,
  'conversationId': conversationId,
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

Map<String, dynamic> _eventPage(String conversationId) {
  if (conversationId != 'conversation:alpha') {
    return {'events': const <Map<String, dynamic>>[], 'totalCount': 0};
  }
  return {
    'events': [
      {
        'id': 'event:alpha-1',
        'conversationId': 'conversation:alpha',
        'sequence': 1,
        'authorMembershipId': 'membership:owner',
        'kind': 'message',
        'createdAtUnixMs': 10,
        'finalized': true,
        'parts': [
          {
            'id': 'part:alpha-text',
            'eventId': 'event:alpha-1',
            'ordinal': 0,
            'kind': 'text',
            'content': 'hello',
            'createdAtUnixMs': 10,
          },
        ],
      },
      {
        'id': 'event:alpha-diagnostic',
        'conversationId': 'conversation:alpha',
        'sequence': 2,
        'authorMembershipId': 'membership:codex',
        'kind': 'message',
        'causationId': 'event:alpha-1',
        'correlationId': 'turn:alpha',
        'createdAtUnixMs': 11,
        'finalized': true,
        'parts': [
          {
            'id': 'part:alpha-diagnostic',
            'eventId': 'event:alpha-diagnostic',
            'ordinal': 0,
            'kind': 'diagnostic',
            'content': '{"code":"fixture_turn_failed"}',
            'createdAtUnixMs': 11,
          },
        ],
      },
    ],
    'totalCount': 2,
  };
}
