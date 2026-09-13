import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks/native_subagent_history_scope.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

import 'message_blocks_test_harness.dart';

void main() {
  test(
    'native child identity and page facts round-trip without inline content',
    () {
      final message = parseAgentConversationMessage({
        'id': 'child-card',
        'role': 'subagent',
        'text': '',
        'childSessionId': 'native-child',
        'childMessageCount': 65,
        'childSourceRevision': 'native-revision-1',
        'messages': <Map<String, dynamic>>[],
      });
      expect(message.childSessionId, 'native-child');
      expect(message.childMessageCount, 65);
      expect(message.childMessagePage, isNull);
      expect(message.childMessages, isEmpty);
      final restored = parseAgentConversationMessage(message.toJson());
      expect(restored.childSessionId, message.childSessionId);
      expect(restored.childMessageCount, 65);
      expect(restored.childSourceRevision, 'native-revision-1');
    },
  );

  testWidgets(
    'same-count child revisions refresh once when expanded and stay lazy while collapsed',
    (tester) async {
      var revision = 'native-revision-1';
      var history = const <NativeChildConversationProjection>[];
      final requests = <String>[];
      Future<void> pump() async {
        await tester.pumpWidget(
          messageBlocksTestApp(
            NativeSubagentHistoryScope(
              histories: history,
              onLoad: (_, _) => requests.add(revision),
              child: AgentConversationSubagentCardBlock(
                message: parseAgentConversationMessage({
                  'id': 'child-card',
                  'role': 'subagent',
                  'cardTitle': 'Native child',
                  'childSessionId': 'native-child',
                  'childMessageCount': 65,
                  'childSourceRevision': revision,
                }),
                adapter: AgentRenderAdapter.fallback(),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      AgentConversationSession page(String version, String text) {
        final value = _page(45, 65).toJson();
        value['sourceRevision'] = version;
        ((value['messages'] as List).last as Map)['text'] = text;
        return AgentConversationSession.fromJson(value);
      }

      await pump();
      expect(requests, isEmpty);
      await tester.tap(find.text('Native child'));
      await tester.pump();
      history = [
        NativeChildConversationProjection(
          sessionId: 'native-child',
          session: page(revision, 'Original child response'),
        ),
      ];
      await pump();
      revision = 'native-revision-2';
      await pump();
      expect(requests, ['native-revision-1', 'native-revision-2']);
      history = [
        NativeChildConversationProjection(
          sessionId: 'native-child',
          session: page(revision, 'Revised child response'),
        ),
      ];
      await pump();
      await tester.pumpAndSettle();
      expect(
        find.text('Revised child response', findRichText: true),
        findsOneWidget,
      );
      await pump();
      expect(requests, hasLength(2));
      await tester.tap(find.text('Native child'));
      revision = 'native-revision-3';
      await pump();
      expect(requests, hasLength(2));
      await tester.tap(find.text('Native child'));
      await tester.pump();
      expect(requests.last, 'native-revision-3');
    },
  );

  testWidgets(
    'expansion loads the native child once and older pages stay within its card',
    (tester) async {
      final histories = ValueNotifier<List<NativeChildConversationProjection>>(
        const [],
      );
      addTearDown(histories.dispose);
      final requests = <(String, bool)>[];
      final card = AgentConversationSubagentCardBlock(
        message: parseAgentConversationMessage({
          'id': 'child-card',
          'role': 'subagent',
          'text': '',
          'cardTitle': 'Native child',
          'childSessionId': 'native-child',
          'childMessageCount': 65,
        }),
        adapter: AgentRenderAdapter.fallback(),
      );
      await tester.pumpWidget(
        messageBlocksTestApp(
          ValueListenableBuilder<List<NativeChildConversationProjection>>(
            valueListenable: histories,
            builder: (context, values, child) => NativeSubagentHistoryScope(
              histories: values,
              onLoad: (id, earlier) => requests.add((id, earlier)),
              child: child!,
            ),
            child: card,
          ),
        ),
      );
      expect(requests, isEmpty);
      await tester.tap(find.text('Native child'));
      await tester.pump();
      expect(requests, [('native-child', false)]);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      histories.value = [
        NativeChildConversationProjection(
          sessionId: 'native-child',
          session: _page(45, 65),
        ),
      ];
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Child message 64', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Child message 44', findRichText: true),
        findsNothing,
      );
      final list = find.byType(ListView);
      final controller = tester.widget<ListView>(list).controller!;
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Earlier'));
      await tester.pump();
      expect(requests.last, ('native-child', true));
      final offset = controller.offset;
      histories.value = [
        NativeChildConversationProjection(
          sessionId: 'native-child',
          session: _page(25, 65),
        ),
      ];
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(offset, 1));

      await tester.tap(find.text('Native child'));
      await tester.pumpAndSettle();
      final calls = requests.length;
      await tester.tap(find.text('Native child'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(calls));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed child page stays visible and retries its exact request', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      messageBlocksTestApp(
        NativeSubagentHistoryScope(
          histories: const [
            NativeChildConversationProjection(
              sessionId: 'native-child',
              errorCode: 'native_history_session_not_found',
            ),
          ],
          onLoad: (id, earlier) {
            expect(id, 'native-child');
            expect(earlier, isFalse);
            retries += 1;
          },
          child: AgentConversationSubagentCardBlock(
            message: parseAgentConversationMessage({
              'id': 'child-card',
              'role': 'subagent',
              'text': '',
              'cardTitle': 'Native child',
              'childSessionId': 'native-child',
            }),
            adapter: AgentRenderAdapter.fallback(),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Native child'));
    await tester.pumpAndSettle();
    expect(find.text('native_history_session_not_found'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);
  });
}

AgentConversationSession _page(int start, int end) =>
    AgentConversationSession.fromJson({
      'id': 'native-child',
      'agentId': 'codex',
      'nativeSessionId': 'native-child',
      'sourceMessageCount': 65,
      'messages': [
        for (var index = start; index < end; index += 1)
          {
            'id': 'message-$index',
            'role': 'assistant',
            'text': 'Child message $index',
            'createdAt': '2026-07-23T00:00:00Z',
          },
      ],
      'messagePage': {
        'start': start,
        'endExclusive': end,
        'returned': end - start,
        'total': 65,
        'hasEarlier': start > 0,
        if (start > 0) 'nextBefore': 'message-$start',
      },
    });
