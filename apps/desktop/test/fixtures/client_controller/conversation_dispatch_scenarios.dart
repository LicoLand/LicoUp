import 'conversation_orchestration_scenarios.dart' as orchestration;

import 'support/client_controller_scenario_dependencies.dart';
import 'support/client_controller_scenario_json.dart';
import 'support/fake_agent_service.dart';

void registerClientConversationDispatchScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'in-flight follow-ups use bounded FIFO and continue the returned native session',
    () async {
      final gate = Completer<void>();
      final service = FakeAgentService()..runtimeMessageGate = gate;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      final first = controller.sendConversationMessage('First turn');
      for (
        var attempt = 0;
        attempt < 20 && service.runtimeMessageCalls == 0;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      await controller.sendConversationMessage('Second turn');
      expect(
        service.runtimeMessageCalls,
        1,
        reason:
            'selected=${controller.selectedConversationAgentId} '
            'targets=${controller.scannedTargets.map((target) => target.target).join(',')} '
            'relay=${controller.selectedConversationAgent?.canRelayRuntime} '
            'sending=${controller.isSendingConversationMessage} '
            'error=${controller.lastError}',
      );
      expect(controller.queuedConversationTurnCount, 1);

      gate.complete();
      await first;
      for (
        var attempt = 0;
        attempt < 40 &&
            (service.runtimeMessageCalls < 2 ||
                controller.isSendingConversationMessage);
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(service.runtimeMessageRequests.map((request) => request['text']), [
        'First turn',
        'Second turn',
      ]);
      expect(
        service.runtimeMessageRequests.last['sessionId'],
        'native-codex-1',
      );
      expect(controller.queuedConversationTurnCount, 0);
    },
  );

  test(
    'native steer consumes an in-flight follow-up without queueing',
    () async {
      final gate = Completer<void>();
      final service = FakeAgentService()
        ..runtimeMessageGate = gate
        ..scanTargetsResult = [_steerReadyTarget()]
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-session-1',
            agentId: 'codex',
            text: 'Existing native conversation',
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectConversationSession('native-session-1');
      final first = controller.sendConversationMessage('First turn');
      for (
        var attempt = 0;
        attempt < 20 && service.runtimeMessageCalls == 0;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      await controller.sendConversationMessage('Steer now');

      expect(service.runtimeSteerCalls, 1);
      expect(service.lastRuntimeSteerRequest['agent'], 'codex');
      expect(service.lastRuntimeSteerRequest['sessionId'], 'native-session-1');
      expect(service.lastRuntimeSteerRequest['text'], 'Steer now');
      expect(service.runtimeMessageCalls, 1);
      expect(controller.queuedConversationTurnCount, 0);

      gate.complete();
      await first;
    },
  );

  test(
    'unknown native steer outcome is never resent through the FIFO',
    () async {
      final gate = Completer<void>();
      final service = FakeAgentService()
        ..runtimeMessageGate = gate
        ..runtimeSteerThrows = true
        ..scanTargetsResult = [_steerReadyTarget()]
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-session-1',
            agentId: 'codex',
            text: 'Existing native conversation',
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectConversationSession('native-session-1');
      final first = controller.sendConversationMessage('First turn');
      for (
        var attempt = 0;
        attempt < 20 && service.runtimeMessageCalls == 0;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      await controller.sendConversationMessage('Do not duplicate');
      expect(controller.lastError, 'dispatch_steer_outcome_unknown');
      expect(controller.queuedConversationTurnCount, 0);

      gate.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(service.runtimeMessageCalls, 1);
    },
  );

  test('explicitly unavailable steer falls back to the bounded FIFO', () async {
    final gate = Completer<void>();
    final service = FakeAgentService()
      ..runtimeMessageGate = gate
      ..runtimeSteerResult = const {
        'ok': false,
        'status': 'unavailable',
        'error': {'code': 'dispatch_steer_transport_unavailable'},
      }
      ..scanTargetsResult = [_steerReadyTarget()]
      ..conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-session-1',
          agentId: 'codex',
          text: 'Existing native conversation',
        ),
      ];
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    await controller.selectConversationAgent('codex');
    controller.selectConversationSession('native-session-1');
    final first = controller.sendConversationMessage('First turn');
    for (
      var attempt = 0;
      attempt < 20 && service.runtimeMessageCalls == 0;
      attempt += 1
    ) {
      await Future<void>.delayed(Duration.zero);
    }

    await controller.sendConversationMessage('Queue after unavailable steer');
    expect(service.runtimeSteerCalls, 1);
    expect(controller.queuedConversationTurnCount, 1);

    gate.complete();
    await first;
    for (
      var attempt = 0;
      attempt < 40 &&
          (service.runtimeMessageCalls < 2 ||
              controller.isSendingConversationMessage);
      attempt += 1
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(service.runtimeMessageCalls, 2);
    expect(controller.queuedConversationTurnCount, 0);
  });

  test(
    'dispose clears queued follow-ups and ignores late completion',
    () async {
      final gate = Completer<void>();
      final service = FakeAgentService()..runtimeMessageGate = gate;
      final controller = ClientController(agentService: service);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      final first = controller.sendConversationMessage('First turn');
      for (
        var attempt = 0;
        attempt < 20 && service.runtimeMessageCalls == 0;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      await controller.sendConversationMessage('Pending turn');
      expect(controller.queuedConversationTurnCount, 1);

      controller.dispose();
      expect(controller.queuedConversationTurnCount, 0);

      gate.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(service.runtimeMessageCalls, 1);
    },
  );

  test('cancel clears FIFO and stays bound to the active agent', () async {
    final gate = Completer<void>();
    final service = FakeAgentService()
      ..runtimeMessageGate = gate
      ..scanTargetsResult = [
        _steerReadyTarget(interruptSteer: false),
        TargetCandidate(
          target: 'opencode',
          label: 'OpenCode',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'implemented',
          adapterCapabilities: parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ]
      ..conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-session-1',
          agentId: 'codex',
          text: 'Existing native conversation',
        ),
      ];
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    await controller.selectConversationAgent('codex');
    controller.selectConversationSession('native-session-1');
    final first = controller.sendConversationMessage('First turn');
    for (
      var attempt = 0;
      attempt < 20 && service.runtimeMessageCalls == 0;
      attempt += 1
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.sendConversationMessage('Queued follow-up');
    expect(controller.queuedConversationTurnCount, 1);
    controller.selectedConversationAgentId = 'opencode';

    await controller.cancelActiveConversationTurn();

    expect(controller.queuedConversationTurnCount, 0);
    expect(service.runtimeCancelCalls, 1);
    expect(service.lastRuntimeCancelRequest['agent'], 'codex');
    expect(service.lastRuntimeCancelRequest['sessionId'], 'native-session-1');

    gate.complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(service.runtimeMessageCalls, 1);
  });

  test(
    'failed active turn stops queued follow-ups without duplicate send',
    () async {
      final gate = Completer<void>();
      final service = FakeAgentService()
        ..runtimeMessageGate = gate
        ..runtimeMessageResultQueue = [
          {
            'ok': false,
            'error': {'code': 'known_turn_failure'},
          },
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      final first = controller.sendConversationMessage('First turn');
      for (
        var attempt = 0;
        attempt < 20 && service.runtimeMessageCalls == 0;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      await controller.sendConversationMessage('Must not duplicate');
      gate.complete();
      await first;
      await Future<void>.delayed(Duration.zero);

      expect(service.runtimeMessageCalls, 1);
      expect(controller.queuedConversationTurnCount, 0);
    },
  );

  test(
    'sendConversationMessage uses the driver-owned native continuity id',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'codex-native-thread',
            agentId: 'codex',
            text: 'Existing native Codex history',
          ),
        ]
        ..runtimeSessionIdResult = 'codex-process-session'
        ..runtimeThreadIdResult = 'codex-native-thread'
        ..runtimeNativeSessionIdResult = 'codex-native-thread';
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectConversationSession('codex-native-thread');
      await controller.sendConversationMessage('Continue the native thread');

      expect(service.runtimeMessageCalls, 1);
      expect(
        service.lastRuntimeMessageRequest['sessionId'],
        'codex-native-thread',
      );
      expect(controller.lastError, isEmpty);
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'codex-native-thread',
      );
    },
  );

  test(
    'sendConversationMessage executes despite unverified parity evidence',
    () async {
      final service = FakeAgentService()
        ..scanTargetsResult = [
          TargetCandidate(
            target: 'opencode',
            label: 'OpenCode',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 0.9,
            binaryPath: 'test-binary-opencode',
            adapterStatus: 'implemented',
            adapterCapabilities: const {
              'conversationDriver': 'implemented',
              'conversationProtocol': 'opencode-serve-http-v1',
              'conversationReadiness': 'unverified',
              'conversationBlocker': 'live_release_parity_evidence_missing',
            },
            supportedActions: const ['runtime.message.send'],
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('opencode');
      await controller.sendConversationMessage(
        'execute and report real failures',
      );

      expect(service.runtimeMessageCalls, 1);
      expect(controller.lastError, isEmpty);
    },
  );

  test(
    'conversation composer forwards selected native model settings',
    () async {
      final service = FakeAgentService()
        ..scanTargetsResult = [
          TargetCandidate(
            target: 'codex',
            label: 'Codex',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 0.9,
            adapterStatus: 'implemented',
            modelCatalog: const {
              'status': 'available',
              'models': [
                {
                  'name': 'model-canary',
                  'reasoningEfforts': ['high'],
                },
              ],
            },
            adapterCapabilities: parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectConversationModel('model-canary');
      controller.selectConversationReasoningEffort('high');
      controller.startNewConversationSession();
      await controller.sendConversationMessage('settings parity canary');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest['model'], 'model-canary');
      expect(service.lastRuntimeMessageRequest['reasoningEffort'], 'high');
    },
  );

  test(
    'sendConversationMessage never substitutes a projection session id',
    () async {
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      controller.selectedConversationAgentId = 'codex';
      controller.selectedConversationSessionId = 'projection-only-id';
      controller.conversationSessionsByAgent = {
        'codex': const [
          AgentConversationSession(
            id: 'projection-only-id',
            nativeSessionId: '',
            agentId: 'codex',
            title: 'Read-only projection',
            createdAt: '2026-07-10T00:00:00Z',
            updatedAt: '2026-07-10T00:00:00Z',
            messages: [],
          ),
        ],
      };

      await controller.sendConversationMessage('do not fork this session');

      expect(service.runtimeMessageCalls, 0);
      expect(controller.lastError, 'native_session_id_missing');
    },
  );

  test(
    'sendConversationMessage never resumes the newest session for a stale selection',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'newer-concurrent-session',
            agentId: 'codex',
            text: 'A different native conversation',
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectConversationSession('stale-deleted-session');

      await controller.sendConversationMessage(
        'must not resume another thread',
      );

      expect(service.runtimeMessageCalls, 0);
      expect(controller.lastError, 'native_session_unresolved');
    },
  );

  test(
    'send readback never falls back to the newest unrelated session',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'newest-unrelated-session',
            agentId: 'codex',
            text: 'Concurrent conversation',
          ),
        ]
        ..runtimeSessionIdResult = 'returned-session-not-yet-indexed'
        ..recordRuntimeMessageInHistory = false;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.startNewConversationSession();
      await controller.sendConversationMessage('create an exact new session');

      expect(service.runtimeMessageCalls, 1);
      expect(controller.selectedConversationSessionId, isNotEmpty);
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'returned-session-not-yet-indexed',
      );
      expect(controller.lastError, isEmpty);
      expect(
        service.cliCalls.any(
          (args) =>
              args.length >= 2 &&
              args[0] == 'conversations' &&
              args.contains('--session-id') &&
              args.contains('returned-session-not-yet-indexed'),
        ),
        isTrue,
      );

      await controller.sendConversationMessage('continue the exact session');

      expect(service.runtimeMessageCalls, 2);
      expect(controller.lastError, isEmpty);

      service.conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'newest-unrelated-session',
          agentId: 'codex',
          text: 'Concurrent conversation',
        ),
        conversationSessionJson(
          id: 'returned-session-projection',
          nativeSessionId: 'returned-session-not-yet-indexed',
          agentId: 'codex',
          text: 'Exact created conversation',
          updatedAt: '2026-07-10T00:00:01Z',
        ),
      ];
      await controller.refreshConversationSessions('codex');

      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'returned-session-not-yet-indexed',
      );
    },
  );

  orchestration.registerClientConversationOrchestrationScenarios();
}

TargetCandidate _steerReadyTarget({bool interruptSteer = true}) {
  return TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'implemented',
    adapterCapabilities: {
      ...parityReadyAdapterCapabilities,
      'conversationCapabilityMatrix': {
        'laneFamily': 'app-server',
        'interruptSteer': interruptSteer,
      },
    },
    supportedActions: const ['runtime.message.send'],
  );
}
