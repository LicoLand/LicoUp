import 'fixtures/client_controller/support/client_controller_scenario_dependencies.dart';
import 'fixtures/client_controller/support/client_controller_scenario_json.dart';
import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late PortableDataRoot portableData;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lico-last-used-');
    portableData = PortableDataRoot(dataDirectoryOverride: directory);
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  TargetCandidate codexTarget() => TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: false,
    confidence: 0.82,
    adapterStatus: 'implemented',
  );

  TargetCandidate claudeCodeTarget() => TargetCandidate(
    target: 'claude-code',
    label: 'Claude Code',
    kind: 'cli',
    status: 'detected',
    configured: false,
    confidence: 0.9,
    adapterStatus: 'implemented',
  );

  ClientController newController({FakeAgentService? agentService}) =>
      ClientController(
        portableData: portableData,
        agentService: agentService ?? FakeAgentService(),
      );

  Future<void> waitForLastUsedFile() async {
    final dataDir = await portableData.clientDirectory();
    final file = File('${dataDir.path}/last-used-conversation.json');
    for (var attempt = 0; attempt < 100; attempt++) {
      if (await file.exists()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('last-used-conversation.json was never written');
  }

  test('reopens the last-used conversation after relaunch', () async {
    final first = newController();
    addTearDown(first.dispose);
    await first.initialize();
    first.scannedTargets = [codexTarget()];
    first.selectedConversationAgentId = 'codex';

    // A completed live turn binds a session and records it as last-used.
    final saved = await first.conversationCommitTurnBoundNativeReadback(
      agentId: 'codex',
      nativeSessionId: 'native-synthetic-session',
      mergeWithSelectedSession: false,
      messages: const [
        AgentConversationMessage(
          id: 'synthetic-user',
          role: 'user',
          text: 'Continue the last conversation',
          createdAt: '2026-08-07T00:00:00.000Z',
        ),
        AgentConversationMessage(
          id: 'synthetic-assistant',
          role: 'assistant',
          text: 'Synthetic persisted response',
          createdAt: '2026-08-07T00:00:01.000Z',
        ),
      ],
    );
    expect(saved, isTrue);
    final sessionId = first.selectedConversationSessionId;
    expect(sessionId, isNotEmpty);
    await waitForLastUsedFile();

    // Relaunch: the second client restores the same agent and session.
    final secondService = FakeAgentService()
      ..scanTargetsResult = [codexTarget()]
      ..conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-synthetic-session',
          agentId: 'codex',
          text: 'Continue the last conversation',
        ),
      ];
    final second = newController(agentService: secondService);
    addTearDown(second.dispose);
    await second.initialize();
    second.scannedTargets = [codexTarget()];
    second.selectDefaultConversationAgent();

    expect(second.selectedConversationAgentId, 'codex');
    expect(second.selectedConversationSessionId, sessionId);
    expect(second.selectedConversationSession?.id, sessionId);
  });

  test('shows Welcome when the restored agent is gone', () async {
    final first = newController();
    addTearDown(first.dispose);
    await first.initialize();
    first.scannedTargets = [codexTarget()];
    first.selectedConversationAgentId = 'codex';
    await first.conversationCommitTurnBoundNativeReadback(
      agentId: 'codex',
      nativeSessionId: 'native-gone-agent-session',
      mergeWithSelectedSession: false,
      messages: const [
        AgentConversationMessage(
          id: 'synthetic-user',
          role: 'user',
          text: 'Agent disappears later',
          createdAt: '2026-08-07T00:00:00.000Z',
        ),
        AgentConversationMessage(
          id: 'synthetic-assistant',
          role: 'assistant',
          text: 'Synthetic response',
          createdAt: '2026-08-07T00:00:01.000Z',
        ),
      ],
    );
    await waitForLastUsedFile();

    // The previous run's scan snapshot would re-expose codex through the
    // acceleration cache; remove it so the relaunch genuinely sees the agent
    // as gone.
    final dataDir = await portableData.clientDirectory();
    final cacheFile = File('${dataDir.path}/scanned-targets-cache.json');
    if (await cacheFile.exists()) {
      await cacheFile.delete();
    }

    final second = newController(
      agentService: FakeAgentService()
        ..scanTargetsResult = [claudeCodeTarget()],
    );
    addTearDown(second.dispose);
    await second.initialize();
    // Codex is no longer discovered; desktop does not select an unrelated
    // conversation in its place.
    second.scannedTargets = [claudeCodeTarget()];
    second.selectDefaultConversationAgent();

    expect(second.selectedConversationAgentId, isEmpty);
    expect(second.selectedConversationSessionId, isEmpty);
  });

  test('fresh desktop launch keeps the conversation selection empty', () async {
    final controller = newController(
      agentService: FakeAgentService()..scanTargetsResult = [codexTarget()],
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    controller.scannedTargets = [codexTarget()];
    controller.selectDefaultConversationAgent();

    expect(controller.selectedConversationAgentId, isEmpty);
    expect(controller.selectedConversationSessionId, isEmpty);
  });

  test('targets settle keeps an active agent selection when it is missing', () {
    final controller = newController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [codexTarget()];
    controller.selectedConversationAgentId = 'codex';
    // A background scan fails the codex probe and removes it from the
    // results; the settle callback must keep the active conversation
    // instead of switching to the default selection.
    controller.scannedTargets = [];
    controller.selectDefaultConversationAgent();
    expect(controller.selectedConversationAgentId, 'codex');
  });

  test(
    'restore applies after targets settle before the reference loads',
    () async {
      final first = newController();
      addTearDown(first.dispose);
      await first.initialize();
      first.scannedTargets = [codexTarget()];
      first.selectedConversationAgentId = 'codex';
      await first.conversationCommitTurnBoundNativeReadback(
        agentId: 'codex',
        nativeSessionId: 'native-early-settle-session',
        mergeWithSelectedSession: false,
        messages: const [
          AgentConversationMessage(
            id: 'synthetic-user',
            role: 'user',
            text: 'Session before the reference loads',
            createdAt: '2026-08-07T00:00:00.000Z',
          ),
          AgentConversationMessage(
            id: 'synthetic-assistant',
            role: 'assistant',
            text: 'Synthetic response',
            createdAt: '2026-08-07T00:00:01.000Z',
          ),
        ],
      );
      await waitForLastUsedFile();

      final second = newController();
      addTearDown(second.dispose);
      // Targets settle before the persisted reference loads. Desktop stays
      // unselected until the persisted reference becomes available.
      second.scannedTargets = [claudeCodeTarget(), codexTarget()];
      second.selectDefaultConversationAgent();
      expect(second.selectedConversationAgentId, isEmpty);
      // Loading the reference retries and applies the previous conversation.
      await second.initialize();
      expect(second.selectedConversationAgentId, 'codex');
    },
  );

  test('entering the agents section applies the pending restore', () async {
    final first = newController();
    addTearDown(first.dispose);
    await first.initialize();
    first.scannedTargets = [codexTarget()];
    first.selectedConversationAgentId = 'codex';
    await first.conversationCommitTurnBoundNativeReadback(
      agentId: 'codex',
      nativeSessionId: 'native-section-entry-session',
      mergeWithSelectedSession: false,
      messages: const [
        AgentConversationMessage(
          id: 'synthetic-user',
          role: 'user',
          text: 'Session to reopen on section entry',
          createdAt: '2026-08-07T00:00:00.000Z',
        ),
        AgentConversationMessage(
          id: 'synthetic-assistant',
          role: 'assistant',
          text: 'Synthetic response',
          createdAt: '2026-08-07T00:00:01.000Z',
        ),
      ],
    );
    await waitForLastUsedFile();

    // The previous run's scan snapshot would re-expose codex through the
    // acceleration cache; remove it so the relaunch starts with no targets.
    final dataDir = await portableData.clientDirectory();
    final cacheFile = File('${dataDir.path}/scanned-targets-cache.json');
    if (await cacheFile.exists()) {
      await cacheFile.delete();
    }

    final second = newController(
      agentService: FakeAgentService()..scanTargetsResult = const [],
    );
    addTearDown(second.dispose);
    // No agent is visible during initialization, so the restore stays
    // pending and no selection is made.
    await second.initialize();
    expect(second.selectedConversationAgentId, isEmpty);

    // Entering the agents section must apply the pending restore instead of
    // jumping straight to a different visible agent.
    second.scannedTargets = [codexTarget()];
    second.clientEnterAgentsSection();
    expect(second.selectedConversationAgentId, 'codex');
  });
}
