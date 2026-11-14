import 'support/agents_workspace_test_harness.dart';
import 'package:licoup/src/frontend/layout/layout_agents_directive.dart';

import '../support/bundled_font_loader.dart';

void main() {
  setUpAll(loadBundledVisualFonts);
  testWidgets('switcher panel covers the detail with a readability veil', (
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
      'codex': [
        AgentConversationSession(
          id: 'session-1',
          agentId: 'codex',
          title: 'Imported Codex conversation',
          createdAt: '2026-06-15T00:00:00Z',
          updatedAt: '2026-06-15T00:00:00Z',
          adapterId: 'codex',
          nativeSessionId: 'codex-session',
          sourceKind: 'native-agent-history',
          messages: [
            AgentConversationMessage(
              id: 'message-1',
              role: 'assistant',
              text: 'Session content the switcher must cover.',
              createdAt: '2026-06-15T00:00:00Z',
            ),
          ],
        ),
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: FixtureLayoutPresentationScope(child: child!),
        ),
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 520,
            child: LayoutAgentsDirectiveScope(
              directive: LayoutAgentsDirective(
                sidebarMode: LayoutAgentsSidebarMode.avatarColumn,
                switcherOpen: true,
                onToggleSwitcher: () {},
              ),
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
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('agents-workspace-switcher-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-conversation-overlay-readability-veil')),
      findsOneWidget,
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/agents_workspace_switcher_veil.png'),
    );
  });
}
