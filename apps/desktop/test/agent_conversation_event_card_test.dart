import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_event_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_log_event_row.dart';
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

  test('timeline separates bookkeeping logs from agent activity', () {
    const lifecycle = AgentConversationMessage(
      id: 'lifecycle',
      role: 'event',
      text: 'thinking',
      createdAt: '2026-01-01T00:00:01Z',
      cardType: 'lifecycle',
    );
    const reasoning = AgentConversationMessage(
      id: 'reasoning',
      role: 'reasoning',
      text: 'safe summary',
      createdAt: '2026-01-01T00:00:02Z',
    );
    const firstLog = AgentConversationMessage(
      id: 'log-1',
      role: 'event',
      text: 'provider bookkeeping',
      createdAt: '2026-01-01T00:00:03Z',
      cardType: 'provider-event',
    );
    const secondLog = AgentConversationMessage(
      id: 'log-2',
      role: 'metadata',
      text: 'provider metadata',
      createdAt: '2026-01-01T00:00:04Z',
    );

    final items = buildConversationTimelineItems(const [
      lifecycle,
      firstLog,
      reasoning,
      secondLog,
    ], 'log-fixture');

    expect(items, hasLength(2));
    expect((items.first as ConversationProcessTimelineItem).events, [
      lifecycle,
      reasoning,
    ]);
    expect((items.last as ConversationLogTimelineItem).events, [
      firstLog,
      secondLog,
    ]);
  });

  testWidgets('runtime logs render as a quiet row instead of a process card', (
    tester,
  ) async {
    const events = [
      AgentConversationMessage(
        id: 'log-fixture',
        role: 'event',
        text: 'provider bookkeeping',
        createdAt: '2026-01-01T00:00:01Z',
        cardType: 'provider-event',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: const Scaffold(body: ConversationLogEventRow(events: events)),
      ),
    );

    expect(find.text('Runtime log · 1 entry'), findsOneWidget);
    expect(find.byType(ConversationProcessCard), findsNothing);
  });

  test('runtime update card is its own timeline item with a stable key', () {
    const lifecycle = AgentConversationMessage(
      id: 'lifecycle',
      role: 'event',
      text: 'accepted',
      createdAt: '2026-01-01T00:00:01Z',
      cardType: 'lifecycle',
    );
    const updateDownloading = AgentConversationMessage(
      id: 'turn-runtime-update',
      role: 'event',
      text: 'downloading',
      createdAt: '2026-01-01T00:00:02Z',
      cardType: 'runtime-update',
      cardSubtitle: 'Cursor Agent 正在更新 2026.08.04 · 下载中',
      stableIdentity: 'turn-runtime-update',
    );
    const updateInstalling = AgentConversationMessage(
      id: 'turn-runtime-update',
      role: 'event',
      text: 'installing',
      createdAt: '2026-01-01T00:00:02Z',
      cardType: 'runtime-update',
      cardSubtitle: 'Cursor Agent 正在更新 2026.08.04 · 安装中',
      stableIdentity: 'turn-runtime-update',
    );
    const assistant = AgentConversationMessage(
      id: 'assistant-1',
      role: 'assistant',
      text: 'Done',
      createdAt: '2026-01-01T00:00:03Z',
      stableIdentity: 'stable-assistant',
    );

    final first = buildConversationTimelineItems(const [
      lifecycle,
      updateDownloading,
      assistant,
    ], 'update-fixture');
    expect(first, hasLength(3));
    expect(first[0], isA<ConversationProcessTimelineItem>());
    final card = first[1] as ConversationRuntimeUpdateTimelineItem;
    expect(card.message.cardSubtitle, contains('下载中'));
    expect(first[2], isA<ConversationMessageTimelineItem>());

    // Phase upserts keep the same storage key (in-place card, no churn).
    final second = buildConversationTimelineItems(const [
      lifecycle,
      updateInstalling,
      assistant,
    ], 'update-fixture');
    final secondCard = second[1] as ConversationRuntimeUpdateTimelineItem;
    expect(secondCard.storageKey, card.storageKey);
    expect(secondCard.message.cardSubtitle, contains('安装中'));
  });
}
