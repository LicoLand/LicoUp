import 'fixtures/client_controller/support/client_controller_scenario_dependencies.dart';
import 'fixtures/client_controller/support/client_controller_scenario_json.dart';
import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'package:licoup/src/projections/conversation/conversation_projection_producer.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'same-count native child revision refreshes the latest body and retains opened history',
    () async {
      final service = _PagedHistoryService()
        ..messageCounts['child'] = 25
        ..sourceRevisions['child'] = 'native-revision-1';
      Map<String, dynamic> root(String revision) => {
        ...conversationSessionJson(
          id: 'parent',
          agentId: 'codex',
          text: 'Parent',
        ),
        'messages': [
          {
            'id': 'child-card',
            'role': 'subagent',
            'childSessionId': 'child',
            'childMessageCount': 25,
            'childSourceRevision': revision,
          },
        ],
      };
      final controller = _controller(service, root('native-revision-1'));
      addTearDown(controller.dispose);
      await controller.loadChildConversationMessages('child');
      await controller.loadChildConversationMessages('child', earlier: true);
      final oldRoot = controller.selectedConversationSession!;
      final updatedRoot = AgentConversationSession.fromJson(
        root('native-revision-2'),
      );
      expect(conversationSessionsEquivalent(oldRoot, updatedRoot), isFalse);
      controller.conversationSessionsByAgent = {
        'codex': [updatedRoot],
      };
      service.sourceRevisions['child'] = 'native-revision-2';
      service.lastMessageText['child'] =
          'Revised live response at the same count';
      await controller.loadChildConversationMessages('child');
      final child = controller.conversationChildSessions['child']!;
      expect(child.messages, hasLength(25));
      expect(
        child.messages.last.text,
        'Revised live response at the same count',
      );
      expect(child.sourceRevision, 'native-revision-2');
      expect(child.toJson()['sourceRevision'], 'native-revision-2');
      expect(service.conversationStdinRequests, hasLength(3));
      await controller.loadChildConversationMessages('child');
      expect(service.conversationStdinRequests, hasLength(3));
    },
  );

  test(
    'root reads latest 20 and every earlier page stays 20 while refresh retains history',
    () async {
      final service = _PagedHistoryService()..messageCounts['parent'] = 65;
      final controller = _controller(service, _page('parent', 65, 45, 65));
      addTearDown(controller.dispose);

      controller.selectConversationSession('parent');
      await _finishPage(controller);
      expect(controller.selectedConversationSession!.messages, hasLength(20));
      expect(service.conversationStdinRequests.single['messageLimit'], 20);
      for (final length in [40, 60, 65]) {
        await controller.loadEarlierConversationMessages();
        expect(
          controller.selectedConversationSession!.messages,
          hasLength(length),
        );
      }
      expect(
        service.conversationStdinRequests.map(
          (request) => request['messageLimit'],
        ),
        everyElement(20),
      );
      expect(
        service.conversationStdinRequests.map(
          (request) => request['messageBefore'] ?? '',
        ),
        ['', 'message-45', 'message-25', 'message-5'],
      );
      service.messageCounts['parent'] = 112;
      await controller.refreshActiveConversationSessionInternal(
        'codex',
        'parent',
      );
      final messages = controller.selectedConversationSession!.messages;
      expect(messages, hasLength(112));
      expect(messages.first.id, 'message-0');
      expect(messages.last.id, 'message-111');
      expect(messages.map((message) => message.id).toSet(), hasLength(112));
      expect(
        service.conversationStdinRequests
            .skip(4)
            .map((request) => request['messageLimit']),
        everyElement(20),
      );
    },
  );

  test(
    'child pages stay cached beneath the selected root and keep every message',
    () async {
      final service = _PagedHistoryService()..messageCounts['child'] = 65;
      final root = {
        ...conversationSessionJson(
          id: 'parent',
          agentId: 'codex',
          text: 'Parent',
        ),
        'messages': [
          {
            'id': 'child-card',
            'role': 'subagent',
            'text': 'Native worker',
            'childSessionId': 'child',
            'childMessageCount': 65,
          },
        ],
      };
      final controller = _controller(service, root);
      addTearDown(controller.dispose);
      final producer = ConversationProjectionProducer(controller);
      addTearDown(producer.close);
      final selected = controller.selectedConversationSession;

      await controller.loadChildConversationMessages('unrecorded-child');
      expect(service.conversationStdinRequests, isEmpty);
      await controller.loadChildConversationMessages('child');
      await Future<void>.delayed(Duration.zero);
      expect(
        producer.nativeCatalog.current.childHistories.single.session!.messages,
        hasLength(20),
      );
      expect(
        controller.conversationChildSessions['child']!.messages,
        hasLength(20),
      );
      await controller.loadChildConversationMessages('child');
      expect(service.conversationStdinRequests, hasLength(1));
      for (final length in [40, 60, 65]) {
        await controller.loadChildConversationMessages('child', earlier: true);
        expect(
          controller.conversationChildSessions['child']!.messages,
          hasLength(length),
        );
        expect(
          identical(controller.selectedConversationSession, selected),
          isTrue,
        );
      }
      final child = controller.conversationChildSessions['child']!;
      expect(child.messagePage.hasEarlier, isFalse);
      expect(
        child.messages.map((message) => message.id).toSet(),
        hasLength(65),
      );
      expect(controller.selectedConversationSessionId, 'parent');
      expect(controller.selectedConversationSessions, hasLength(1));
      expect(
        service.conversationStdinRequests.map(
          (request) => request['messageLimit'],
        ),
        everyElement(20),
      );
    },
  );

  test(
    'duplicate child expansion shares the request and late result cannot replace a new root',
    () async {
      final gate = Completer<void>();
      final service = _PagedHistoryService()
        ..messageCounts['child'] = 30
        ..conversationStreamGates['codex'] = gate;
      final controller = _controller(service, {
        ...conversationSessionJson(
          id: 'parent',
          agentId: 'codex',
          text: 'Parent',
        ),
        'messages': [
          {
            'id': 'child-card',
            'role': 'subagent',
            'text': '',
            'childSessionId': 'child',
            'childMessageCount': 30,
          },
        ],
      });
      addTearDown(controller.dispose);
      final pending = controller.loadChildConversationMessages('child');
      await controller.loadChildConversationMessages('child');
      await Future<void>.delayed(Duration.zero);
      expect(service.conversationStdinRequests, hasLength(1));
      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession.fromJson(_page('another-root', 1, 0, 1)),
        ],
      };
      controller.selectedConversationSessionId = 'another-root';
      gate.complete();
      await pending;
      expect(controller.conversationChildSessions, isEmpty);
      expect(controller.selectedConversationSessionId, 'another-root');
    },
  );

  test(
    'native live child facts remain addressable before root readback',
    () async {
      final service = _PagedHistoryService()..messageCounts['child'] = 1;
      final controller = _controller(service, _page('parent', 2, 0, 2));
      addTearDown(controller.dispose);
      controller.liveConversationMessagesByScope = {
        controller.conversationComposerScopeKey: [
          parseAgentConversationMessage({
            'id': 'live-child-card',
            'role': 'subagent',
            'text': '',
            'childSessionId': 'child',
            'childMessageCount': 1,
          }),
        ],
      };
      await controller.loadChildConversationMessages('child');
      expect(
        controller.conversationChildSessions['child']!.messages,
        hasLength(1),
      );
      expect(controller.selectedConversationSessionId, 'parent');
    },
  );
}

