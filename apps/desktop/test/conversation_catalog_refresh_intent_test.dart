import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sidebar refresh re-lists canonical groups while a group is selected',
    () async {
      final native = _CatalogNative()
        ..summaries = [_summary(id: 'lico-group-default', title: 'Local')];
      final controller = ClientController(
        agentService: FakeAgentService(),
        conversationNativePort: native,
        pendingNoticePollInterval: const Duration(hours: 1),
      );
      final composition = ConversationFeatureComposition(controller);
      addTearDown(() async {
        await composition.close();
        await controller.close();
      });

      await controller.clientConversationController.initialize();
      await controller.clientConversationController.selectConversation(
        'lico-group-default',
      );
      expect(
        controller.groupNativeSessions.conversationId,
        'lico-group-default',
      );
      expect(
        controller.clientConversationController.groupConversations.map(
          (conversation) => conversation.id,
        ),
        ['lico-group-default'],
      );
      final listsBeforeRefresh = native.listCount;

      native.summaries = [
        _summary(id: 'lico-group-default', title: 'Local'),
        _summary(id: 'conversation:research', title: 'Research room'),
      ];
      composition.binding.intents.send(const RefreshConversationCatalog());
      await _settleUntil(
        () =>
            controller.clientConversationController.groupConversations.length ==
            2,
      );

      expect(native.listCount, greaterThan(listsBeforeRefresh));
      expect(
        controller.clientConversationController.groupConversations.map(
          (conversation) => conversation.id,
        ),
        ['lico-group-default', 'conversation:research'],
      );
    },
  );
}

Future<void> _settleUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 80; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('canonical catalog did not pick up the host-created group');
}

final class _CatalogNative implements ClientConversationNativePort {
  List<Map<String, dynamic>> summaries = const [];
  final requests = <Map<String, dynamic>>[];

  int get listCount => requests
      .where((request) => request['action'] == 'conversation.list')
      .length;

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = Map<String, dynamic>.from(command.payload);
    requests.add(request);
    final action = (request['action'] ?? '').toString();
    final conversationId = (request['conversationId'] ?? '').toString();
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => summaries,
        'conversation.get' => _conversation(conversationId),
        'conversation.events.page' => {
          'events': <Map<String, dynamic>>[],
          'nextCursor': null,
          'totalCount': 0,
        },
        _ => <String, dynamic>{},
      },
    };
  }
}

Map<String, dynamic> _summary({required String id, required String title}) => {
  'id': id,
  'title': title,
  'archived': false,
  'pinned': id == 'lico-group-default',
  'isGroup': true,
  'revision': 1,
  'updatedAtUnixMs': 10,
  'membershipCount': 2,
  'eventCount': 0,
};

Map<String, dynamic> _conversation(String id) {
  final title = id == 'lico-group-default' ? 'Local' : 'Research room';
  return {
    'id': id,
    'title': title,
    'archived': false,
    'pinned': id == 'lico-group-default',
    'isGroup': true,
    'revision': 1,
    'createdAtUnixMs': 1,
    'updatedAtUnixMs': 10,
    'eventCount': 0,
    'memberships': [
      {
        'id': 'membership:owner',
        'conversationId': id,
        'principal': {
          'id': 'human:local',
          'kind': 'human',
          'displayName': 'Local User',
          'createdAtUnixMs': 1,
        },
        'access': 'owner',
        'status': 'active',
        'joinedAtUnixMs': 1,
      },
    ],
  };
}
