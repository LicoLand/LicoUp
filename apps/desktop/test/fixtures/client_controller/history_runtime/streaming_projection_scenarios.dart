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
              'event': 'dispatch.turn.bound',
              'sessionId': 'native-codex-turn-bound',
              'turnId': 'turn-1',
              'payload': {'nativeSteer': true},
            },
            {
              'event': 'agent.turn.processing',
              'sessionId': 'native-codex-turn-bound',
              'turnId': 'turn-1',
              'payload': {'evidenceKind': 'tool'},
            },
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
        if (!readbackGate.isCompleted) readbackGate.complete();
      });
      final observedReplies = <String>[];
      final observedProcessKinds = <AgentConversationMessageKind>[];
      var liveProjectionUpdates = 0;
      controller.liveConversationListenable.addListener(() {
        liveProjectionUpdates += 1;
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
      expect(observedReplies, containsAll(['Hello world', 'Hello world.']));
      expect(observedReplies, isNot(contains('Hello')));
      expect(observedReplies, isNot(contains('Hello worldworld')));
      // Evidence-driven budget: one live projection update per observable
      // native advance — accepted, processing, responding, the coalesced
      // reply publish, the tool step, the final reply, and completed. The
      // 32ms reply-publish timer keeps chunk bursts below this bound; a
      // per-chunk publish storm would exceed it.
      expect(liveProjectionUpdates, lessThanOrEqualTo(7));
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
      expect(
        committedSession?.messages
            .where((message) => message.cardType == 'lifecycle')
            .single
            .cardSubtitle,
        'submitted,accepted,processing,responding,completed',
      );
    },
  );
}
