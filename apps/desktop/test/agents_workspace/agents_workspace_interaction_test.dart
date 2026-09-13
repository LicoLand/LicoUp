import 'support/agents_workspace_test_harness.dart';

void registerAgentsWorkspaceInteractionScenarios() {
  testWidgets('runtime composer selects discovered model settings', (
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
        confidence: 0.9,
        binaryPath: '/test-bin/codex',
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationProtocol': 'codex-app-server-stdio-jsonrpc',
          'conversationReadiness': 'ready',
        },
        supportedActions: const ['runtime.message.send'],
        modelCatalog: const {
          'status': 'available',
          'models': [
            {
              'name': 'model-canary',
              'reasoningEfforts': ['high'],
            },
          ],
        },
      ),
    ];
    controller.selectedConversationAgentId = 'codex';

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 760,
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
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const ValueKey('conversation-model-select')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('model-canary').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(
      find.byKey(const ValueKey('conversation-reasoning-select')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Reasoning · high').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(controller.selectedConversationModel, 'model-canary');
    expect(controller.selectedConversationReasoningEffort, 'high');
    expect(tester.takeException(), isNull);
  });

  testWidgets('agents workspace sidebar exposes conversation actions', (
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
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 900,
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
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('CONVERSATIONS'), findsOneWidget);
    expect(
      find.byKey(const Key('agents-sidebar-new-conversation')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agents-sidebar-archive')), findsNothing);
    expect(
      find.byKey(const Key('agents-sidebar-backup-conversations')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agents-sidebar-add-target')), findsOneWidget);
    expect(find.byKey(const Key('agents-sidebar-nav-skills')), findsNothing);
    expect(find.byKey(const Key('agents-sidebar-nav-stats')), findsNothing);
  });

  testWidgets(
    'available agent keeps the composer enabled without a send error',
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
          confidence: 1,
          binaryPath: '/synthetic/bin/codex',
          adapterStatus: 'implemented',
          adapterCapabilities: const {'conversationDriver': 'implemented'},
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
              width: 900,
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
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('发送失败：当前策略没有可用的发送目标。'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(find.text('Codex'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}

void main() => registerAgentsWorkspaceInteractionScenarios();
