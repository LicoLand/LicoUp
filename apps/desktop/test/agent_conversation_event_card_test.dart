import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_event_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  test('timeline builder groups structured events behind their message', () {
    const user = AgentConversationMessage(
      id: 'user-1',
      role: 'user',
      text: 'Start',
      createdAt: '2026-01-01T00:00:00Z',
      stableIdentity: 'stable-user',
    );
    const toolCall = AgentConversationMessage(
      id: 'tool-1',
      role: 'function_call',
      text: 'fixture input',
      createdAt: '2026-01-01T00:00:01Z',
      cardType: 'tool-call',
    );
    const toolResult = AgentConversationMessage(
      id: 'tool-2',
      role: 'function_call_output',
      text: 'fixture output',
      createdAt: '2026-01-01T00:00:02Z',
      cardType: 'tool-result',
    );
    const assistant = AgentConversationMessage(
      id: 'assistant-1',
      role: 'assistant',
      text: 'Done',
      createdAt: '2026-01-01T00:00:03Z',
      stableIdentity: 'stable-assistant',
    );

    final first = buildConversationTimelineItems(
      const [user, toolCall, toolResult, assistant],
      'fixture-session',
      historyTruncated: true,
    );
    final second = buildConversationTimelineItems(
      const [user, toolCall, toolResult, assistant],
      'fixture-session',
      historyTruncated: true,
    );

    expect(first, hasLength(4));
    expect(first[0], isA<ConversationTruncationTimelineItem>());
    expect(first[1], isA<ConversationMessageTimelineItem>());
    final process = first[2] as ConversationProcessTimelineItem;
    expect(process.events, containsAll(const [toolCall, toolResult]));
    expect(process.events, hasLength(2));
    expect(first[3], isA<ConversationMessageTimelineItem>());
    expect(
      first.map((item) => item.storageKey),
      orderedEquals(second.map((item) => item.storageKey)),
    );
    expect(first.map((item) => item.storageKey).toSet(), hasLength(4));
    expect(() => first.add(first.first), throwsUnsupportedError);
    expect(() => process.events.add(toolCall), throwsUnsupportedError);
  });

  testWidgets('process card delegates event details through its render port', (
    tester,
  ) async {
    const event = AgentConversationMessage(
      id: 'tool-fixture',
      role: 'function_call',
      text: 'bounded fixture details',
      createdAt: '2026-01-01T00:00:01Z',
      cardType: 'tool-call',
      cardTitle: 'Fixture operation',
    );

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ConversationProcessCard(
              events: const [event],
              adapter: AgentRenderAdapter.fallback(),
              detailsBuilder:
                  ({
                    required data,
                    required foreground,
                    required accent,
                    required codeBackground,
                    required blockBackground,
                    required borderColor,
                    required renderStyle,
                  }) => Text(data, key: const Key('fixture-event-details')),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('fixture-event-details')), findsNothing);
    await tester.tap(
      find.byKey(const Key('conversation-process-toggle-tool-fixture')),
    );
    await tester.pump();

    expect(find.byKey(const Key('fixture-event-details')), findsOneWidget);
    expect(find.text('bounded fixture details'), findsOneWidget);
  });
}
