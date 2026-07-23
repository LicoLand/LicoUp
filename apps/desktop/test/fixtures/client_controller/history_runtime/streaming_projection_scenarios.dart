import '../support/client_controller_scenario_dependencies.dart';
import '../support/client_controller_scenario_json.dart';
import '../support/fake_agent_service.dart';

void registerClientHistoryRuntimeStreamingProjectionScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
        ..runtimeSessionIdResult = 'native-codex-turn-bound'
        ..runtimeNativeSessionIdResult = 'native-codex-turn-bound'
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
      final readbackGate = Completer<void>();
      service.conversationStreamGates['codex'] = readbackGate;
      addTearDown(() {
        if (!readbackGate.isCompleted) {
          readbackGate.complete();
        }
      });
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
      expect(
        controller.selectedLiveConversationMessages
            .where((message) => message.role == 'assistant')
            .map((message) => message.text),
        contains('Hello world.'),
      );
      final committedSession = controller.selectedConversationSession;
      expect(committedSession?.id, 'native-codex-turn-bound');
      expect(committedSession?.nativeSessionId, 'native-codex-turn-bound');
      expect(
        committedSession?.messages
            .where((message) => message.role == 'user')
            .map((message) => message.text),
        contains('Show live progress'),
      );
      expect(
        committedSession?.messages
            .where((message) => message.role == 'assistant')
            .map((message) => message.text),
        contains('Hello world.'),
      );
    },
  );

  test(
    'completed streamed reply remains visible until native history catches up',
    () async {
      final staleSession = conversationSessionJson(
        id: 'claude-native-session',
        nativeSessionId: 'claude-native-session',
        agentId: 'claude-code',
        text: 'Existing native history',
      );
      final service = FakeAgentService()
        ..scanTargetsResult = [
          TargetCandidate(
            target: 'claude-code',
            label: 'Claude Code',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 1,
            binaryPath: '/synthetic/bin/claude',
            adapterStatus: 'implemented',
            adapterCapabilities: parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
        ]
        ..conversationSessions['claude-code'] = [staleSession]
        ..runtimeSessionIdResult = 'claude-native-session'
        ..runtimeNativeSessionIdResult = 'claude-native-session'
        ..runtimeMessageStreamEventQueue = [
          [
            {
              'event': 'agent.message.completed',
              'payload': {'text': 'Synthetic Claude reply'},
            },
          ],
        ]
        ..recordRuntimeMessageInHistory = false;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('claude-code');
      controller.selectConversationSession('claude-native-session');

      await controller.sendConversationMessage('Synthetic Claude prompt');

      expect(
        controller.selectedLiveConversationMessages
            .where((message) => message.role == 'assistant')
            .map((message) => message.text),
        contains('Synthetic Claude reply'),
      );

      service.conversationSessions['claude-code'] = [
        {
          ...staleSession,
          'messages': [
            ...(staleSession['messages'] as List),
            {
              'id': 'persisted-user',
              'role': 'user',
              'text': 'Synthetic Claude prompt',
            },
            {
              'id': 'persisted-assistant',
              'role': 'assistant',
              'text': 'Synthetic Claude reply',
            },
          ],
        },
      ];

      await controller.refreshConversationSessions('claude-code');

      expect(controller.selectedLiveConversationMessages, isEmpty);
      expect(
        controller.selectedConversationSession?.messages
            .where((message) => message.role == 'assistant')
            .map((message) => message.text),
        contains('Synthetic Claude reply'),
      );
    },
  );
}
