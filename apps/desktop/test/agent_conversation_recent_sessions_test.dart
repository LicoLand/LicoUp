import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_recent_sessions.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('recent sessions home lists rows and forwards taps', (
    tester,
  ) async {
    final selected = <String>[];
    await _pumpRecentSessions(
      tester,
      sessions: [
        _session('s-1', 'Fix the loop guard'),
        _session('s-2', 'Search the repository'),
        _session('s-3', '停止你的 loop'),
      ],
      onSelectSession: selected.add,
    );

    expect(find.text('最近对话'), findsOneWidget);
    expect(find.text('新对话'), findsOneWidget);
    expect(find.text('Fix the loop guard'), findsOneWidget);
    expect(find.text('Search the repository'), findsOneWidget);
    expect(find.text('停止你的 loop'), findsOneWidget);

    await tester.tap(find.byKey(const Key('agent-conversation-recent-s-2')));
    await tester.pump();
    expect(selected, ['s-2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recent sessions home is split and renders every loaded row', (
    tester,
  ) async {
    final sessions = [
      for (var index = 1; index <= 12; index += 1)
        _session('s-$index', 'Conversation $index'),
    ];
    await _pumpRecentSessions(
      tester,
      sessions: sessions,
      width: 900,
      onSelectSession: (_) {},
    );

    expect(
      find.byKey(const Key('agent-conversation-home-split')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-conversation-home-new-conversation')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(
            find.byKey(const Key('agent-conversation-home-new-conversation')),
          )
          .height,
      36,
    );
    final recentList = tester.widget<ListView>(
      find.byKey(const Key('agent-conversation-recent-list')),
    );
    expect(
      recentList.childrenDelegate.estimatedChildCount,
      (sessions.length * 2) - 1,
    );
    expect(
      find.byKey(const Key('agent-conversation-recent-divider-0')),
      findsOneWidget,
    );

    final actionX = tester
        .getTopLeft(
          find.byKey(const Key('agent-conversation-home-new-conversation')),
        )
        .dx;
    final listX = tester
        .getTopLeft(find.byKey(const Key('agent-conversation-recent-section')))
        .dx;
    expect(actionX, lessThan(listX));

    await tester.scrollUntilVisible(
      find.byKey(const Key('agent-conversation-recent-s-10')),
      180,
      scrollable: find.descendant(
        of: find.byKey(const Key('agent-conversation-recent-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('Conversation 10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling to the end requests one next page', (tester) async {
    var loadMoreCount = 0;
    await _pumpRecentSessions(
      tester,
      sessions: [
        for (var index = 1; index <= 10; index += 1)
          _session('s-$index', 'Conversation $index'),
      ],
      width: 900,
      height: 360,
      hasMore: true,
      onLoadMore: () => loadMoreCount += 1,
      onSelectSession: (_) {},
    );

    await tester.drag(
      find.byKey(const Key('agent-conversation-recent-list')),
      const Offset(0, -500),
    );
    await tester.pump();

    expect(loadMoreCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('next-page loading keeps a visible moving indicator', (
    tester,
  ) async {
    await _pumpRecentSessions(
      tester,
      sessions: [
        for (var index = 1; index <= 10; index += 1)
          _session('s-$index', 'Conversation $index'),
      ],
      width: 900,
      height: 360,
      hasMore: true,
      loadingMore: true,
      onSelectSession: (_) {},
    );

    await tester.drag(
      find.byKey(const Key('agent-conversation-recent-list')),
      const Offset(0, -500),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('agent-conversation-recent-loading-more')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('new conversation card forwards taps', (tester) async {
    var tapped = false;
    await _pumpRecentSessions(
      tester,
      sessions: [_session('s-1', 'Existing conversation')],
      onNewConversation: () => tapped = true,
      onSelectSession: (_) {},
    );

    await tester.tap(
      find.byKey(const Key('agent-conversation-home-new-conversation')),
    );
    await tester.pump();
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recent sessions home shows progress while loading', (
    tester,
  ) async {
    await _pumpRecentSessions(
      tester,
      sessions: const [],
      loading: true,
      onSelectSession: (_) {},
    );

    expect(
      find.byKey(const Key('agent-conversation-recent-loading')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('recent sessions home shows empty label without history', (
    tester,
  ) async {
    await _pumpRecentSessions(
      tester,
      sessions: const [],
      onSelectSession: (_) {},
    );

    expect(find.text('暂无原生智能体历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('running recent conversation shows the shared activity spinner', (
    tester,
  ) async {
    await _pumpRecentSessions(
      tester,
      sessions: [_session('running-session', 'Active work')],
      runningSessionIds: const {'running-session'},
      onSelectSession: (_) {},
    );

    expect(
      find.byKey(
        const Key('agent-conversation-recent-running-running-session'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

AgentConversationSession _session(String id, String title) {
  final updatedAt = DateTime.now()
      .subtract(const Duration(hours: 2))
      .toUtc()
      .toIso8601String();
  return AgentConversationSession(
    id: id,
    agentId: 'codex',
    title: title,
    createdAt: updatedAt,
    updatedAt: updatedAt,
    cachedPreview: 'Preview of $title',
    messages: const [],
  );
}

Future<void> _pumpRecentSessions(
  WidgetTester tester, {
  required List<AgentConversationSession> sessions,
  required ValueChanged<String> onSelectSession,
  Set<String> runningSessionIds = const {},
  bool loading = false,
  bool hasMore = false,
  bool loadingMore = false,
  VoidCallback? onNewConversation,
  VoidCallback? onLoadMore,
  double width = 720,
  double height = 600,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: height,
          child: AgentConversationRecentSessions(
            sessions: sessions,
            runningSessionIds: runningSessionIds,
            loading: loading,
            hasMore: hasMore,
            loadingMore: loadingMore,
            onNewConversation: onNewConversation ?? () {},
            onSelectSession: onSelectSession,
            onLoadMore: onLoadMore,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
