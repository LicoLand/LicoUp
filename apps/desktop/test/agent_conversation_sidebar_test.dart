import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native running fact survives session projection copies', () {
    final session = AgentConversationSession.fromJson({
      'id': 'running',
      'agentId': 'codex',
      'title': 'Running',
      'running': true,
      'messages': const <Object?>[],
    });

    expect(session.running, isTrue);
    expect(session.withTitle('Renamed').running, isTrue);
    expect(session.withWorkingDirectory('/fixture').running, isTrue);
    expect(session.toJson()['running'], isTrue);
  });

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

  test('compact conversation names use local narrow-surface defaults', () {
    expect(
      agentConversationTargetCompactDisplayName(
        _target('github-copilot', 'GitHub Copilot'),
      ),
      'Copilot',
    );
    expect(
      agentConversationTargetCompactDisplayName(
        _target('claude-code', 'Claude Code'),
      ),
      'Claude',
    );
    expect(
      agentConversationTargetCompactDisplayName(
        _target('kimi-code', 'Kimi Code'),
      ),
      'Kimi',
    );
    expect(
      agentConversationTargetCompactDisplayName(
        _target('custom-tool', 'My Custom Tool'),
      ),
      'My Custom Tool',
    );
  });

  test('sidebar time groups follow local calendar boundaries', () {
    // 2026-07-30 is a Thursday; 2026-07-27 is the Monday of the same week.
    final now = DateTime(2026, 7, 30, 15);
    expect(
      sidebarTimeGroupFor(DateTime(2026, 7, 30, 9), now),
      SidebarTimeGroup.today,
    );
    expect(
      sidebarTimeGroupFor(DateTime(2026, 7, 29, 23), now),
      SidebarTimeGroup.yesterday,
    );
    expect(
      sidebarTimeGroupFor(DateTime(2026, 7, 28, 12), now),
      SidebarTimeGroup.weekday,
    );
    expect(
      sidebarTimeGroupFor(DateTime(2026, 7, 27, 0, 1), now),
      SidebarTimeGroup.weekday,
    );
    // Sunday belongs to the previous week and folds into Earlier.
    expect(
      sidebarTimeGroupFor(DateTime(2026, 7, 26, 23), now),
      SidebarTimeGroup.earlier,
    );
    expect(
      sidebarTimeGroupFor(DateTime(2026, 6, 1, 12), now),
      SidebarTimeGroup.earlier,
    );
  });

  testWidgets('flat list shows merged-product sessions with one brand', (
    tester,
  ) async {
    final selectedSessions = <(String, String)>[];
    await _pumpSidebar(
      tester,
      targets: [
        _target('codex', 'ChatGPT Codex - CLI'),
        _target('codex-desktop', 'Codex - Desktop'),
        _target('kimi-code', 'Kimi Code - CLI'),
      ],
      sessionsByAgent: {
        'codex': [
          _session(
            'session-cli',
            'codex',
            'CLI session',
            // 23h keeps the row inside today/yesterday, so it renders no
            // matter which weekday the suite runs on; anything older can
            // land in the collapsed Earlier group before the week's Monday.
            updatedHoursAgo: 23,
            workingDirectory: '/work/alpha',
          ),
        ],
        'codex-desktop': [
          _session(
            'session-desktop',
            'codex-desktop',
            'Desktop session',
            updatedHoursAgo: 2,
            workingDirectory: '/work/beta',
          ),
        ],
      },
      onSelectSession: (agentId, sessionId) =>
          selectedSessions.add((agentId, sessionId)),
    );

    // No agent rows and no project tree: every conversation is a flat row.
    expect(find.text('Codex'), findsNothing);
    expect(find.text('CLI session'), findsOneWidget);
    expect(find.text('Desktop session'), findsOneWidget);
    expect(find.text('未关联项目'), findsNothing);

    // Both merged rows carry the group representative's brand icon.
    final brandIcons = tester
        .widgetList<AgentBrandIcon>(find.byType(AgentBrandIcon))
        .toList();
    expect(brandIcons, isNotEmpty);
    expect(
      brandIcons.every((icon) => icon.target.target == 'codex'),
      isTrue,
      reason: 'merged products share the first target as the brand',
    );

    // Newest first: the desktop session (2h old) precedes the CLI one (23h).
    final desktopDy = tester.getTopLeft(find.text('Desktop session')).dy;
    final cliDy = tester.getTopLeft(find.text('CLI session')).dy;
    expect(desktopDy, lessThan(cliDy));

    // Tapping routes to the map-key owner, not the group representative.
    await tester.tap(find.text('Desktop session'));
    await tester.pump();
    expect(selectedSessions, [('codex-desktop', 'session-desktop')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flat list renders time-group headers for synthetic dates', (
    tester,
  ) async {
    // Date-component timestamps (noon of each calendar day) keep every row
    // in its intended group no matter what hour the suite runs at.
    final now = DateTime.now();
    String atNoon(int dayOffset) => DateTime(
      now.year,
      now.month,
      now.day - dayOffset,
      12,
    ).toUtc().toIso8601String();
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'Codex')],
      sessionsByAgent: {
        'codex': [
          _session('s-today', 'codex', 'Today session', updatedAt: atNoon(0)),
          _session(
            's-yesterday',
            'codex',
            'Yesterday session',
            updatedAt: atNoon(1),
          ),
          _session('s-week', 'codex', 'Week session', updatedAt: atNoon(3)),
          _session('s-old', 'codex', 'Old session', updatedAt: atNoon(40)),
        ],
      },
      onSelectSession: (_, _) {},
    );

    String expectedHeader(int daysAgo) {
      final updated = DateTime(now.year, now.month, now.day - daysAgo, 12);
      return switch (sidebarTimeGroupFor(updated, now)) {
        SidebarTimeGroup.today => '今天',
        SidebarTimeGroup.yesterday => '昨天',
        SidebarTimeGroup.weekday => const [
          '星期一',
          '星期二',
          '星期三',
          '星期四',
          '星期五',
          '星期六',
          '星期日',
        ][updated.weekday - 1],
        SidebarTimeGroup.earlier => '更早',
      };
    }

    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    expect(find.text(expectedHeader(3)), findsOneWidget);
    expect(find.text('更早'), findsOneWidget);
    // Earlier starts collapsed: the 40-day-old row waits behind the toggle.
    expect(find.text('Old session'), findsNothing);
    await tester.tap(find.byKey(const Key('agents-sidebar-earlier-toggle')));
    await tester.pump();

    // Groups land newest-first and rows stay newest-first across the list.
    final order = [
      'Today session',
      'Yesterday session',
      'Week session',
      'Old session',
    ].map((title) => tester.getTopLeft(find.text(title)).dy).toList();
    for (var index = 1; index < order.length; index += 1) {
      expect(order[index - 1], lessThan(order[index]));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('flat list keeps distinct products as separate brand icons', (
    tester,
  ) async {
    await _pumpSidebar(
      tester,
      targets: [
        _target('kimi', 'Kimi - Desktop'),
        _target('kimi-code', 'Kimi Code - CLI'),
      ],
      sessionsByAgent: {
        'kimi': [
          _session('kimi-session', 'kimi', 'Kimi session', updatedHoursAgo: 1),
        ],
        'kimi-code': [
          _session(
            'kimi-code-session',
            'kimi-code',
            'Kimi Code session',
            updatedHoursAgo: 3,
          ),
        ],
      },
      onSelectSession: (_, _) {},
    );

    final targets = tester
        .widgetList<AgentBrandIcon>(find.byType(AgentBrandIcon))
        .map((icon) => icon.target.target)
        .toSet();
    expect(targets, containsAll(['kimi', 'kimi-code']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected conversation row follows the house selection rule', (
    tester,
  ) async {
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'Codex')],
      sessionsByAgent: {
        'codex': [
          _session('picked', 'codex', 'Picked session', updatedHoursAgo: 1),
          _session('other', 'codex', 'Other session', updatedHoursAgo: 5),
        ],
      },
      selectedSessionId: 'picked',
      onSelectSession: (_, _) {},
    );

    final colors = tester
        .element(find.byKey(const Key('agents-workspace-sidebar')))
        .licoColors;
    final container = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byKey(const Key('agents-sidebar-conversation-picked')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect(
      (container.decoration as BoxDecoration?)?.color,
      Colors.white.withAlpha(26),
    );

    final title = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const Key('agents-sidebar-conversation-picked')),
            matching: find.text('Picked session'),
          )
          .first,
    );
    expect(title.style?.color, colors.text);
    expect(tester.takeException(), isNull);
  });

  testWidgets('activity dot follows the owning group signal', (tester) async {
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'Codex')],
      sessionsByAgent: {
        'codex': [
          _session('active', 'codex', 'Active session', updatedHoursAgo: 1),
        ],
      },
      activityFor: (_) => AgentConversationTabActivity.needsApproval,
      onSelectSession: (_, _) {},
    );

    final colors = tester
        .element(find.byKey(const Key('agents-workspace-sidebar')))
        .licoColors;
    final dot = tester.widget<Container>(
      find.byKey(const Key('agents-sidebar-activity-active')),
    );
    expect((dot.decoration as BoxDecoration?)?.color, colors.warning);
    expect(tester.takeException(), isNull);
  });

  testWidgets('running conversation spins and takes priority over completion', (
    tester,
  ) async {
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'Codex')],
      sessionsByAgent: {
        'codex': [
          _session('running', 'codex', 'Running session', updatedHoursAgo: 1),
        ],
      },
      activityFor: (_) => AgentConversationTabActivity.workFinished,
      runningFor: (session) => session.id == 'running',
      onSelectSession: (_, _) {},
    );

    final running = find.byKey(const Key('agents-sidebar-running-running'));
    expect(running, findsOneWidget);
    expect(
      find.byKey(const Key('agents-sidebar-activity-running')),
      findsNothing,
    );
    expect(find.text('优先'), findsOneWidget);
    final rotation = tester.widget<RotationTransition>(
      find.descendant(of: running, matching: find.byType(RotationTransition)),
    );
    final before = rotation.turns.value;
    await tester.pump(const Duration(milliseconds: 120));
    expect(rotation.turns.value, isNot(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'running conversations move above recency groups without duplicates',
    (tester) async {
      await _pumpSidebar(
        tester,
        targets: [_target('codex', 'Codex')],
        sessionsByAgent: {
          'codex': [
            _session('idle', 'codex', 'Newest idle', updatedHoursAgo: 1),
            _session(
              'running',
              'codex',
              'Older running',
              updatedHoursAgo: 20,
              running: true,
            ),
          ],
        },
        runningFor: (session) => session.running,
        onSelectSession: (_, _) {},
      );

      expect(find.text('优先'), findsOneWidget);
      expect(find.text('Older running'), findsOneWidget);
      expect(find.text('Newest idle'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Older running')).dy,
        lessThan(tester.getTopLeft(find.text('Newest idle')).dy),
      );
      expect(
        find.byKey(const Key('agents-sidebar-conversation-running')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the group assistant thread pins above recency groups by default',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final entries = flattenSidebarConversations(
        targets: [_target('codex', 'Codex'), _target('worker-a', 'Worker A')],
        sessionsByAgent: {
          'codex': [_session('assistant-thread', 'codex', 'Assistant thread')],
          'worker-a': [
            _session(
              'member-work',
              'worker-a',
              'Member work',
              updatedHoursAgo: 1,
            ),
          ],
        },
        activityFor: (_) => AgentConversationTabActivity.none,
      );
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
              height: 640,
              child: SidebarConversationListView(
                entries: entries,
                selectedSessionId: '',
                earlierExpanded: false,
                onToggleEarlier: () {},
                onSelectSession: (_, _) {},
                priorityAgentId: 'codex',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The assistant thread (older) pins into 优先 above the newer member row
      // and is not duplicated in the recency groups below.
      expect(find.text('优先'), findsOneWidget);
      expect(find.text('Assistant thread'), findsOneWidget);
      expect(find.text('Member work'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Assistant thread')).dy,
        lessThan(tester.getTopLeft(find.text('Member work')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completed conversation activity dot breathes', (tester) async {
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'Codex')],
      sessionsByAgent: {
        'codex': [
          _session('finished', 'codex', 'Finished session', updatedHoursAgo: 1),
        ],
      },
      activityFor: (_) => AgentConversationTabActivity.workFinished,
      onSelectSession: (_, _) {},
    );

    final dot = find.byKey(const Key('agents-sidebar-activity-finished'));
    expect(dot, findsOneWidget);
    final fade = tester.widget<FadeTransition>(
      find.ancestor(of: dot, matching: find.byType(FadeTransition)).first,
    );
    final before = fade.opacity.value;
    await tester.pump(const Duration(milliseconds: 320));
    expect(fade.opacity.value, isNot(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar title bar precedes the New Chat action', (tester) async {
    var newConversationCount = 0;
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'Codex')],
      sessionsByAgent: const {},
      onSelectSession: (_, _) {},
      onNewConversation: () => newConversationCount += 1,
    );

    final action = find.byKey(const Key('agents-sidebar-new-conversation'));
    final heading = find.byKey(
      const Key('agents-sidebar-conversations-heading'),
    );
    expect(action, findsOneWidget);
    expect(find.text('新对话'), findsOneWidget);
    expect(
      tester.getTopLeft(heading).dy,
      lessThan(tester.getTopLeft(action).dy),
    );

    await tester.tap(action);
    await tester.pump();
    expect(newConversationCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the more-actions button is the shared header circle', (
    tester,
  ) async {
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'Codex')],
      sessionsByAgent: const {},
      onSelectSession: (_, _) {},
      onAddTarget: () {},
    );

    final button = find.byKey(const Key('agents-sidebar-add-target'));
    expect(button, findsOneWidget);
    final circle = tester.widget<AnimatedContainer>(
      find
          .descendant(of: button, matching: find.byType(AnimatedContainer))
          .first,
    );
    final decoration = circle.decoration! as BoxDecoration;
    // The unified icon-button primitive expresses shape through borderRadius
    // so the same recipe can also nest concentrically inside a rounded field.
    expect(decoration.borderRadius, isNotNull);
    expect(decoration.border!.top.width, 1);
    expect(
      tester.getSize(button),
      Size(LicoIconButtonSize.large.extent, LicoIconButtonSize.large.extent),
    );
  });

  testWidgets('Earlier group starts collapsed and expands on tap', (
    tester,
  ) async {
    await _pumpSidebar(
      tester,
      targets: [_target('codex', 'Codex')],
      sessionsByAgent: {
        'codex': [
          _session('recent', 'codex', 'Recent session', updatedHoursAgo: 2),
          _session('old-1', 'codex', 'Old session one', updatedDaysAgo: 30),
          _session('old-2', 'codex', 'Old session two', updatedDaysAgo: 60),
        ],
      },
      onSelectSession: (_, _) {},
    );

    // Collapsed by default: the header shows a right chevron and the count;
    // the old rows stay hidden.
    final toggle = find.byKey(const Key('agents-sidebar-earlier-toggle'));
    expect(toggle, findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Recent session'), findsOneWidget);
    expect(find.text('Old session one'), findsNothing);
    expect(find.text('Old session two'), findsNothing);
    // The retired >7-day archive group stays gone.
    expect(find.text('已归档 · 2'), findsNothing);

    await tester.tap(toggle);
    await tester.pump();

    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    expect(find.text('Old session one'), findsOneWidget);
    expect(find.text('Old session two'), findsOneWidget);

    // Tapping again collapses it back.
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('Old session one'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first build prefetches every unloaded conversation agent', (
    tester,
  ) async {
    final prefetched = <String>[];
    await _pumpSidebar(
      tester,
      targets: [
        _target('codex', 'Codex'),
        _target('cursor', 'Cursor'),
        _target('code', 'VS Code'),
      ],
      sessionsByAgent: {
        'codex': [
          _session('loaded', 'codex', 'Loaded session', updatedHoursAgo: 1),
        ],
      },
      onPrefetchSessions: prefetched.add,
      onSelectSession: (_, _) {},
    );

    // The unloaded conversation agent is prefetched; the agent with loaded
    // sessions and the non-conversation 'code' target are skipped, and the
    // kick fires exactly once per agent.
    expect(prefetched, ['cursor']);

    // When the landed sessions arrive, the non-selected agent's recent
    // conversation joins the flat list.
    await _pumpSidebar(
      tester,
      targets: [
        _target('codex', 'Codex'),
        _target('cursor', 'Cursor'),
        _target('code', 'VS Code'),
      ],
      sessionsByAgent: {
        'codex': [
          _session('loaded', 'codex', 'Loaded session', updatedHoursAgo: 1),
        ],
        'cursor': [
          // Same weekday-robust timestamp rule as above: stay inside
          // today/yesterday so the row never hides in the collapsed Earlier
          // group.
          _session(
            'cursor-recent',
            'cursor',
            'Cursor recent session',
            updatedHoursAgo: 3,
          ),
        ],
      },
      onPrefetchSessions: prefetched.add,
      onSelectSession: (_, _) {},
    );
    expect(find.text('Cursor recent session'), findsOneWidget);
    expect(prefetched, ['cursor']);
    expect(tester.takeException(), isNull);
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
  int updatedDaysAgo = 2,
  int? updatedHoursAgo,
  String? updatedAt,
  String workingDirectory = '',
  bool running = false,
}) {
  final effectiveUpdatedAt =
      updatedAt ??
      (updatedHoursAgo != null
              ? DateTime.now().subtract(Duration(hours: updatedHoursAgo))
              : DateTime.now().subtract(Duration(days: updatedDaysAgo)))
          .toUtc()
          .toIso8601String();
  return AgentConversationSession(
    id: id,
    agentId: agentId,
    title: title,
    createdAt: effectiveUpdatedAt,
    updatedAt: effectiveUpdatedAt,
    messages: const [],
    workingDirectory: workingDirectory,
    running: running,
  );
}

Future<void> _pumpSidebar(
  WidgetTester tester, {
  required List<TargetCandidate> targets,
  required Map<String, List<AgentConversationSession>> sessionsByAgent,
  required void Function(String agentId, String sessionId) onSelectSession,
  AgentConversationTabActivity Function(String agentId)? activityFor,
  bool Function(AgentConversationSession session)? runningFor,
  ValueChanged<String>? onPrefetchSessions,
  VoidCallback? onNewConversation,
  VoidCallback? onAddTarget,
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
          height: 640,
          child: AgentsWorkspaceSidebar(
            targets: targets,
            sessionsByAgent: sessionsByAgent,
            selectedSessionId: selectedSessionId,
            activityFor:
                activityFor ?? (_) => AgentConversationTabActivity.none,
            runningFor: runningFor,
            onSelectSession: onSelectSession,
            onPrefetchSessions: onPrefetchSessions,
            onNewConversation: onNewConversation ?? () {},
            onAddTarget: onAddTarget,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
