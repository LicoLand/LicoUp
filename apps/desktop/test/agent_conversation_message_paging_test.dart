import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/ui/reading_position_scroll_controller.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  for (final style in AgentsMessageStyle.values) {
    testWidgets(
      '${style.name} switches a scrolled parent to child and restores the parent position',
      (tester) async {
        final controller = ReadingPositionScrollController();
        addTearDown(controller.dispose);
        Future<void> pump(String sessionId) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildLicoTheme(platformBrightness: Brightness.dark),
              home: Scaffold(
                body: AgentConversationMessageList(
                  loading: false,
                  session: _page(40, 60, sessionId: sessionId),
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
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await pump('parent');
        controller.jumpTo(650);
        await tester.pumpAndSettle();
        final parentPosition = controller.position;
        final parked = parentPosition.pixels;
        expect(parked, greaterThan(48));
        await pump('child');
        expect(tester.takeException(), isNull);
        expect(controller.position, isNot(same(parentPosition)));
        expect(controller.position.hasContentDimensions, isTrue);
        expect(controller.offset, 0);
        await pump('parent');
        expect(tester.takeException(), isNull);
        expect(controller.offset, closeTo(parked, 1));
      },
    );

    testWidgets(
      '${style.name} preserves reading position across older pages and failed-page live growth',
      (tester) async {
        final controller = ReadingPositionScrollController();
        addTearDown(controller.dispose);
        var session = _page(40, 60);
        var live = <AgentConversationMessage>[];
        var loading = false;
        var error = '';
        Future<void> pump() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildLicoTheme(platformBrightness: Brightness.dark),
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 600,
                  child: AgentConversationMessageList(
                    loading: false,
                    session: session,
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
                    messagePageLoading: loading,
                    messagePageError: error,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
        }

        await pump();
        expect(session.messages, hasLength(20));
        expect(controller.offset, 0);
        controller.jumpTo(650);
        await tester.pumpAndSettle();
        final anchor = _visibleHistory(tester);
        final before = tester.getTopLeft(anchor).dy;
        session = _page(20, 60);
        await pump();
        expect(tester.getTopLeft(anchor).dy, closeTo(before, 1));

        loading = true;
        await pump();
        loading = false;
        error = 'native_history_message_page_gap';
        await pump();
        final beforeLive = tester.getTopLeft(anchor).dy;
        live = [
          const AgentConversationMessage(
            id: 'live-reply',
            role: 'assistant',
            text: 'Live reply\n\nOne\n\nTwo\n\nThree\n\nFour\n\nFive',
            createdAt: '2026-07-24T00:00:00Z',
          ),
        ];
        await pump();
        expect(tester.getTopLeft(anchor).dy, closeTo(beforeLive, 2));
        controller.jumpTo(0);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Live reply', findRichText: true),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
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

AgentConversationSession _page(
  int start,
  int end, {
  String sessionId = 'root',
}) => AgentConversationSession.fromJson({
  'id': sessionId,
  'agentId': 'codex',
  'nativeSessionId': sessionId,
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
