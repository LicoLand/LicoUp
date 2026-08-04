import 'fixtures/client_controller/support/client_controller_scenario_dependencies.dart';
import 'fixtures/client_controller/support/fake_agent_conversation_fixture.dart';
import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'package:licoup/src/contracts/generated/client_state.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native RPC failure keeps its stable stage code visible', () async {
    final service = FakeAgentService()
      ..runtimeMessageRpcErrorCode = 'invalid_response';
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.scanTargets();
    await controller.selectConversationAgent('codex');
    await controller.sendConversationMessage('Synthetic failed turn');

    expect(controller.lastError, 'native_agent_invalid_response');
    expect(
      controller.conversationSendErrorFor('codex'),
      'native_agent_invalid_response',
    );
    expect(controller.isSendingConversationMessage, isFalse);
  });

  test('non-send controller errors are not presented as send failures', () {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);

    controller.lastError = 'target_scan_failed';

    expect(controller.conversationSendErrorFor('codex'), isEmpty);
  });

  test(
    'main agent dispatch works when its runtime publishes no model catalog',
    () async {
      final service = FakeAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      controller.orchestrationPolicyDraft = const AgentOrchestrationPolicy(
        commanderAgentId: 'codex',
      ).toTomlConfig();
      await controller.selectConversationAgent(agentOrchestrationTargetId);
      controller.startNewConversationSession();

      expect(controller.agentOrchestrationPolicyConfigured, isTrue);
      expect(controller.agentOrchestrationManagerTarget?.target, 'codex');

      await controller.sendConversationMessage('Route through the main agent');
      await _settleAsyncProjection();

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest['agent'], 'codex');
      expect(service.lastRuntimeMessageRequest['model'], isNull);
      final session = controller.selectedConversationSession;
      expect(session?.agentId, agentOrchestrationTargetId);
      expect(session?.native, isFalse);
      expect(session?.readOnly, isFalse);
      expect(session?.id, isNot(session?.nativeSessionId));
      expect(
        session?.messages
            .where(
              (message) =>
                  message.role == 'user' &&
                  message.text == 'Route through the main agent',
            )
            .length,
        1,
      );
      expect(
        session?.messages
            .where((message) => message.cardType == 'lifecycle')
            .single
            .cardTitle,
        'lifecycle.completed',
      );
      expect(
        session?.messages
            .where((message) => message.cardType == 'lifecycle')
            .single
            .cardSubtitle,
        'submitted,completed',
      );
      final projectedKinds = session!.messages
          .where(
            (message) =>
                message.kind == AgentConversationMessageKind.user ||
                message.cardType == 'lifecycle' ||
                message.kind == AgentConversationMessageKind.assistant,
          )
          .map(
            (message) => message.cardType == 'lifecycle'
                ? 'lifecycle'
                : message.kind.name,
          );
      expect(projectedKinds, ['user', 'lifecycle', 'assistant']);
      expect(
        controller
                .liveConversationMessagesByAgent[agentOrchestrationTargetId] ??
            const [],
        isEmpty,
      );
      expect(
        session.messages
            .where((message) => message.role == 'assistant')
            .single
            .participantAgentId,
        'codex',
      );
      expect(
        controller.conversationSessionsByAgent['codex'] ?? const [],
        hasLength(1),
      );
      expect(
        (controller.conversationSessionsByAgent['codex'] ?? const [])
            .single
            .native,
        isTrue,
      );
      expect(controller.lastError, isEmpty);
    },
  );

  test('lifecycle updates stay between the request and reply', () {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);

    controller.conversationStartLiveProjection(
      agentId: agentOrchestrationTargetId,
      turnId: 'turn-1',
      userText: 'Request',
    );
    controller.conversationUpsertLiveReply(
      agentId: agentOrchestrationTargetId,
      turnId: 'turn-1',
      text: 'Reply',
    );
    controller.conversationUpsertLiveLifecycle(
      agentId: agentOrchestrationTargetId,
      turnId: 'turn-1',
      stage: 'completed',
    );

    expect(
      controller.liveConversationMessagesByAgent[agentOrchestrationTargetId]!
          .map((message) => message.id),
      ['turn-1-user', 'turn-1-lifecycle', 'turn-1-assistant'],
    );
  });

  test(
    'orchestration stream keeps subagent replies as named participants',
    () async {
      final service = FakeAgentService()
        ..runtimeMessageStreamEventQueue = [
          [
            {
              'event': 'agent.message.completed',
              'sessionId': 'native-codex-1',
              'payload': {
                'text': 'Architecture ready',
                'participantAgentId': 'designer',
                'participantLabel': 'Designer',
                'participantRole': 'designer',
              },
            },
            {
              'event': 'agent.message.completed',
              'sessionId': 'native-codex-1',
              'payload': {
                'text': 'Implementation ready',
                'participantAgentId': 'backend-worker',
                'participantLabel': 'Backend Worker',
                'participantRole': 'backend-worker',
              },
            },
          ],
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      controller.orchestrationPolicyDraft = const AgentOrchestrationPolicy(
        commanderAgentId: 'codex',
      ).toTomlConfig();
      await controller.selectConversationAgent(agentOrchestrationTargetId);
      controller.startNewConversationSession();

      await controller.sendConversationMessage('Build it');
      await _settleAsyncProjection();

      final assistantMessages = controller.selectedConversationSession!.messages
          .where((message) => message.role == 'assistant')
          .toList();
      expect(
        assistantMessages.map((message) => message.participantAgentId),
        containsAll(<String>['designer', 'backend-worker', 'codex']),
      );
      expect(
        assistantMessages.map((message) => message.participantRole),
        containsAll(<String>['designer', 'backend-worker', 'main-agent']),
      );
    },
  );

  test(
    'persisted main agent survives paint cache until runtime scan settles',
    () async {
      final service = _PersistedMainAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.scannedTargets = [_codexTarget(runtimeBound: false)];
      await controller.loadAgentOrchestrationPolicy();

      expect(
        (controller.orchestrationPolicyDraft['main_agent'] as Map)['agent'],
        'codex',
      );
      expect(controller.agentOrchestrationManagerTarget, isNull);
      expect(
        controller.agentOrchestrationConfiguredManagerTarget?.target,
        'codex',
      );

      controller.scannedTargets = [_codexTarget(runtimeBound: true)];
      await controller.selectConversationAgent(agentOrchestrationTargetId);

      expect(controller.agentOrchestrationPolicyConfigured, isTrue);
      expect(controller.agentOrchestrationManagerTarget?.target, 'codex');

      await controller.sendConversationMessage('Send after runtime scan');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest['agent'], 'codex');
      expect(controller.lastError, isEmpty);
    },
  );

  test(
    'saving does not erase a selection when the live scan refreshes',
    () async {
      final service = _RecordingFlywheelService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      controller.scannedTargets = [_codexTarget(runtimeBound: true)];
      final selected = const AgentOrchestrationPolicy(
        commanderAgentId: 'codex',
        commanderModelName: 'gpt-5.6-sol',
        commanderReasoningEffort: 'medium',
      );

      // Discovery is asynchronous and can transiently clear the catalog
      // after the dialog returns but before the state write begins.
      controller.scannedTargets = const [];
      await controller.saveAgentOrchestrationPolicy(selected);

      expect(
        (service.lastAdaptiveFlywheel?['main_agent'] as Map?)?['agent'],
        'codex',
      );
      expect(controller.agentOrchestrationPolicyConfigured, isTrue);
      expect(
        controller.effectiveAgentOrchestrationPolicy.commanderModelName,
        'gpt-5.6-sol',
      );
      expect(controller.agentOrchestrationManagerTarget, isNull);
      expect(controller.lastError, isEmpty);
    },
  );

  test(
    'delayed native readback does not fail or disable a completed turn',
    () async {
      final service = FakeAgentService()
        ..runtimeSessionIdResult = 'synthetic-delayed-session'
        ..recordRuntimeMessageInHistory = false;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.startNewConversationSession();
      await controller.sendConversationMessage('Synthetic successful turn');

      expect(controller.lastError, isEmpty);
      expect(controller.isSendingConversationMessage, isFalse);
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        'synthetic-delayed-session',
      );

      await controller.sendConversationMessage('Synthetic continuation');
      expect(service.runtimeMessageCalls, 2);
      expect(controller.lastError, isEmpty);
    },
  );

  test(
    'completed turn readback cannot reclaim a newly prepared conversation',
    () async {
      final service = FakeAgentService()
        ..runtimeSessionIdResult = 'completed-session';
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      final readbackGate = Completer<void>();
      service.conversationStreamGates['codex'] = readbackGate;

      controller.startNewConversationSession();
      await controller.sendConversationMessage('First conversation');
      expect(controller.selectedConversationSessionId, 'completed-session');

      controller.startNewConversationSession();
      expect(controller.preparingNewConversation, isTrue);
      expect(controller.selectedConversationSession, isNull);
      expect(controller.selectedLiveConversationMessages, isEmpty);

      readbackGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.preparingNewConversation, isTrue);
      expect(controller.selectedConversationSessionId, isEmpty);
      expect(controller.selectedConversationSession, isNull);

      service.conversationStreamGates.remove('codex');
      service.runtimeSessionIdResult = 'second-session';
      await controller.sendConversationMessage('Second conversation');

      expect(controller.selectedConversationSessionId, 'second-session');
      final secondMessages =
          controller.selectedConversationSession?.messages ?? const [];
      expect(
        secondMessages.any((message) => message.text == 'Second conversation'),
        isTrue,
      );
      expect(
        secondMessages.any((message) => message.text == 'First conversation'),
        isFalse,
      );
    },
  );

  test(
    'new conversation draft never inherits a refreshed previous session id',
    () async {
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          buildFakeConversationSession(
            id: 'previous-session',
            agentId: 'claude-code',
            agentLabel: 'Claude Code',
            text: 'Previous conversation',
          )..['nativeSessionId'] = 'previous-session',
        ]
        ..runtimeSessionIdResult = 'brand-new-session'
        ..recordRuntimeMessageInHistory = false;
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.startNewConversationSession();

      // Simulate a late catalog reconciliation writing the previous selection.
      // The draft token remains the sole authority for the first send.
      controller.selectedConversationSessionId = 'previous-session';
      expect(controller.preparingNewConversation, isTrue);
      expect(controller.selectedConversationSession, isNull);

      await controller.sendConversationMessage('Brand new conversation');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest['sessionId'], isNull);
      expect(controller.selectedConversationSessionId, 'brand-new-session');

      await controller.refreshConversationCatalogInternal(
        'codex',
        foreground: true,
      );

      expect(
        controller.selectedConversationSessions.map(
          (session) => session.nativeSessionId,
        ),
        contains('brand-new-session'),
      );
      expect(controller.selectedConversationSessionId, 'brand-new-session');
      expect(controller.preparingNewConversation, isFalse);
      expect(
        controller.selectedConversationSession?.messages.any(
          (message) => message.text == 'Previous conversation',
        ),
        isFalse,
      );
    },
  );
}

