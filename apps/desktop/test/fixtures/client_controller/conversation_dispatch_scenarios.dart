import 'package:path/path.dart' as p;

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
        attempt < 20 &&
            (service.runtimeMessageCalls == 0 ||
                controller.sendingConversationTurnId.isEmpty);
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      await controller.sendConversationMessage('Steer now');

      expect(service.runtimeSteerCalls, 1);
      expect(service.lastRuntimeSteerRequest['agent'], 'codex');
      expect(service.lastRuntimeSteerRequest['sessionId'], 'native-session-1');
      expect(service.lastRuntimeSteerRequest['turnId'], 'native-turn-1');
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
        attempt < 20 &&
            (service.runtimeMessageCalls == 0 ||
                controller.sendingConversationTurnId.isEmpty);
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
      attempt < 20 &&
          (service.runtimeMessageCalls == 0 ||
              controller.sendingConversationTurnId.isEmpty);
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
            binaryPath: '/test-bin/codex',
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
    'reasoning-effort catalog resolves while the model stays on the agent default',
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
            binaryPath: '/test-bin/codex',
            adapterStatus: 'implemented',
            modelCatalog: const {
              'status': 'available',
              'defaultModel': 'model-canary',
              'models': [
                {
                  'name': 'model-canary',
                  'reasoningEfforts': ['low', 'high'],
                },
                {'name': 'model-plain'},
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

      // Model left on Auto: the composer must still offer the efforts the
      // agent's own default model would run with.
      expect(controller.selectedConversationModel, isEmpty);
      expect(controller.selectedConversationReasoningEffortOptions, [
        'low',
        'high',
      ]);

      controller.selectConversationReasoningEffort('high');
      expect(controller.selectedConversationReasoningEffort, 'high');
      expect(controller.lastError, isEmpty);
    },
  );

  test(
    'selected working directory survives the new-session projection',
    () async {
      final workingDirectory = Directory.systemTemp
          .createTempSync('licoup-selected-workspace-')
          .path;
      addTearDown(() {
        final directory = Directory(workingDirectory);
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectNewConversationWorkingDirectory(workingDirectory);

      expect(controller.selectedConversationWorkingDirectory, workingDirectory);

      await controller.sendConversationMessage('Create in this project');

      expect(
        service.lastRuntimeMessageRequest['workingDirectory'],
        workingDirectory,
      );
      expect(
        controller.selectedConversationSession?.workingDirectory,
        workingDirectory,
      );
      expect(
        controller.selectedConversationSession?.title,
        'Create in this project',
      );

      final nativeSessionId =
          controller.selectedConversationSession?.nativeSessionId ?? '';
      expect(nativeSessionId, isNotEmpty);
      await controller.reloadSelectedConversationSessionsAfterSend(
        'codex',
        preferredNativeSessionId: nativeSessionId,
      );

      expect(controller.selectedConversationWorkingDirectory, workingDirectory);
      expect(
        controller.selectedConversationSession?.workingDirectory,
        workingDirectory,
      );

      await controller.sendConversationMessage('Continue in this project');

      expect(
        service.runtimeMessageRequests
            .map((request) => request['workingDirectory'])
            .toList(),
        [workingDirectory, workingDirectory],
      );
    },
  );

  test(
    'an unusable selected workspace fails the send instead of a silent default',
    () async {
      final workingDirectory = Directory.systemTemp
          .createTempSync('licoup-removed-workspace-')
          .path;
      addTearDown(() {
        final directory = Directory(workingDirectory);
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectNewConversationWorkingDirectory(workingDirectory);

      expect(controller.selectedConversationWorkingDirectory, workingDirectory);

      Directory(workingDirectory).deleteSync(recursive: true);

      await controller.sendConversationMessage('Create in this project');

      expect(
        controller.lastError,
        'conversation_working_directory_unavailable',
      );
      expect(service.runtimeMessageCalls, 0);
      expect(controller.isSendingConversationMessage, isFalse);
      expect(controller.selectedConversationSession, isNull);
    },
  );

  test(
    'live process card is bound to the conversation it was sent in',
    () async {
      final gate = Completer<void>();
      final service = FakeAgentService()
        ..runtimeMessageGate = gate
        ..conversationSessions = {
          'codex': [
            conversationSessionJson(
              id: 'one',
              agentId: 'codex',
              text: 'turn in one',
              updatedAt: '2026-06-01T00:00:00Z',
              workingDirectory: Directory.systemTemp
                  .createTempSync('licoup-scope-one-')
                  .path,
            ),
            conversationSessionJson(
              id: 'two',
              agentId: 'codex',
              text: 'turn in two',
              updatedAt: '2026-06-02T00:00:00Z',
              workingDirectory: Directory.systemTemp
                  .createTempSync('licoup-scope-two-')
                  .path,
            ),
          ],
        };
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectConversationSession('one');

      final sending = controller.sendConversationMessage('Working in one');
      for (
        var attempt = 0;
        attempt < 20 && service.runtimeMessageCalls == 0;
        attempt += 1
      ) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(service.runtimeMessageCalls, 1);
      expect(controller.selectedLiveConversationMessages, isNotEmpty);

      controller.selectConversationSession('two');
      expect(controller.selectedLiveConversationMessages, isEmpty);

      controller.selectConversationSession('one');
      expect(controller.selectedLiveConversationMessages, isNotEmpty);

      gate.complete();
      await sending;
    },
  );

  test(
    'local conversation defaults to the client-owned agent workspace',
    () async {
      final home =
          (Platform.environment['HOME'] ??
                  Platform.environment['USERPROFILE'] ??
                  '')
              .trim();
      expect(home, isNotEmpty);
      final expected = localConversationWorkingDirectoryFallback(
        agentId: 'codex',
      );
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');

      expect(controller.selectedConversationWorkingDirectory, expected);
      expect(expected, isNot(home));
      expect(expected, isNot('/'));
      expect(isUnboundedLocalAgentWorkspace(expected), isFalse);

      await controller.sendConversationMessage('where are we');

      expect(service.lastRuntimeMessageRequest['workingDirectory'], expected);
      // The client-owned fallback is used for the turn, but not persisted as
      // the session's project path — relaunch must be free to bind native cwd.
      expect(controller.selectedConversationSession?.workingDirectory, isEmpty);
    },
  );

  test(
    'new conversation reuses the newest historical working directory',
    () async {
      final olderDirectory = Directory.systemTemp
          .createTempSync('licoup-history-older-')
          .path;
      final historicalDirectory = Directory.systemTemp
          .createTempSync('licoup-history-newer-')
          .path;
      addTearDown(() {
        for (final directory in [olderDirectory, historicalDirectory]) {
          final entry = Directory(directory);
          if (entry.existsSync()) {
            entry.deleteSync(recursive: true);
          }
        }
      });
      final service = FakeAgentService()
        ..conversationSessions = {
          'codex': [
            conversationSessionJson(
              id: 'older',
              agentId: 'codex',
              text: 'older turn',
              updatedAt: '2026-01-01T00:00:00Z',
              workingDirectory: olderDirectory,
            ),
            conversationSessionJson(
              id: 'newer',
              agentId: 'codex',
              text: 'newer turn',
              updatedAt: '2026-06-01T00:00:00Z',
              workingDirectory: historicalDirectory,
            ),
          ],
        };
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');

      expect(controller.preparingNewConversation, isTrue);
      expect(
        controller.selectedConversationWorkingDirectory,
        historicalDirectory,
      );

      await controller.sendConversationMessage('continue in history project');

      expect(
        service.lastRuntimeMessageRequest['workingDirectory'],
        historicalDirectory,
      );
    },
  );

  test(
    'a session stuck on agent-workspace recovers a historical project path',
    () async {
      final historicalDirectory = Directory.systemTemp
          .createTempSync('licoup-history-cwd-')
          .path;
      addTearDown(() {
        final directory = Directory(historicalDirectory);
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });
      final fallback = localConversationWorkingDirectoryFallback(
        agentId: 'codex',
      );
      final service = FakeAgentService()
        ..conversationSessions = {
          'codex': [
            conversationSessionJson(
              id: 'stuck',
              agentId: 'codex',
              text: 'stuck on fallback',
              updatedAt: '2026-07-01T00:00:00Z',
              workingDirectory: fallback,
            ),
            conversationSessionJson(
              id: 'history',
              agentId: 'codex',
              text: 'history project',
              updatedAt: '2026-06-01T00:00:00Z',
              workingDirectory: historicalDirectory,
            ),
          ],
        };
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectConversationSession('stuck');

      expect(controller.preparingNewConversation, isFalse);
      expect(
        controller.selectedConversationSession?.workingDirectory,
        fallback,
      );
      expect(
        controller.selectedConversationWorkingDirectory,
        historicalDirectory,
      );

      await controller.sendConversationMessage('leave the fallback workspace');

      expect(
        service.lastRuntimeMessageRequest['workingDirectory'],
        historicalDirectory,
      );
    },
  );

  test(
    'turn-bound readback keeps catalog project directories for the agent',
    () async {
      final projectDirectory = Directory.systemTemp
          .createTempSync('licoup-turn-cwd-')
          .path;
      addTearDown(() {
        final directory = Directory(projectDirectory);
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });
      const nativeSessionId = 'native-turn-cwd';
      final service = FakeAgentService()
        ..conversationSessions = {
          'codex': [
            conversationSessionJson(
              id: 'catalog',
              agentId: 'codex',
              nativeSessionId: nativeSessionId,
              text: 'catalog project',
              updatedAt: '2026-08-01T00:00:00Z',
              workingDirectory: projectDirectory,
            ),
          ],
        };
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      expect(controller.selectedConversationWorkingDirectory, projectDirectory);

      await controller.conversationCommitTurnBoundNativeReadback(
        agentId: 'codex',
        nativeSessionId: nativeSessionId,
        messages: [
          const AgentConversationMessage(
            id: 'u1',
            role: 'user',
            text: 'follow up',
            createdAt: '2026-08-05T00:00:00Z',
          ),
          const AgentConversationMessage(
            id: 'a1',
            role: 'assistant',
            text: 'ok',
            createdAt: '2026-08-05T00:00:01Z',
          ),
        ],
        mergeWithSelectedSession: true,
        workingDirectory: localConversationWorkingDirectoryFallback(
          agentId: 'codex',
        ),
      );

      expect(
        controller.selectedConversationWorkingDirectory,
        projectDirectory,
        reason: 'composer must not fall back to agent-workspace after readback',
      );
      expect(
        controller.selectedConversationSessions.any(
          (session) => isUsableLocalConversationWorkingDirectory(
            session.workingDirectory,
          ),
        ),
        isTrue,
      );
    },
  );

  test(
    'local workspace capsule stays selectable outside a new-conversation draft',
    () async {
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      expect(controller.preparingNewConversation, isTrue);
      expect(controller.canSelectNewConversationWorkingDirectory, isTrue);
      expect(
        controller.selectedConversationWorkingDirectory,
        localConversationWorkingDirectoryFallback(agentId: 'codex'),
      );

      // Selecting a session abandons the new-conversation draft; the shared
      // client-owned fallback must remain clickable so the user can rebind.
      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession(
            id: 'codex-1',
            agentId: 'codex',
            title: 'Prior turn',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-02T00:00:00Z',
            messages: const [],
            workingDirectory: localConversationWorkingDirectoryFallback(
              agentId: 'codex',
            ),
          ),
        ],
      };
      controller.selectConversationSession('codex-1');
      expect(controller.preparingNewConversation, isFalse);
      expect(controller.canSelectNewConversationWorkingDirectory, isTrue);
      expect(
        controller.selectedConversationWorkingDirectory,
        localConversationWorkingDirectoryFallback(agentId: 'codex'),
      );

      final project = [
        '',
        'synthetic',
        'workspaces',
        'rebind-project',
      ].join('/');
      controller.selectNewConversationWorkingDirectory(project);
      expect(controller.lastError, isEmpty);
      expect(controller.selectedConversationWorkingDirectory, project);
    },
  );

  test('a personal tree root is refused as an agent workspace', () async {
    final home =
        (Platform.environment['HOME'] ??
                Platform.environment['USERPROFILE'] ??
                '')
            .trim();
    expect(home, isNotEmpty);
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    await controller.selectConversationAgent('codex');
    final defaultWorkspace = controller.selectedConversationWorkingDirectory;

    controller.selectNewConversationWorkingDirectory(home);

    expect(controller.lastError, 'conversation_working_directory_unbounded');
    expect(controller.selectedConversationWorkingDirectory, defaultWorkspace);

    controller.selectNewConversationWorkingDirectory(p.join(home, 'Pictures'));

    expect(controller.lastError, 'conversation_working_directory_unbounded');
    expect(controller.selectedConversationWorkingDirectory, defaultWorkspace);

    final project = p.join(home, 'Documents', 'synthetic-project');
    controller.selectNewConversationWorkingDirectory(project);

    expect(controller.lastError, isEmpty);
    expect(controller.selectedConversationWorkingDirectory, project);
  });

  test(
    'new-conversation working directory selection persists per agent',
    () async {
      final directoryA = ['', 'synthetic', 'workspaces', 'project-a'].join('/');
      final directoryB = ['', 'synthetic', 'workspaces', 'project-b'].join('/');
      TargetCandidate fixtureTarget(String id, String label) => TargetCandidate(
        target: id,
        label: label,
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 0.9,
        binaryPath: ['', 'opt', 'lico-test', 'bin', id].join('/'),
        adapterStatus: 'implemented',
        adapterCapabilities: parityReadyAdapterCapabilities,
        supportedActions: const ['runtime.message.send'],
      );
      final service = FakeAgentService()
        ..scanTargetsResult = [
          fixtureTarget('codex', 'Codex'),
          fixtureTarget('opencode', 'OpenCode'),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectNewConversationWorkingDirectory(directoryA);
      await controller.selectConversationAgent('opencode');
      controller.selectNewConversationWorkingDirectory(directoryB);

      expect(controller.selectedConversationWorkingDirectory, directoryB);

      await controller.selectConversationAgent('codex');
      expect(controller.selectedConversationWorkingDirectory, directoryA);

      await controller.selectConversationAgent('opencode');
      expect(controller.selectedConversationWorkingDirectory, directoryB);
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
      controller.selectConversationSession('projection-only-id');

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
}

TargetCandidate _steerReadyTarget({bool interruptSteer = true}) {
  return TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    binaryPath: '/test-bin/codex',
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
