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
      // reply publish, the tool step, the final reply, commit, and completed.
      // The 32ms reply-publish timer keeps chunk bursts below this bound; a
      // per-chunk publish storm would exceed it.
      expect(liveProjectionUpdates, lessThanOrEqualTo(8));
      expect(
        observedProcessKinds,
        contains(AgentConversationMessageKind.toolCall),
      );
      expect(controller.selectedLiveConversationMessages, isEmpty);
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

  test(
    'runtime update events project one in-place runtime-update card',
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
              'event': 'agent.runtime.updating',
              'sessionId': 'native-codex-turn-bound',
              'turnId': 'turn-1',
              'payload': {
                'artifact': 'cursor-agent',
                'version': '2026.08.04-aaa8809',
                'phase': 'downloading',
              },
            },
            {
              'event': 'agent.runtime.updating',
              'sessionId': 'native-codex-turn-bound',
              'turnId': 'turn-1',
              'payload': {
                'artifact': 'cursor-agent',
                'version': '2026.08.04-aaa8809',
                'phase': 'installing',
              },
            },
            {
              'event': 'agent.runtime.update.completed',
              'sessionId': 'native-codex-turn-bound',
              'turnId': 'turn-1',
              'payload': {
                'artifact': 'cursor-agent',
                'version': '2026.08.04-aaa8809',
              },
            },
            {
              'event': 'agent.message.chunk',
              'payload': {'text': 'Hello world.'},
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
      var updateCardCounts = <int>[];
      var updateCardSubtitles = <String>[];
      controller.liveConversationListenable.addListener(() {
        final live = controller.selectedLiveConversationMessages;
        final cards = live.where(
          (message) => message.cardType == 'runtime-update',
        );
        updateCardCounts.add(cards.length);
        updateCardSubtitles.addAll(
          cards.map((message) => message.cardSubtitle),
        );
      });
      await controller.sendConversationMessage('Send while updating');
      // One in-place card per turn at every revision (upsert, not append).
      // The live projection clears after the turn commits, so later revisions
      // may observe zero cards; never more than one.
      expect(updateCardCounts, isNotEmpty);
      expect(updateCardCounts.any((count) => count == 1), isTrue);
      expect(updateCardCounts.every((count) => count <= 1), isTrue);
      // The turn-bound readback is the durable owner after commit; the live
      // projection is cleared once the committed catalog entry is selected.
      expect(controller.selectedLiveConversationMessages, isEmpty);
      final cards = controller.selectedConversationSession!.messages
          .where((message) => message.cardType == 'runtime-update')
          .toList();
      expect(cards, hasLength(1));
      final card = cards.single;
      expect(card.id, endsWith('-runtime-update'));
      expect(card.role, 'event');
      expect(card.text, 'completed');
      // Phase text surfaced before completion, version preserved.
      expect(updateCardSubtitles, anyElement(contains('下载中')));
      expect(card.cardSubtitle, contains('2026.08.04-aaa8809'));
      // Update events must not advance the turn lifecycle beyond accepted;
      // the later message events advance it to responding/completed as usual.
      final lifecycle = controller.selectedConversationSession!.messages
          .where((message) => message.cardType == 'lifecycle')
          .single;
      expect(lifecycle.cardSubtitle, 'submitted,accepted,responding,completed');
      // The turn itself still converges.
      expect(
        controller.selectedConversationSession!.messages
            .where((message) => message.role == 'assistant')
            .map((message) => message.text),
        contains('Hello world.'),
      );
    },
  );
}