Future<void> _settleAsyncProjection() async {
  for (var index = 0; index < 8; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

TargetCandidate _codexTarget({required bool runtimeBound}) {
  return TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    binaryPath: runtimeBound ? '/synthetic/bin/codex' : null,
    adapterStatus: 'implemented',
    adapterCapabilities: const <String, dynamic>{
      'conversationDriver': 'implemented',
      'conversationProtocol': 'synthetic-native-protocol',
      'conversationReadiness': 'ready',
    },
  );
}

final class _PersistedMainAgentService extends FakeAgentService {
  @override
  Future<ClientStateGetResult> getClientState(ClientStateGetRequest request) {
    return Future.value(
      ClientStateGetResult(
        collection: request.collection,
        document: ClientStateDocument(
          schemaVersion: clientStateSchemaVersion,
          collection: request.collection,
          content: const <String, Object?>{
            'version': 1,
            'main_agent': <String, Object?>{
              'agent': 'codex',
              'model': '',
              'reasoning_effort': '',
            },
          },
        ),
      ),
    );
  }
}

final class _RecordingFlywheelService extends FakeAgentService {
  Map<String, Object?>? lastAdaptiveFlywheel;

  @override
  Future<ClientStateSetResult> setClientState(ClientStateSetRequest request) {
    if (request.collection == ClientStateCollection.adaptiveFlywheel) {
      lastAdaptiveFlywheel = request.document.content;
    }
    return Future.value(
      ClientStateSetResult(
        collection: request.collection,
        document: request.document,
        activity: const ClientStateActivity(
          schemaVersion: clientStateSchemaVersion,
          eventId: 'test-event',
          type: 'state.set',
          target: 'adaptive-flywheel',
          createdAt: '2026-08-03T00:00:00Z',
        ),
      ),
    );
  }
}
