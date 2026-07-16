import 'package:path/path.dart' as p;

import 'support/client_controller_routing_harness.dart';
import 'support/client_controller_scenario_dependencies.dart';
import 'support/client_controller_scenario_environment.dart';
import 'support/client_controller_scenario_json.dart';
import 'support/fake_agent_service.dart';

void registerClientRoutingScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production orchestration routes policy switch through real lane sessions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-routing-production-callsite-',
      );
      addTearDown(() => deleteTempDirectory(directory));
      final targets = [
        for (final (id, label) in const [
          ('codex', 'Codex'),
          ('claude-code', 'Claude Code'),
        ])
          TargetCandidate(
            target: id,
            label: label,
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 0.9,
            adapterStatus: 'implemented',
            modelCatalog: {
              'status': 'available',
              'models': [
                {'name': '$id-model'},
              ],
            },
            adapterCapabilities: parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
      ];
      final service = FakeAgentService()
        ..scanTargetsResult = targets
        ..runtimeMessageResultQueue = [
          {'nativeSessionId': 'native-primary-session'},
          {
            'nativeSessionId': 'native-distiller-session',
            'text': jsonEncode({
              'objective': 'Continue the routed task.',
              'currentState': 'Agent reply 1 established the primary session.',
              'decisions': ['Switch through the routing coordinator.'],
              'constraints': ['Use the unified dispatch lane.'],
              'openItems': ['Continue in the target session.'],
            }),
          },
          {'nativeSessionId': 'native-target-session'},
        ];
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
      );
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.saveAgentOrchestrationPolicy(
        const AgentOrchestrationPolicy(
          commanderAgentId: 'codex',
          commanderModelName: 'codex-model',
        ),
      );
      await controller.sendConversationMessage('Start the routed task');

      await controller.saveAgentOrchestrationPolicy(
        const AgentOrchestrationPolicy(
          commanderAgentId: 'claude-code',
          commanderModelName: 'claude-code-model',
        ),
      );
      await controller.sendConversationMessage('Continue the routed task');

      expect(service.runtimeMessageRequests, hasLength(4));
      expect(service.runtimeMessageRequests[0]['agent'], 'codex');
      expect(
        service.runtimeMessageRequests[0].containsKey('sessionId'),
        isFalse,
      );
      expect(service.runtimeMessageRequests[1]['agent'], 'codex');
      expect(
        service.runtimeMessageRequests[1]['text'],
        contains('Agent reply 1'),
      );
      expect(
        service.runtimeMessageRequests[1]['text'],
        isNot(contains('Continue the routed task')),
      );
      expect(
        service.runtimeMessageRequests[1].containsKey('sessionId'),
        isFalse,
      );
      expect(service.runtimeMessageRequests[2]['agent'], 'claude-code');
      expect(
        service.runtimeMessageRequests[2].containsKey('sessionId'),
        isFalse,
      );
      expect(service.runtimeMessageRequests[3]['agent'], 'claude-code');
      expect(
        service.runtimeMessageRequests[3]['sessionId'],
        'native-target-session',
      );
      expect(
        service.runtimeMessageRequests[3]['text'],
        contains('Continue the routed task'),
      );
      expect(
        service.runtimeMessageRequests[2]['text'],
        startsWith('Lico Arc routed handoff:'),
      );
    },
  );

  test(
    'policy reload during a live stream waits for the next message boundary',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-routing-message-boundary-',
      );
      addTearDown(() => deleteTempDirectory(directory));
      final targets = [
        for (final id in const ['codex', 'claude-code'])
          TargetCandidate(
            target: id,
            label: id,
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 1,
            adapterStatus: 'implemented',
            modelCatalog: {
              'status': 'available',
              'models': [
                {'name': '$id-model'},
              ],
            },
            adapterCapabilities: parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
      ];
      final gate = Completer<void>();
      final service = FakeAgentService()
        ..scanTargetsResult = targets
        ..runtimeMessageGate = gate;
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
      );
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.saveAgentOrchestrationPolicy(
        const AgentOrchestrationPolicy(
          commanderAgentId: 'codex',
          commanderModelName: 'codex-model',
        ),
      );
      final firstSend = controller.sendConversationMessage('First turn');
      while (service.runtimeMessageCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      await controller.saveAgentOrchestrationPolicy(
        const AgentOrchestrationPolicy(
          commanderAgentId: 'claude-code',
          commanderModelName: 'claude-code-model',
        ),
      );
      expect(service.runtimeMessageCalls, 1);
      expect(service.runtimeMessageRequests.single['agent'], 'codex');

      gate.complete();
      await firstSend;
      service.runtimeMessageGate = null;
      service.runtimeMessageResultQueue = [
        {
          'text': jsonEncode({
            'objective': 'Continue the First turn after the policy boundary.',
            'currentState': 'Agent reply 1 completed the first turn on Codex.',
            'decisions': ['Apply the queued policy at the next message.'],
            'constraints': ['Do not switch during an in-flight stream.'],
            'openItems': ['Continue on Claude Code.'],
          }),
        },
        {'nativeSessionId': 'native-claude-handoff'},
        {'nativeSessionId': 'native-claude-handoff'},
      ];

      await controller.sendConversationMessage('Second turn');

      expect(service.runtimeMessageRequests, hasLength(4));
      expect(service.runtimeMessageRequests[1]['agent'], 'codex');
      expect(service.runtimeMessageRequests[2]['agent'], 'claude-code');
      expect(service.runtimeMessageRequests[3]['agent'], 'claude-code');
      expect(
        service.runtimeMessageRequests[3]['sessionId'],
        'native-claude-handoff',
      );
    },
  );

  test('controller hot reload applies the canonical routing policy', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-routing-controller-reload-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
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
                'name': 'gpt-5.5',
                'reasoningEfforts': ['high'],
              },
            ],
          },
          adapterCapabilities: parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: service,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.agentOrchestrationPolicyConfigured, isFalse);

    final policyFile = File(
      p.join(directory.path, 'lico-client', 'routing', 'routing-policy.json'),
    );
    await policyFile.writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'id': 'hot-reloaded',
        'label': 'Hot Reloaded',
        'agents': [
          {
            'id': 'codex',
            'modelName': 'gpt-5.5',
            'reasoningEffort': 'high',
            'coordinator': true,
            'priority': 1,
          },
        ],
      }),
    );

    for (
      var attempt = 0;
      attempt < 80 && !controller.agentOrchestrationPolicyConfigured;
      attempt += 1
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    expect(controller.agentOrchestrationPolicy.id, 'hot-reloaded');
    final plan = controller.previewRoutingDispatchPlan('reload');
    expect(plan.routes.single.agentId, 'codex');
    expect(plan.routes.single.modelName, 'gpt-5.5');
  });

  test(
    'serial-all dispatches every eligible route in priority order',
    () async {
      final service = FakeAgentService();
      final harness = await createRoutingStrategyHarness(
        strategy: 'serial-all',
        service: service,
      );
      addTearDown(harness.controller.dispose);
      addTearDown(() => deleteTempDirectory(harness.directory));

      final preview = harness.controller.previewRoutingDispatchPlan(
        'Run every serial route',
      );
      expect(preview.blocked, isFalse);
      expect(preview.routes.map((route) => route.agentId), [
        'codex',
        'claude-code',
        'opencode',
      ]);

      await harness.controller.sendConversationMessage(
        'Run every serial route',
      );

      expect(
        service.runtimeMessageRequests.map((request) => request['agent']),
        ['codex', 'claude-code', 'opencode'],
      );
      expect(harness.controller.lastError, isEmpty);
      expect(
        harness.controller.selectedConversationSession!.threadMessages.where(
          (message) => message.role == 'assistant',
        ),
        hasLength(3),
      );
    },
  );

  test(
    'parallel-all starts every eligible route before any completes',
    () async {
      final gate = Completer<void>();
      final service = FakeAgentService()..runtimeMessageGate = gate;
      final harness = await createRoutingStrategyHarness(
        strategy: 'parallel-all',
        service: service,
      );
      addTearDown(harness.controller.dispose);
      addTearDown(() => deleteTempDirectory(harness.directory));

      final send = harness.controller.sendConversationMessage(
        'Run every parallel route',
      );
      await waitForRuntimeMessageCount(service, 3);

      expect(
        service.runtimeMessageRequests.map((request) => request['agent']),
        ['codex', 'claude-code', 'opencode'],
      );
      gate.complete();
      await send;
      expect(harness.controller.lastError, isEmpty);
    },
  );

  test('coordinator-workers synthesizes only after worker results', () async {
    final service = FakeAgentService();
    final harness = await createRoutingStrategyHarness(
      strategy: 'coordinator-workers',
      service: service,
    );
    addTearDown(harness.controller.dispose);
    addTearDown(() => deleteTempDirectory(harness.directory));

    await harness.controller.sendConversationMessage(
      'Delegate and synthesize the work',
    );

    expect(service.runtimeMessageRequests.map((request) => request['agent']), [
      'claude-code',
      'opencode',
      'codex',
    ]);
    final coordinatorPrompt = service.runtimeMessageRequests.last['text']
        .toString();
    expect(
      coordinatorPrompt,
      contains('Worker results to verify and synthesize'),
    );
    expect(coordinatorPrompt, contains('claude-code: Agent reply 1'));
    expect(coordinatorPrompt, contains('opencode: Agent reply 2'));
    expect(harness.controller.lastError, isEmpty);
  });

  test('priority-fallback stops when the first outcome is unknown', () async {
    final service = FakeAgentService()
      ..runtimeMessageResultQueue = [
        {
          'ok': false,
          'code': 'transport_timeout',
          'transient': true,
          'outcomeKnown': false,
          'text': '',
        },
      ];
    final harness = await createRoutingStrategyHarness(
      strategy: 'priority-fallback',
      service: service,
    );
    addTearDown(harness.controller.dispose);
    addTearDown(() => deleteTempDirectory(harness.directory));

    await harness.controller.sendConversationMessage('Do not duplicate work');

    expect(service.runtimeMessageRequests, hasLength(1));
    expect(service.runtimeMessageRequests.single['agent'], 'codex');
    expect(
      harness.controller.lastError,
      'default orchestration dispatch failed',
    );
  });

  test('priority-fallback stops on a known terminal failure', () async {
    final service = FakeAgentService()
      ..runtimeMessageResultQueue = [
        {
          'ok': false,
          'code': 'authentication_failed',
          'transient': false,
          'outcomeKnown': true,
          'text': '',
        },
      ];
    final harness = await createRoutingStrategyHarness(
      strategy: 'priority-fallback',
      service: service,
    );
    addTearDown(harness.controller.dispose);
    addTearDown(() => deleteTempDirectory(harness.directory));

    await harness.controller.sendConversationMessage('Do not bypass auth');

    expect(service.runtimeMessageRequests, hasLength(1));
    expect(service.runtimeMessageRequests.single['agent'], 'codex');
  });

  test(
    'priority-fallback requires explicit transient and known outcome facts',
    () async {
      final service = FakeAgentService()
        ..runtimeMessageResultQueue = [
          {
            'ok': false,
            'code': 'provider_busy',
            'transient': true,
            'outcomeKnown': true,
            'text': '',
          },
          {'text': 'Fallback completed.'},
        ];
      final harness = await createRoutingStrategyHarness(
        strategy: 'priority-fallback',
        service: service,
      );
      addTearDown(harness.controller.dispose);
      addTearDown(() => deleteTempDirectory(harness.directory));

      await harness.controller.sendConversationMessage('Fallback safely');

      expect(
        service.runtimeMessageRequests.map((request) => request['agent']),
        ['codex', 'claude-code'],
      );
      expect(harness.controller.lastError, isEmpty);
      expect(
        harness
            .controller
            .selectedConversationSession!
            .threadMessages
            .last
            .text,
        'Fallback completed.',
      );
    },
  );

  test(
    'priority-fallback does not infer safety from a transient error code',
    () async {
      final service = FakeAgentService()
        ..runtimeMessageResultQueue = [
          {
            'ok': false,
            'code': 'provider_busy',
            'transient': false,
            'outcomeKnown': true,
            'text': '',
          },
        ];
      final harness = await createRoutingStrategyHarness(
        strategy: 'priority-fallback',
        service: service,
      );
      addTearDown(harness.controller.dispose);
      addTearDown(() => deleteTempDirectory(harness.directory));

      await harness.controller.sendConversationMessage(
        'Error spelling is not authority',
      );

      expect(service.runtimeMessageRequests, hasLength(1));
      expect(service.runtimeMessageRequests.single['agent'], 'codex');
    },
  );
}
