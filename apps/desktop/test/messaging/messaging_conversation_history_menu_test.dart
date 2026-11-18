import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_history_menu.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  // Pin the conversation clock so time buckets stay deterministic.
  final fixtureNow = DateTime(2026, 10, 12, 12);
  setUpAll(() => conversationNow = () => fixtureNow);
  tearDownAll(() => conversationNow = DateTime.now);
  testWidgets('history menu groups by project name then time bucket', (
    tester,
  ) async {
    final selected = <String>[];
    var newCount = 0;
    await _pump(
      tester,
      sessions: [
        _session(
          'session-today',
          'Today fix',
          updatedAgo: const Duration(hours: 1),
          workingDirectory: '/workspace/licoup',
        ),
        _session(
          'session-yesterday',
          'Yesterday refactor',
          updatedAgo: const Duration(days: 1, hours: 1),
          workingDirectory: '/workspace/licoup',
        ),
        _session(
          'session-other-project',
          'Playground thread',
          updatedAgo: const Duration(hours: 2),
          workingDirectory: '/work/playground',
        ),
        _session(
          'session-no-project',
          'Detached thread',
          updatedAgo: const Duration(days: 40),
        ),
      ],
      onSelect: selected.add,
      onNewConversation: () => newCount += 1,
    );

    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('messaging-conversation-history-menu')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-history-new-conversation')),
      findsOneWidget,
    );
    // Project headers show only the final path segment — never the full path.
    expect(find.text('licoup'), findsOneWidget);
    expect(find.text('playground'), findsOneWidget);
    expect(find.text('No project'), findsOneWidget);
    expect(find.text('/workspace/licoup'), findsNothing);
    expect(find.text('/work/playground'), findsNothing);
    // Time buckets nest inside their project.
    expect(find.text('Today'), findsWidgets);
    // Bucket headers are the 10.5px w700 labels; the row timestamp may also
    // read 'Yesterday' under the demo's clock format.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == 'Yesterday' &&
            widget.style?.fontWeight == FontWeight.w700,
      ),
      findsOneWidget,
    );
    expect(find.text('Earlier'), findsOneWidget);
    expect(find.text('Today fix'), findsOneWidget);
    expect(find.text('Yesterday refactor'), findsOneWidget);
    expect(find.text('Playground thread'), findsOneWidget);
    expect(find.text('Detached thread'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('messaging-history-session-session-yesterday')),
    );
    await tester.pumpAndSettle();
    expect(selected, ['session-yesterday']);
    expect(
      find.byKey(const Key('messaging-conversation-history-menu')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('messaging-history-new-conversation')),
    );
    await tester.pumpAndSettle();
    expect(newCount, 1);
  });

  testWidgets('sub-agent threads never appear as history rows', (tester) async {
    await _pump(
      tester,
      sessions: [
        _session(
          'session-parent',
          'Parent thread',
          updatedAgo: const Duration(hours: 3),
          workingDirectory: '/workspace/licoup',
        ),
        _session(
          'session-child',
          'Sub-agent thread',
          updatedAgo: Duration.zero,
          parentSessionId: 'session-parent',
          workingDirectory: '/workspace/licoup',
        ),
      ],
      onSelect: (_) {},
    );

    await tester.tap(find.byKey(const Key('open-history')));
    await tester.pumpAndSettle();

    expect(find.text('Parent thread'), findsOneWidget);
    expect(find.text('Sub-agent thread'), findsNothing);
    expect(
      find.byKey(const Key('messaging-history-session-session-child')),
      findsNothing,
    );
  });

  testWidgets(
    'member history omits the new-conversation row and marks selected',
    (tester) async {
      await _pump(
        tester,
        sessions: [
          _session(
            'session-in-group',
            'In-group thread',
            updatedAgo: const Duration(hours: 2),
          ),
        ],
        selectedSessionId: 'session-in-group',
        onSelect: (_) {},
      );

      await tester.tap(find.byKey(const Key('open-history')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('messaging-history-new-conversation')),
        findsNothing,
      );
      final row = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(
            const Key('messaging-history-session-session-in-group'),
          ),
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect((row.decoration! as BoxDecoration).color, Colors.transparent);
      expect(
        find.descendant(
          of: find.byKey(
            const Key('messaging-history-session-session-in-group'),
          ),
          matching: find.byWidgetPredicate(
            (w) =>
                w is CustomPaint && w.painter is LicoSelectionHighlightPainter,
          ),
        ),
        findsOneWidget,
      );
    },
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required List<AgentConversationSession> sessions,
  required ValueChanged<String> onSelect,
  String selectedSessionId = '',
  VoidCallback? onNewConversation,
}) async {
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
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('open-history'),
              onPressed: () => showMessagingConversationHistoryMenu(
                context: context,
                globalPosition: const Offset(20, 20),
                sessions: sessions,
                selectedSessionId: selectedSessionId,
                onSelect: onSelect,
                onNewConversation: onNewConversation,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

AgentConversationSession _session(
  String id,
  String title, {
  required Duration updatedAgo,
  String workingDirectory = '',
  String parentSessionId = '',
  String preview = '',
}) {
  final stamp = conversationNow()
      .subtract(updatedAgo)
      .toUtc()
      .toIso8601String();
  return AgentConversationSession(
    id: id,
    agentId: 'codex',
    title: title,
    createdAt: stamp,
    updatedAt: stamp,
    messages: const [],
    workingDirectory: workingDirectory,
    cachedPreview: preview,
    parentSessionId: parentSessionId,
  );
}
