import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';

import 'support/agents_workspace_test_harness.dart';

void registerAgentsWorkspaceLayoutScenarios() {
  testWidgets('agent workspace does not overflow in a narrow app window', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    final sessionUpdatedAt = DateTime.now()
        .subtract(const Duration(days: 1))
        .toUtc()
        .toIso8601String();
    controller.scannedTargets = [
      TargetCandidate(
        target: 'copilot',
        label: 'Copilot',
        kind: 'native-history-with-long-kind-label',
        status: 'detected',
        configured: false,
        confidence: 0.84,
        adapterStatus: 'implemented',
      ),
      TargetCandidate(
        target: 'code',
        label: 'VS Code',
        kind: 'desktop-agent',
        status: 'detected',
        configured: false,
        confidence: 0.88,
        adapterStatus: 'unsupported',
      ),
      TargetCandidate(
        target: 'kilo-code',
        label: 'Kilo Code',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
      TargetCandidate(
        target: 'openclaw',
        label: 'OpenClaw',
        kind: 'cli',
        status: 'not-detected',
        configured: false,
        confidence: 0.15,
        adapterStatus: 'unsupported',
      ),
    ];
    controller.selectedConversationAgentId = 'copilot';
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'copilot': [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'copilot',
          title: 'key: workspace-history-with-a-long-title',
          createdAt: sessionUpdatedAt,
          updatedAt: sessionUpdatedAt,
          adapterId: 'copilot-native-import',
          nativeSessionId: 'native-session-with-long-identifier',
          sourceKind: 'native-agent-history',
          sourcePath: '<user-home>/.config/copilot/history/session.jsonl',
          messages: [
            AgentConversationMessage(
              id: 'message-1',
              role: 'assistant',
              text:
                  'A long native agent history preview should wrap inside the available message column instead of pushing adjacent controls outside the window.',
              createdAt: '2026-06-15T00:00:00Z',
            ),
          ],
        ),
        AgentConversationSession(
          id: 'session-2',
          agentId: 'copilot',
          title: 'second runtime conversation',
          createdAt: sessionUpdatedAt,
          updatedAt: sessionUpdatedAt,
          adapterId: 'copilot-native-import',
          nativeSessionId: 'native-session-2',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-2',
              role: 'user',
              text: 'Follow up from another imported native history.',
              createdAt: '2026-06-16T00:00:00Z',
            ),
          ],
        ),
      ],
    };
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 540,
            height: 560,
            child: AgentConversationWorkspace(
              controller: controller,
              targets: controller.scannedTargets,
              scanning: false,
              adding: false,
              onAddTarget: () {},
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('agents-workspace-shell')), findsOneWidget);
    expect(find.byKey(const Key('agents-workspace-sidebar')), findsOneWidget);
    expect(
      find.byKey(const Key('agents-workspace-detail-pane')),
      findsOneWidget,
    );
    expect(find.byType(AgentsWorkspaceSidebar), findsOneWidget);
    expect(
      find.byKey(const Key('conversation-parity-readiness')),
      findsOneWidget,
    );
    expect(find.text('Unverified'), findsOneWidget);
    expect(find.text('UNVERIFIED'), findsNothing);
    expect(find.text('unverified'), findsNothing);
    expect(find.text('VS Code'), findsNothing);
    expect(find.text('OpenClaw'), findsNothing);
    expect(find.text('Not detected'), findsNothing);
    expect(find.text('Conversation history'), findsNothing);
    expect(find.text('Search conversations'), findsNothing);
    expect(find.text('Back up conversations'), findsOneWidget);
    expect(find.text('New Chat'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('New Chat')).dy,
      lessThan(tester.getTopLeft(find.text('Back up conversations')).dy),
    );
    expect(find.byTooltip('Collapse conversation history'), findsOneWidget);
    expect(find.text('key: workspace-history-with-a-long-title'), findsWidgets);
    expect(find.text('second runtime conversation'), findsOneWidget);
    expect(find.textContaining('Updated'), findsNothing);
    expect(
      find.textContaining(
        'A long native agent history preview should wrap inside the available message column',
      ),
      findsWidgets,
    );
    expect(find.textContaining('2 messages'), findsNothing);
    expect(find.textContaining('native-agent-history'), findsNothing);
    expect(
      find.textContaining('native-session-with-long-identifier'),
      findsNothing,
    );
    expect(find.text('Local agents'), findsNothing);
    expect(find.text('Inspect'), findsNothing);
    expect(find.text('Plan'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);

    await tester.tap(find.byKey(const Key('agents-sidebar-new-conversation')));
    await tester.pump();

    expect(controller.selectedConversationSessionId, isEmpty);
    expect(controller.selectedConversationSession, isNull);

    await tester.tap(find.byTooltip('Collapse conversation history'));
    await tester.pumpAndSettle();

    expect(find.text('Back up conversations'), findsNothing);
    expect(find.text('New Chat'), findsNothing);
    expect(find.byTooltip('Expand conversation history'), findsOneWidget);
  });

  testWidgets('agent workspace survives a window narrower than the sidebar minimum', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'codex';
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'codex': const [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'codex',
          title: 'Narrow window conversation',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          nativeSessionId: 'codex-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-1',
              role: 'assistant',
              text: 'Body',
              createdAt: '2026-06-15T00:00:00Z',
            ),
          ],
        ),
      ],
    };

    // 500 px leaves less room than the 196 px sidebar minimum after the chat
    // minimum and chrome extents; the sidebar must floor at its minimum
    // instead of feeding an inverted clamp range.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 560,
            child: AgentConversationWorkspace(
              controller: controller,
              targets: controller.scannedTargets,
              scanning: false,
              adding: false,
              onAddTarget: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('agents-workspace-shell')), findsOneWidget);
    final sidebar = find.byKey(const Key('agents-workspace-sidebar'));
    expect(sidebar, findsOneWidget);
    expect(tester.getSize(sidebar).width, agentsSidebarMinWidth);
  });

  testWidgets('wide agent workspace uses sidebar and floating card', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'claude-code',
        label: 'Claude Code',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'claude-code';
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'claude-code': const [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'claude-code',
          title: 'Resizable split conversation',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'claude-code',
          nativeSessionId: 'claude-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-1',
              role: 'assistant',
              text: 'Split pane body',
              createdAt: '2026-06-15T00:00:00Z',
            ),
          ],
        ),
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 520,
            child: AgentConversationWorkspace(
              controller: controller,
              targets: controller.scannedTargets,
              scanning: false,
              adding: false,
              onAddTarget: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agents-workspace-shell')), findsOneWidget);
    expect(find.byKey(const Key('agents-workspace-sidebar')), findsOneWidget);
    expect(
      find.byKey(const Key('agents-workspace-detail-pane')),
      findsOneWidget,
    );
    expect(find.byType(AgentsWorkspaceSidebar), findsOneWidget);
    expect(find.text('CONVERSATIONS'), findsOneWidget);
    expect(find.byKey(const Key('agents-sidebar-nav-skills')), findsNothing);
    expect(find.byKey(const Key('agents-sidebar-nav-stats')), findsNothing);
    expect(find.text('Resizable split conversation'), findsWidgets);
    expect(find.text('Claude Code · 1 messages'), findsNothing);
    expect(find.byKey(const Key('conversation-split-page')), findsNothing);
    expect(find.byKey(const Key('conversation-split-divider')), findsNothing);

    final sidebarFinder = find.byKey(const Key('agents-workspace-sidebar'));
    final dividerFinder = find.byKey(
      const Key('agents-workspace-split-divider'),
    );
    expect(dividerFinder, findsOneWidget);
    final initialWidth = tester.getSize(sidebarFinder).width;
    expect(initialWidth, 196);

    // Drag from inside the left-edge drag handle rather than its center,
    // because the handle is only a few pixels wide and sits at the pane edge.
    final dividerRect = tester.getRect(dividerFinder);
    await tester.dragFrom(
      Offset(dividerRect.left + 2, dividerRect.center.dy),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebarFinder).width, greaterThan(initialWidth));
  });

  testWidgets('mobile agent empty state hides manual add target actions', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        locale: const Locale('zh'),
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
          body: SizedBox(
            width: 390,
            height: 760,
            child: AgentConversationWorkspace(
              controller: controller,
              targets: const [],
              scanning: false,
              adding: false,
              onAddTarget: () {},
              allowManualTargetActions: false,
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('选择一个智能体查看历史并对话'), findsOneWidget);
    expect(find.text('添加目标'), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('mobile runtime suppresses agent tabs under desktop theme', (
    tester,
  ) async {
    final controller = ClientController(
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'codex';

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
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
            width: 390,
            height: 760,
            child: AgentConversationWorkspace(
              controller: controller,
              targets: controller.scannedTargets,
              scanning: false,
              adding: false,
              onAddTarget: () {},
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('添加目标'), findsNothing);
  });
}

void main() => registerAgentsWorkspaceLayoutScenarios();
