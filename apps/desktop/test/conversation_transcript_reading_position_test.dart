import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

/// The production transcript is a value-driven collection: appended content
/// must not move a scrolled-up reader, and a rebuild for an unrelated resource
/// must not move it either. The caller never captures an anchor by hand.
void main() {
  for (final style in AgentsMessageStyle.values) {
    testWidgets('${style.name} appended messages keep the reading position', (
      tester,
    ) async {
      final controller = ReadingPositionScrollController();
      addTearDown(controller.dispose);
      await _pump(tester, controller: controller, style: style);
      expect(
        find.byWidgetPredicate((widget) => widget is CollectionView),
        findsOneWidget,
      );

      controller.jumpTo(650);
      await tester.pumpAndSettle();
      final anchor = _visibleHistory(tester);
      final before = tester.getTopLeft(anchor).dy;
      expect(before, greaterThan(100));

      await _pump(
        tester,
        controller: controller,
        style: style,
        live: const [
          AgentConversationMessage(
            id: 'live-reply',
            role: 'assistant',
            text: 'Live reply\n\nOne\n\nTwo\n\nThree\n\nFour\n\nFive',
            createdAt: '2026-07-24T00:00:00Z',
          ),
        ],
      );

      expect(tester.getTopLeft(anchor).dy, closeTo(before, 2));
      expect(controller.offset, greaterThan(48));
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Live reply', findRichText: true),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a theme change keeps the reader where they were', (
    tester,
  ) async {
    final controller = ReadingPositionScrollController();
    addTearDown(controller.dispose);
    await _pump(
      tester,
      controller: controller,
      style: AgentsMessageStyle.documentTranscript,
    );

    controller.jumpTo(650);
    await tester.pumpAndSettle();
    final anchor = _visibleHistory(tester);
    final before = tester.getTopLeft(anchor).dy;

    await _pump(
      tester,
      controller: controller,
      style: AgentsMessageStyle.documentTranscript,
      brightness: Brightness.light,
    );

    expect(tester.getTopLeft(anchor).dy, closeTo(before, 2));
    expect(controller.offset, greaterThan(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a reader parked at the newest message follows appended content',
    (tester) async {
      final controller = ReadingPositionScrollController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        controller: controller,
        style: AgentsMessageStyle.documentTranscript,
      );
      expect(controller.offset, 0);

      await _pump(
        tester,
        controller: controller,
        style: AgentsMessageStyle.documentTranscript,
        live: const [
          AgentConversationMessage(
            id: 'live-reply',
            role: 'assistant',
            text: 'Live reply',
            createdAt: '2026-07-24T00:00:00Z',
          ),
        ],
      );

      expect(controller.offset, 0);
      expect(
        find.textContaining('Live reply', findRichText: true),
        findsWidgets,
      );
    },
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required ReadingPositionScrollController controller,
  required AgentsMessageStyle style,
  List<AgentConversationMessage> live = const [],
  Brightness brightness = Brightness.dark,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLicoTheme(platformBrightness: brightness),
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: AgentConversationMessageList(
            loading: false,
            session: _page(40, 60),
            target: TargetCandidate(
              target: 'codex',
              label: 'Codex',
              kind: 'cli',
              status: 'detected',
              configured: true,
              confidence: 1,
              adapterStatus: 'implemented',
            ),
            scrollController: controller,
            messageStyle: style,
            liveMessages: live,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Finder _visibleHistory(WidgetTester tester) {
  for (final element in find.byType(RichText).evaluate()) {
    final text = (element.widget as RichText).text.toPlainText();
    if (!text.startsWith('History message')) continue;
    final finder = find.byWidget(element.widget);
    final rect = tester.getRect(finder);
    if (rect.top > 100 && rect.bottom < 550) {
      return find.text(text, findRichText: true);
    }
  }
  throw StateError('No visible synthetic history anchor');
}

AgentConversationSession _page(int start, int end) =>
    AgentConversationSession.fromJson({
      'id': 'root',
      'agentId': 'codex',
      'nativeSessionId': 'root',
      'sourceMessageCount': 60,
      'messages': [
        for (var index = start; index < end; index += 1)
          {
            'id': 'message-$index',
            'role': index.isEven ? 'user' : 'assistant',
            'text': 'History message $index\n\nRetained content',
            'createdAt': '2026-07-23T00:00:00Z',
          },
      ],
      'messagePage': {
        'start': start,
        'endExclusive': end,
        'returned': end - start,
        'total': 60,
        'hasEarlier': true,
        'nextBefore': 'message-$start',
      },
    });
