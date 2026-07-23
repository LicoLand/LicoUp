import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_recent_sessions.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
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
    expect(find.text('Fix the loop guard'), findsOneWidget);
    expect(find.text('Search the repository'), findsOneWidget);
    expect(find.text('停止你的 loop'), findsOneWidget);

    await tester.tap(find.byKey(const Key('agent-conversation-recent-s-2')));
    await tester.pump();
    expect(selected, ['s-2']);
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
  bool loading = false,
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
          width: 720,
          height: 600,
          child: AgentConversationRecentSessions(
            sessions: sessions,
            loading: loading,
            onSelectSession: onSelectSession,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
