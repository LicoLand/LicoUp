import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_header.dart';
import '../agent_conversation_pane/pane_test_harness.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('switcher lists only the current agent conversations in recency '
      'order', (tester) async {
    await _pumpSwitcher(
      tester,
      sessions: [
        _session('session-old', 'Older session', const Duration(hours: 2)),
        _session('session-new', 'Fresh session', const Duration(minutes: 5)),
      ],
    );

    await tester.tap(
      find.byKey(const Key('messaging-conversation-switcher-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const Key('messaging-conversation-switcher-content')),
      findsOneWidget,
    );
    final fresh = tester.getTopLeft(
      find.byKey(const Key('messaging-switcher-session-new')),
    );
    final older = tester.getTopLeft(
      find.byKey(const Key('messaging-switcher-session-old')),
    );
    expect(fresh.dy, lessThan(older.dy));
    expect(find.text('fresh preview · project-alpha'), findsOneWidget);
    expect(find.text('5m'), findsOneWidget);
    expect(find.text('2h'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switcher selects a conversation and closes the panel', (
    tester,
  ) async {
    final selected = <String>[];
    await _pumpSwitcher(
      tester,
      sessions: [
        _session('session-old', 'Older session', const Duration(hours: 2)),
        _session('session-new', 'Fresh session', const Duration(minutes: 5)),
      ],
      onSelectConversation: selected.add,
    );

    await tester.tap(
      find.byKey(const Key('messaging-conversation-switcher-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('messaging-switcher-session-old')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(selected, ['session-old']);
    expect(
      find.byKey(const Key('messaging-conversation-switcher-content')),
      findsNothing,
    );
  });

  testWidgets('switcher new-conversation row starts a fresh conversation', (
    tester,
  ) async {
    var started = 0;
    await _pumpSwitcher(
      tester,
      sessions: [
        _session('session-new', 'Fresh session', const Duration(minutes: 5)),
      ],
      onNewConversation: () => started += 1,
    );

    await tester.tap(
      find.byKey(const Key('messaging-conversation-switcher-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(
      find.byKey(const Key('messaging-switcher-new-conversation')),
    );
    await tester.pump();

    expect(started, 1);
    expect(
      find.byKey(const Key('messaging-conversation-switcher-content')),
      findsNothing,
    );
  });

  testWidgets('switcher marks the running conversation', (tester) async {
    final running = _session(
      'session-running',
      'Running session',
      const Duration(minutes: 1),
    );
    await _pumpSwitcher(
      tester,
      sessions: [
        running,
        _session('session-idle', 'Idle session', const Duration(minutes: 9)),
      ],
      runningFor: (session) => session.id == 'session-running',
    );

    await tester.tap(
      find.byKey(const Key('messaging-conversation-switcher-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const Key('messaging-switcher-running-dot')),
      findsOneWidget,
    );
  });

  testWidgets('header renders switcher and details toggles together', (
    tester,
  ) async {
    await _pumpSwitcher(
      tester,
      sessions: [
        _session('session-new', 'Fresh session', const Duration(minutes: 5)),
      ],
    );

    expect(
      find.byKey(const Key('messaging-conversation-switcher-button')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('messaging-details-toggle')), findsOneWidget);
  });

  testWidgets('selected switcher row renders solid accent with dark text', (
    tester,
  ) async {
    await _pumpSwitcher(
      tester,
      sessions: [
        _session('session-new', 'Fresh session', const Duration(minutes: 5)),
        _session('session-old', 'Older session', const Duration(hours: 2)),
      ],
    );

    await tester.tap(
      find.byKey(const Key('messaging-conversation-switcher-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final colors = tester
        .element(
          find.byKey(const Key('messaging-conversation-switcher-content')),
        )
        .licoColors;
    final selectedRow = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byKey(const Key('messaging-switcher-session-new')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect((selectedRow.decoration! as BoxDecoration).color, colors.primary);
    final title = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const Key('messaging-switcher-session-new')),
            matching: find.text('Fresh session'),
          )
          .first,
    );
    expect(title.style?.color, colors.textOnPrimary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile header opens the switcher as a bottom sheet', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: MessagingConversationHeader(
            target: TargetCandidate(
              target: 'codex',
              label: 'Codex',
              kind: 'cli',
              status: 'detected',
              configured: true,
              confidence: 1,
              adapterStatus: 'implemented',
            ),
            session: _session(
              'session-new',
              'Fresh session',
              const Duration(minutes: 5),
            ),
            detailsState: paneTestState(
              session: _session(
                'session-new',
                'Fresh session',
                const Duration(minutes: 5),
              ),
            ),
            detailsActions: paneTestActions(),
            switcherSessions: [
              _session(
                'session-new',
                'Fresh session',
                const Duration(minutes: 5),
              ),
            ],
            switcherSelectedSessionId: 'session-new',
            onSwitchConversation: (_) {},
            onSwitchNewConversation: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('messaging-conversation-switcher-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const Key('messaging-conversation-switcher-content')),
      findsOneWidget,
    );
    expect(find.text('Fresh session'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switcher panel anchors under the trailing trigger, not a '
      'window corner', (tester) async {
    await _pumpSwitcher(
      tester,
      sessions: [
        _session('session-new', 'Fresh session', const Duration(minutes: 5)),
        _session('session-old', 'Older session', const Duration(hours: 2)),
      ],
    );

    await tester.tap(
      find.byKey(const Key('messaging-conversation-switcher-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final trigger = tester.getRect(
      find.byKey(const Key('messaging-conversation-switcher-button')),
    );
    final panel = tester.getRect(
      find.byKey(const Key('messaging-conversation-switcher-panel')),
    );

    expect(panel.width, closeTo(320, 0.5));
    // Popover top-right meets the trigger bottom-right plus the 6px gap.
    expect(panel.right, closeTo(trigger.right, 0.5));
    expect(panel.top, closeTo(trigger.bottom + 6, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('details panel anchors under its own trailing trigger', (
    tester,
  ) async {
    await _pumpSwitcher(
      tester,
      sessions: [
        _session('session-new', 'Fresh session', const Duration(minutes: 5)),
      ],
    );

    await tester.tap(find.byKey(const Key('messaging-details-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final trigger = tester.getRect(
      find.byKey(const Key('messaging-details-toggle')),
    );
    final panel = tester.getRect(
      find.byKey(const Key('messaging-details-popover-panel')),
    );

    expect(panel.right, closeTo(trigger.right, 0.5));
    expect(panel.top, closeTo(trigger.bottom + 6, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('details toggle opens hover card with session metadata', (
    tester,
  ) async {
    await _pumpSwitcher(
      tester,
      sessions: [
        _session('session-new', 'Fresh session', const Duration(minutes: 5)),
      ],
    );

    expect(find.byKey(const Key('messaging-details-popover')), findsNothing);
    await tester.tap(find.byKey(const Key('messaging-details-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const Key('messaging-details-popover-panel')),
      findsOneWidget,
    );
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('RUNTIME'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

AgentConversationSession _session(
  String id,
  String title,
  Duration updatedAgo,
) {
  final updatedAt = DateTime.now()
      .subtract(updatedAgo)
      .toUtc()
      .toIso8601String();
  return AgentConversationSession(
    id: id,
    agentId: 'codex',
    title: title,
    createdAt: updatedAt,
    updatedAt: updatedAt,
    messages: const [],
    workingDirectory: id == 'session-new' ? '/work/project-alpha' : '',
    cachedPreview: id == 'session-new' ? 'fresh preview' : '',
  );
}

Future<void> _pumpSwitcher(
  WidgetTester tester, {
  required List<AgentConversationSession> sessions,
  ValueChanged<String>? onSelectConversation,
  VoidCallback? onNewConversation,
  bool Function(AgentConversationSession session)? runningFor,
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
      theme: buildLicoTheme(
        platformBrightness: Brightness.dark,
      ).copyWith(platform: TargetPlatform.macOS),
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: Align(
            alignment: Alignment.topCenter,
            child: MessagingConversationHeader(
              target: TargetCandidate(
                target: 'codex',
                label: 'Codex',
                kind: 'cli',
                status: 'detected',
                configured: true,
                confidence: 1,
                adapterStatus: 'implemented',
              ),
              session: sessions.first,
              detailsState: paneTestState(session: sessions.first),
              detailsActions: paneTestActions(),
              switcherSessions: sessions,
              switcherSelectedSessionId: sessions.first.id,
              onSwitchConversation: onSelectConversation ?? (_) {},
              onSwitchNewConversation: onNewConversation ?? () {},
              switcherRunningFor: runningFor,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
