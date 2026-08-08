import '../support/client_controller_scenario_dependencies.dart';
import '../support/client_controller_scenario_json.dart';
import '../support/fake_agent_service.dart';

void registerClientHistoryRuntimeSessionSelectionScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('agent switching lands on the new conversation home', () async {
    final service = FakeAgentService()
      ..conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'codex-new',
          agentId: 'codex',
          text: 'New Codex history',
          updatedAt: '2026-07-10T00:00:02Z',
        ),
        conversationSessionJson(
          id: 'codex-old',
          agentId: 'codex',
          text: 'Old Codex history',
          updatedAt: '2026-07-10T00:00:01Z',
        ),
      ]
      ..conversationSessions['opencode'] = [
        conversationSessionJson(
          id: 'opencode-session',
          agentId: 'opencode',
          text: 'OpenCode history',
        ),
      ];
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.selectConversationAgent('codex');
    expect(controller.preparingNewConversation, isTrue);
    expect(controller.selectedConversationSession, isNull);

    controller.selectConversationSession('codex-old');
    expect(controller.selectedConversationSession?.id, 'codex-old');

    await controller.selectConversationAgent('opencode');
    expect(controller.preparingNewConversation, isTrue);
    expect(controller.selectedConversationSession, isNull);

    await controller.selectConversationAgent('codex');
    expect(controller.preparingNewConversation, isTrue);
    expect(controller.selectedConversationSession, isNull);
  });

  test(
    'new conversation stays unselected across refresh and sends without session id',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-codex-old',
            agentId: 'codex',
            text: 'Older native Codex history',
            updatedAt: '2026-06-12T00:00:01Z',
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: false,
          confidence: 0.82,
          binaryPath: '/synthetic/bin/codex',
          adapterStatus: 'implemented',
          adapterCapabilities: parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];
      controller.selectedConversationAgentId = 'codex';
      await controller.loadConversationSessions('codex');

      expect(controller.selectedConversationSession?.id, 'native-codex-old');

      controller.startNewConversationSession();

      expect(controller.selectedConversationSessionId, isEmpty);
      expect(controller.selectedConversationSession, isNull);

      service.conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-codex-concurrent',
          agentId: 'codex',
          text: 'Concurrent native Codex history',
          updatedAt: '2026-06-15T00:00:01Z',
        ),
        conversationSessionJson(
          id: 'native-codex-new',
          agentId: 'codex',
          text: 'Newer native Codex history',
          updatedAt: '2026-06-14T00:00:01Z',
        ),
        conversationSessionJson(
          id: 'native-codex-old',
          agentId: 'codex',
          text: 'Older native Codex history',
          updatedAt: '2026-06-12T00:00:01Z',
        ),
      ];

      await controller.refreshConversationSessions('codex');

      expect(controller.selectedConversationSession, isNull);

      service.runtimeSessionIdResult = 'native-codex-new';
      await controller.sendConversationMessage('Fresh prompt');

      final fallbackWorkspace = localConversationWorkingDirectoryFallback(
        agentId: 'codex',
      );
      expect(service.lastRuntimeMessageRequest, {
        'agent': 'codex',
        'text': 'Fresh prompt',
        'streamEvents': true,
        'timeoutMs': 0,
        'permissionMode': 'bypassPermissions',
        'workingDirectory': fallbackWorkspace,
        'binaryPath': '/synthetic/bin/codex',
      });
      expect(controller.selectedConversationSession?.id, 'native-codex-new');
    },
  );
}
