import 'package:licoup/src/contracts/target_management.dart';

import 'support/agents_workspace_test_harness.dart';

void registerAgentsWorkspaceRendererCacheScenarios() {
  testWidgets('message list reuses adapter resolution across rebuilds', (
    tester,
  ) async {
    final previousRegistry = AgentRenderAdapterRegistry.instance;
    final registry = CountingAgentRenderAdapterRegistry();
    AgentRenderAdapterRegistry.instance = registry;
    addTearDown(() {
      AgentRenderAdapterRegistry.instance = previousRegistry;
    });

    final agentService = _RendererCacheAgentService();
    addTearDown(agentService.dispose);
    final controller = ClientController(agentService: agentService);
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
    controller.selectedConversationSessionId = 'session-adapter-cache';
    controller.conversationSessionsByAgent = const {
      'codex': [
        AgentConversationSession(
          id: 'session-adapter-cache',
          agentId: 'codex',
          title: 'Adapter cache',
          createdAt: '2026-07-12T00:00:00Z',
          updatedAt: '2026-07-12T00:00:01Z',
          sourceClient: 'codex',
          messages: [
            AgentConversationMessage(
              id: 'message-adapter-cache',
              role: 'assistant',
              text: 'Stable content.',
              createdAt: '2026-07-12T00:00:01Z',
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
            width: 820,
            height: 700,
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

    expect(registry.resolveCalls, 1);
    expect(find.text('Stable content.'), findsWidgets);

    controller.conversationSessionsByAgent = const {
      'codex': [
        AgentConversationSession(
          id: 'session-adapter-cache',
          agentId: 'codex',
          title: 'Adapter cache',
          createdAt: '2026-07-12T00:00:00Z',
          updatedAt: '2026-07-12T00:00:02Z',
          sourceClient: 'codex-updated',
          messages: [
            AgentConversationMessage(
              id: 'message-adapter-cache',
              role: 'assistant',
              text: 'Stable content.',
              createdAt: '2026-07-12T00:00:01Z',
            ),
          ],
        ),
      ],
    };
    controller.selectConversationSession('session-adapter-cache');
    await tester.pump();

    expect(registry.resolveCalls, 2);
  });
}

final class _RendererCacheAgentService extends AgentService {
  @override
  Future<TargetScanBatch> scanTargetsBatch(
    List<String> targetIds, {
    bool enableAgentCliModelLookup = false,
  }) async => TargetScanBatch([
    for (final targetId in targetIds)
      TargetScanSlot(targetId: targetId, failed: true),
  ]);
}

void main() => registerAgentsWorkspaceRendererCacheScenarios();
