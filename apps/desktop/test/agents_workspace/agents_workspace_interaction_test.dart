import 'support/agents_workspace_test_harness.dart';

void registerAgentsWorkspaceInteractionScenarios() {
  testWidgets(
    'long process stays operable, bounded, and localized after expansion',
    (tester) async {
      final controller = ClientController();
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'native-history',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'implemented',
        ),
      ];
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'long-process';
      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession(
            id: 'long-process',
            agentId: 'codex',
            title: 'Long process',
            createdAt: '2026-06-15T00:00:00Z',
            updatedAt: '2026-06-15T00:02:09Z',
            messages: [
              for (var index = 0; index < 130; index++)
                AgentConversationMessage(
                  id: 'long-event-$index',
                  role: 'event',
                  cardType: 'event',
                  text: 'Safe operation ${index + 1}',
                  createdAt: DateTime.utc(
                    2026,
                    6,
                    15,
                  ).add(Duration(seconds: index)).toIso8601String(),
                ),
            ],
          ),
        ],
      };

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
              height: 360,
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

      const toggleKey = Key('conversation-process-toggle-long-event-0');
      await tester.ensureVisible(find.byKey(toggleKey, skipOffstage: false));
      await tester.pump();
      expect(find.text('处理了 2分钟 9秒'), findsOneWidget);
      expect(find.text('130 个步骤'), findsOneWidget);
      expect(find.text('Safe operation 1', findRichText: true), findsNothing);

      await tester.tap(find.byKey(toggleKey));
      await tester.pumpAndSettle();

      expect(find.text('为保持对话流畅，其余操作已隐藏。'), findsOneWidget);
      expect(find.text('Safe operation 1', findRichText: true), findsOneWidget);
      expect(find.text('Safe operation 129', findRichText: true), findsNothing);
      final listFinder = find
          .ancestor(
            of: find.byKey(toggleKey),
            matching: find.byType(Scrollable),
          )
          .first;
      final toggleRect = tester.getRect(find.byKey(toggleKey));
      final listRect = tester.getRect(listFinder);
      expect(toggleRect.intersect(listRect).height, greaterThanOrEqualTo(24));

      await tester.tap(find.byKey(toggleKey));
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('Safe operation 1', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'truncation and hidden operation details stay explicit and localized',
    (tester) async {
      final controller = ClientController();
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'native-history',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'implemented',
        ),
      ];
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'truncated-process';
      controller.conversationSessionsByAgent = {
        'codex': [
          const AgentConversationSession(
            id: 'truncated-process',
            agentId: 'codex',
            title: 'Truncated process',
            createdAt: '2026-06-15T00:00:00Z',
            updatedAt: '2026-06-15T00:00:02Z',
            historyTruncated: true,
            messageTreeTruncated: true,
            messages: [
              AgentConversationMessage(
                id: 'user-before-process',
                role: 'user',
                text: '检查过程',
                createdAt: '2026-06-15T00:00:00Z',
              ),
              AgentConversationMessage(
                id: 'tool-hidden',
                role: 'tool_call',
                cardType: 'tool-call',
                cardTitle: 'exec',
                text: '',
                createdAt: '2026-06-15T00:00:01Z',
                childMessagesTruncated: true,
              ),
              AgentConversationMessage(
                id: 'final-after-process',
                role: 'assistant',
                text: '最终消息仍保留。',
                createdAt: '2026-06-15T00:00:02Z',
              ),
            ],
          ),
        ],
      };

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
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: SizedBox(
                width: 720,
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
        ),
      );
      await tester.pumpAndSettle();

      const toggleKey = Key('conversation-process-toggle-tool-hidden');
      final finalMessage = find.text('最终消息仍保留。');
      final truncationNotice = find.text('较早消息和部分嵌套过程详情未载入；当前显示最近的完整对话骨架。');
      final messageList = find
          .ancestor(
            of: find.byKey(toggleKey),
            matching: find.byType(Scrollable),
          )
          .first;
      expect(finalMessage, findsWidgets);
      await tester.scrollUntilVisible(
        truncationNotice,
        120,
        scrollable: messageList,
      );
      expect(truncationNotice, findsOneWidget);
      expect(find.text('调用详情已隐藏。', findRichText: true), findsNothing);

      await tester.tap(find.byKey(toggleKey));
      await tester.pump();

      expect(find.text('调用详情已隐藏。', findRichText: true), findsOneWidget);
      expect(find.text('Invocation details are hidden.'), findsNothing);
      expect(find.text('为保持对话流畅，其余操作已隐藏。'), findsOneWidget);
      expect(
        find.byKey(const Key('conversation-process-tool-hidden')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        finalMessage,
        -120,
        scrollable: messageList,
      );
      expect(finalMessage, findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

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

    await tester.tap(find.byKey(const ValueKey('conversation-model-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Model · model-canary').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('conversation-reasoning-select')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reasoning · high').last);
    await tester.pumpAndSettle();

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

    expect(find.text('CONVERSATIONS'), findsOneWidget);
    expect(
      find.byKey(const Key('agents-sidebar-new-conversation')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agents-sidebar-archive')), findsOneWidget);
    expect(find.byKey(const Key('agents-sidebar-add-target')), findsOneWidget);
    expect(find.byKey(const Key('agents-sidebar-nav-skills')), findsNothing);
    expect(find.byKey(const Key('agents-sidebar-nav-stats')), findsNothing);
  });
}

void main() => registerAgentsWorkspaceInteractionScenarios();
