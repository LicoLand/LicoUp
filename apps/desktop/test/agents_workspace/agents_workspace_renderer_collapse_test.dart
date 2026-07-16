import 'support/agents_workspace_test_harness.dart';

void registerAgentsWorkspaceRendererCollapseScenarios() {
  testWidgets('agent messages collapse additional metadata blocks', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'antigravity',
        label: 'Antigravity',
        kind: 'native-history',
        status: 'detected',
        configured: false,
        confidence: 0.9,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'antigravity';
    controller.selectedConversationSessionId = 'session-metadata';
    controller.conversationSessionsByAgent = {
      'antigravity': const [
        AgentConversationSession(
          id: 'session-metadata',
          agentId: 'antigravity',
          title: 'Metadata rendering',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'antigravity',
          nativeSessionId: 'antigravity-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-agent',
              role: 'assistant',
              text:
                  'Visible answer.\n\n<ADDITIONAL_METADATA>\nThe current local time is hidden.\nActive Document: hidden.md\n</ADDITIONAL_METADATA>\n\nNext visible line.',
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

    expect(
      find.textContaining('Visible answer', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('Next visible line', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('ADDITIONAL_METADATA', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('Active Document', findRichText: true),
      findsNothing,
    );
    expect(find.text('Details'), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Active Document', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('ADDITIONAL_METADATA', findRichText: true),
      findsNothing,
    );
  });

  testWidgets('agent messages collapse recommended plugins by default', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'antigravity',
        label: 'Antigravity',
        kind: 'native-history',
        status: 'detected',
        configured: false,
        confidence: 0.9,
        adapterStatus: 'implemented',
      ),
    ];
    controller.selectedConversationAgentId = 'antigravity';
    controller.selectedConversationSessionId = 'session-plugins';
    controller.conversationSessionsByAgent = {
      'antigravity': const [
        AgentConversationSession(
          id: 'session-plugins',
          agentId: 'antigravity',
          title: 'Recommended plugins',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'antigravity',
          nativeSessionId: 'antigravity-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-agent',
              role: 'assistant',
              text:
                  'Visible answer.\n\n<recommended_plugins>\nHere is a list of plugins that are available but not installed.\n\n- Atlassian Rovo (atlassian-rovo@openai-curated-remote)\n- Google Drive (google-drive@openai-curated-remote)\n</recommended_plugins>',
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

    expect(
      find.textContaining('Visible answer', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('recommended_plugins', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('Atlassian Rovo', findRichText: true),
      findsNothing,
    );
    expect(find.text('Recommended Plugins · 2'), findsOneWidget);

    await tester.tap(find.text('Recommended Plugins · 2'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Atlassian Rovo', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Google Drive', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('recommended_plugins', findRichText: true),
      findsNothing,
    );
  });

  testWidgets('agent message list renders subagent output as collapsed card', (
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
    controller.selectedConversationSessionId = 'session-1';
    controller.conversationSessionsByAgent = {
      'codex': const [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'codex',
          title: 'Run security scan',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:03Z',
          adapterId: 'codex',
          nativeSessionId: 'codex-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-user',
              role: 'user',
              text: 'Run security scan',
              createdAt: '2026-06-15T00:00:00Z',
            ),
            AgentConversationMessage(
              id: 'message-worker',
              role: 'subagent',
              cardType: 'subagent',
              cardTitle: 'discovery worker round-05/worker-03',
              text: 'Worker preview line',
              createdAt: '2026-06-15T00:00:01Z',
              childMessages: [
                AgentConversationMessage(
                  id: 'message-worker-output',
                  role: 'agent',
                  text: 'Detailed worker result',
                  createdAt: '2026-06-15T00:00:02Z',
                ),
              ],
            ),
            AgentConversationMessage(
              id: 'message-agent',
              role: 'agent',
              text: 'Coordinator response',
              createdAt: '2026-06-15T00:00:03Z',
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

    expect(find.text('discovery worker round-05/worker-03'), findsOneWidget);
    expect(find.text('Subagent task · 1 messages'), findsOneWidget);
    expect(find.text('Worker preview line'), findsOneWidget);
    expect(find.text('Detailed worker result'), findsNothing);

    await tester.tap(find.text('discovery worker round-05/worker-03'));
    await tester.pumpAndSettle();

    expect(find.text('Detailed worker result'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void main() => registerAgentsWorkspaceRendererCollapseScenarios();
