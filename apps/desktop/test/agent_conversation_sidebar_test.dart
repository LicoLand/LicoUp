import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_conversation_tab_activity.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conversation display names drop delivery-channel suffixes', () {
    expect(
      agentConversationTargetDisplayName(
        _target('codex', 'ChatGPT Codex - CLI'),
      ),
      'Codex',
    );
    expect(
      agentConversationTargetDisplayName(_target('kimi', 'Kimi - Desktop')),
      'Kimi',
    );
    expect(
      agentConversationTargetDisplayName(
        _target('custom-tool', 'My Tool - Plugin'),
      ),
      'My Tool',
    );
    expect(
      agentConversationTargetDisplayName(_target('custom-tool', '')),
      'custom-tool',
    );
  });

  testWidgets('sidebar merges targets from the same source into one entry', (
    tester,
  ) async {
    final selectedAgents = <String>[];
    final selectedSessions = <(String, String)>[];
    await _pumpSidebar(
      tester,
      targets: [
        _target('codex', 'ChatGPT Codex - CLI'),
        _target('codex-desktop', 'Codex - Desktop'),
        _target('kimi-code', 'Kimi Code - CLI'),
      ],
      sessionsByAgent: {
        'codex': [_session('session-cli', 'codex', 'CLI session')],
        'codex-desktop': [
          _session('session-desktop', 'codex-desktop', 'Desktop session'),
        ],
      },
      onSelectAgent: selectedAgents.add,
      onSelectSession: (agentId, sessionId) =>
          selectedSessions.add((agentId, sessionId)),
    );

    // One merged row per product, without channel suffixes.
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Kimi Code'), findsOneWidget);
    expect(find.text('ChatGPT Codex - CLI'), findsNothing);
    expect(find.text('Codex - Desktop'), findsNothing);
    expect(find.text('Kimi Code - CLI'), findsNothing);

    // Expanding the merged row selects the representative target and lists
    // sessions from every member under one project group.
    await tester.tap(find.text('Codex'));
    await tester.pump();
    expect(selectedAgents, ['codex']);

    await tester.tap(find.text('未关联项目'));
    await tester.pump();
    expect(find.text('CLI session'), findsOneWidget);
    expect(find.text('Desktop session'), findsOneWidget);

    // Selecting a session routes to the member that owns it.
    await tester.tap(find.text('Desktop session'));
    await tester.pump();
    expect(selectedSessions, [('codex-desktop', 'session-desktop')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar keeps distinct products as separate entries', (
    tester,
  ) async {
    await _pumpSidebar(
      tester,
      targets: [
        _target('kimi', 'Kimi - Desktop'),
        _target('kimi-code', 'Kimi Code - CLI'),
      ],
      sessionsByAgent: const {},
      onSelectAgent: (_) {},
      onSelectSession: (_, _) {},
    );

    expect(find.text('Kimi'), findsOneWidget);
    expect(find.text('Kimi Code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar folds older conversations into an archived tail group', (
    tester,
  ) async {
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'ChatGPT Codex - CLI')],
      sessionsByAgent: {
        'codex': [
          _session('recent', 'codex', 'Recent session'),
          _session('old-1', 'codex', 'Old session one', updatedDaysAgo: 30),
          _session('old-2', 'codex', 'Old session two', updatedDaysAgo: 60),
        ],
      },
      onSelectAgent: (_) {},
      onSelectSession: (_, _) {},
    );

    await tester.tap(find.text('Codex'));
    await tester.pump();
    await tester.tap(find.text('未关联项目'));
    await tester.pump();

    expect(find.text('Recent session'), findsOneWidget);
    expect(find.text('Old session one'), findsNothing);
    expect(find.text('Old session two'), findsNothing);
    expect(find.text('已归档 · 2'), findsOneWidget);

    await tester.tap(find.text('已归档 · 2'));
    await tester.pump();

    expect(find.text('Old session one'), findsOneWidget);
    expect(find.text('Old session two'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('archived but selected session stays in the archived group', (
    tester,
  ) async {
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'ChatGPT Codex - CLI')],
      sessionsByAgent: {
        'codex': [
          _session('selected-old', 'codex', 'Selected old session', updatedDaysAgo: 45),
        ],
      },
      selectedSessionId: 'selected-old',
      onSelectAgent: (_) {},
      onSelectSession: (_, _) {},
    );

    await tester.tap(find.text('Codex'));
    await tester.pump();

    // Archive membership is purely time-based: the selected old session stays
    // inside the archived group instead of jumping to the ungrouped project.
    expect(find.text('未关联项目'), findsNothing);
    expect(find.text('已归档 · 1'), findsOneWidget);

    await tester.tap(find.text('已归档 · 1'));
    await tester.pump();

    expect(find.text('Selected old session'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('session activity window classification', () {
    final now = DateTime(2026, 7, 20, 12);
    String daysAgo(int days) => now
        .subtract(Duration(days: days))
        .toUtc()
        .toIso8601String();
    final recent = _session('a', 'codex', 'a', updatedDaysAgo: 2);
    final stale = AgentConversationSession(
      id: 'b',
      agentId: 'codex',
      title: 'b',
      createdAt: daysAgo(30),
      updatedAt: daysAgo(30),
      messages: const [],
    );
    final unknown = AgentConversationSession(
      id: 'c',
      agentId: 'codex',
      title: 'c',
      createdAt: '',
      updatedAt: '',
      messages: const [],
    );

    expect(
      agentConversationSessionIsActive(recent, now: DateTime.now()),
      isTrue,
    );
    expect(agentConversationSessionIsActive(stale, now: now), isFalse);
    expect(agentConversationSessionIsActive(unknown, now: now), isTrue);
  });
}

TargetCandidate _target(String target, String label) {
  return TargetCandidate(
    target: target,
    label: label,
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'implemented',
  );
}

AgentConversationSession _session(
  String id,
  String agentId,
  String title, {
  int updatedDaysAgo = 1,
}) {
  final updatedAt = DateTime.now()
      .subtract(Duration(days: updatedDaysAgo))
      .toUtc()
      .toIso8601String();
  return AgentConversationSession(
    id: id,
    agentId: agentId,
    title: title,
    createdAt: updatedAt,
    updatedAt: updatedAt,
    messages: const [],
  );
}

Future<void> _pumpSidebar(
  WidgetTester tester, {
  required List<TargetCandidate> targets,
  required Map<String, List<AgentConversationSession>> sessionsByAgent,
  required ValueChanged<String> onSelectAgent,
  required void Function(String agentId, String sessionId) onSelectSession,
  String selectedSessionId = '',
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
          width: 320,
          height: 600,
          child: AgentsWorkspaceSidebar(
            targets: targets,
            sessionsByAgent: sessionsByAgent,
            selectedAgentId: '',
            selectedSessionId: selectedSessionId,
            activityFor: (_) => AgentConversationTabActivity.none,
            onSelectAgent: onSelectAgent,
            onSelectSession: onSelectSession,
            onNewConversation: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