ClientController _controller(
  _PagedHistoryService service,
  Map<String, dynamic> root,
) {
  final controller = ClientController(agentService: service);
  controller.selectedConversationAgentId = 'codex';
  controller.conversationSessionsByAgent = {
    'codex': [AgentConversationSession.fromJson(root)],
  };
  controller.selectedConversationSessionId = root['id'] as String;
  return controller;
}

Future<void> _finishPage(ClientController controller) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (controller.conversationMessagePageLoadingKeys.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Synthetic message page did not finish');
}

class _PagedHistoryService extends FakeAgentService {
  final messageCounts = <String, int>{};
  final sourceRevisions = <String, String>{};
  final lastMessageText = <String, String>{};

  @override
  List<Map<String, dynamic>> fakeConversationSessionRequestPage(
    Map<String, dynamic> request,
  ) {
    final id = request['sessionId'] as String;
    final count = messageCounts[id]!;
    final before = request['messageBefore'] as String? ?? '';
    final end = before.isEmpty
        ? count
        : int.parse(before.replaceFirst('message-', ''));
    final start = (end - (request['messageLimit'] as int)).clamp(0, end);
    final page = _page(id, count, start, end);
    page['sourceRevision'] = sourceRevisions[id] ?? '';
    if (end == count && lastMessageText.containsKey(id)) {
      ((page['messages'] as List).last as Map)['text'] = lastMessageText[id];
    }
    return [page];
  }
}

Map<String, dynamic> _page(String id, int count, int start, int end) => {
  ...conversationSessionJson(
    id: id,
    agentId: 'codex',
    text: 'Synthetic history',
  ),
  'sourceMessageCount': count,
  'messages': [
    for (var index = start; index < end; index += 1)
      {
        'id': 'message-$index',
        'role': index.isEven ? 'user' : 'assistant',
        'text': 'Message $index',
        'createdAt': '2026-07-23T00:00:00Z',
      },
  ],
  'messagePage': {
    'start': start,
    'endExclusive': end,
    'returned': end - start,
    'total': count,
    'hasEarlier': start > 0,
    if (start > 0) 'nextBefore': 'message-$start',
  },
};
