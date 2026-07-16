import 'support/client_controller_scenario_dependencies.dart';
import 'support/client_controller_scenario_json.dart';
import 'support/fake_agent_service.dart';

void registerClientHistoryRuntimeScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('agent switching restores each cached session selection', () async {
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
    controller.selectConversationSession('codex-old');
    await controller.selectConversationAgent('opencode');
    await controller.selectConversationAgent('codex');

    expect(controller.selectedConversationSession?.id, 'codex-old');
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

      expect(service.lastRuntimeMessageRequest, {
        'agent': 'codex',
        'text': 'Fresh prompt',
        'streamEvents': true,
        'workingDirectory': '/workspace/codex',
      });
      expect(controller.selectedConversationSession?.id, 'native-codex-new');
    },
  );

  test(
    'sendConversationMessage routes through runtime adapter without local append',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-controller-runtime-send-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-codex-1',
            agentId: 'codex',
            text: 'Existing native Codex history',
          ),
        ];
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
      );
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      await controller.sendConversationMessage('  Hello Codex  ');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest, {
        'agent': 'codex',
        'text': 'Hello Codex',
        'streamEvents': true,
        'sessionId': 'native-codex-1',
        'sessionPath': '/tmp/codex/history.jsonl',
        'workingDirectory': '/workspace/codex',
        'binaryPath': ['', 'opt', 'lico-test', 'bin', 'codex'].join('/'),
      });
      expect(service.conversationAppendCalls, 0);
      expect(controller.selectedConversationSessions, hasLength(1));
      expect(controller.lastError, isEmpty);
      expect(controller.statusMessage, '已通过 Codex 运行时适配器发送消息。');
      controller.localePreference = 'en';
      expect(
        controller.displayStatusMessage,
        'Sent the message through the Codex runtime adapter.',
      );
    },
  );

  test(
    'sendConversationMessage projects progressive reply and process events in the active conversation',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-codex-live',
            agentId: 'codex',
            text: 'Existing native Codex history',
          ),
        ]
        ..runtimeMessageStreamEventQueue = [
          [
            {
              'event': 'agent.message.chunk',
              'payload': {'text': 'Hello'},
            },
            {
              'event': 'agent.message.chunk',
              'payload': {'text': 'Hello world'},
            },
            {
              'event': 'agent.message.chunk',
              'payload': {'text': 'world'},
            },
            {
              'event': 'tool.call.started',
              'payload': {'summary': 'Inspecting workspace'},
            },
            {
              'event': 'agent.message.completed',
              'payload': {'text': 'Hello world.'},
            },
          ],
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      final observedReplies = <String>[];
      final observedProcessKinds = <AgentConversationMessageKind>[];
      controller.addListener(() {
        final live = controller.selectedLiveConversationMessages;
        observedReplies.addAll(
          live
              .where((message) => message.role == 'assistant')
              .map((message) => message.text),
        );
        observedProcessKinds.addAll(
          live
              .where((message) => message.isStructuredEvent)
              .map((message) => message.kind),
        );
      });

      await controller.sendConversationMessage('Show live progress');

      expect(
        observedReplies,
        containsAll(['Hello', 'Hello world', 'Hello world.']),
      );
      expect(observedReplies, isNot(contains('Hello worldworld')));
      expect(
        observedProcessKinds,
        contains(AgentConversationMessageKind.toolCall),
      );
      expect(controller.selectedLiveConversationMessages, isEmpty);
    },
  );
}
