import 'support/agents_workspace_test_harness.dart';

void registerAgentsWorkspaceStateScenarios() {
  testWidgets('agent message list defaults to latest messages', (tester) async {
    final controller = ClientController();
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
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'codex': [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'codex',
          title: 'Long imported Codex conversation',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'codex',
          nativeSessionId: 'codex-session',
          sourceKind: 'native-agent-history',
          messages: [
            for (var index = 0; index < 18; index++)
              AgentConversationMessage(
                id: 'message-$index',
                role: index.isEven ? 'user' : 'assistant',
                text: index == 0
                    ? 'Oldest imported prompt'
                    : index == 17
                    ? 'Newest imported answer'
                    : 'Imported message $index',
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
            width: 720,
            height: 420,
            child: AgentConversationWorkspaceFixture(
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

    expect(find.text('Newest imported answer'), findsWidgets);
    expect(find.text('Oldest imported prompt'), findsNothing);
  });

  testWidgets(
    'agent message list renders the active native turn before history readback',
    (tester) async {
      final controller = ClientController();
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
        ),
      ];
      controller.selectedConversationAgentId = 'codex';
      controller.isSendingConversationMessage = true;
      controller.liveConversationMessagesByScope = {
        'new:codex': const [
          AgentConversationMessage(
            id: 'live-user',
            role: 'user',
            text: 'Explain the current build.',
            createdAt: '2026-06-15T00:00:00Z',
          ),
          AgentConversationMessage(
            id: 'live-assistant',
            role: 'assistant',
            text: 'The build is still running',
            createdAt: '2026-06-15T00:00:01Z',
          ),
          AgentConversationMessage(
            id: 'live-process',
            role: 'tool_call',
            text: 'Inspecting build status',
            createdAt: '2026-06-15T00:00:01Z',
            layer: AgentConversationSemanticLayer.execution,
            cardType: 'tool-call',
            cardTitle: 'tool.call.started',
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
              width: 720,
              height: 420,
              child: AgentConversationWorkspaceFixture(
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
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Explain the current build.'), findsOneWidget);
      expect(find.text('The build is still running'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('conversation-process-semantics-live-process'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('agent workspace uses Chinese labels for Chinese locale', (
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
        locale: const Locale('zh'),
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
            width: 720,
            height: 520,
            child: AgentConversationWorkspaceFixture(
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

    expect(find.text('历史对话'), findsNothing);
    expect(find.text('搜索历史对话'), findsNothing);
    expect(find.text('0 条对话'), findsOneWidget);
    expect(find.text('备份对话'), findsOneWidget);
    expect(find.text('新对话'), findsOneWidget);
    expect(find.byTooltip('收起历史对话'), findsOneWidget);
    expect(find.text('查看'), findsNothing);
    expect(find.text('计划'), findsNothing);
    expect(find.text('Conversation history'), findsNothing);
  });
}

void main() => registerAgentsWorkspaceStateScenarios();
