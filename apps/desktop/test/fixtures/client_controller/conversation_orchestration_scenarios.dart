import 'package:path/path.dart' as p;

import 'support/client_controller_scenario_dependencies.dart';
import 'support/client_controller_scenario_environment.dart';
import 'support/client_controller_scenario_json.dart';
import 'support/fake_agent_service.dart';

void registerClientConversationOrchestrationScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default orchestration requires a configured policy before sending',
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
            adapterCapabilities: parityReadyAdapterCapabilities,
            supportedActions: const ['runtime.message.send'],
          ),
        ];
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.sendConversationMessage('Fix the failing tests');

      expect(
        controller.selectedConversationAgentId,
        agentOrchestrationTargetId,
      );
      expect(controller.agentOrchestrationPolicyConfigured, isFalse);
      expect(service.runtimeMessageCalls, 0);
      expect(controller.selectedConversationSession?.messages, isEmpty);
      expect(
        controller.lastError,
        'default orchestration policy not configured',
      );
      expect(controller.statusMessage, contains('未配置'));
    },
  );

  test(
    'default orchestration accepts commander-only policy and dispatches to it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-commander-only-policy-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final service = FakeAgentService()
        ..runtimeMessageResultQueue = [
          {'text': 'Final routed assistant reply.'},
        ]
        ..runtimeMessageStreamEventQueue = [
          [
            {
              'event': 'agent.message.chunk',
              'payload': {'text': 'Partial '},
            },
            {
              'event': 'agent.message.chunk',
              'payload': {'text': 'Partial routed '},
            },
            {
              'event': 'agent.message.chunk',
              'payload': {'text': 'routed '},
            },
            {
              'event': 'agent.message.chunk',
              'payload': {'text': 'assistant '},
            },
            {
              'event': 'agent.message.completed',
              'payload': {'text': 'Final routed assistant reply.'},
            },
          ],
        ]
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

      await controller.scanTargets();
      await controller.saveAgentOrchestrationPolicy(
        const AgentOrchestrationPolicy(
          commanderAgentId: 'codex',
          commanderModelName: 'gpt-5.5',
          commanderReasoningEffort: 'high',
        ),
      );

      expect(controller.agentOrchestrationPolicyConfigured, isTrue);
      expect(
        controller.effectiveAgentOrchestrationPolicy.modelLibrary,
        isEmpty,
      );
      expect(controller.statusMessage, '默认编排策略已保存。');

      final observedReplies = <String>[];
      controller.addListener(() {
        final session = controller.selectedConversationSession;
        if (session?.agentId != agentOrchestrationTargetId) {
          return;
        }
        observedReplies.addAll(
          session!.messages
              .where((message) => message.role == 'assistant')
              .map((message) => message.text),
        );
      });
      await controller.sendConversationMessage('Fix the failing tests');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest['agent'], 'codex');
      expect(service.lastRuntimeMessageRequest['model'], 'gpt-5.5');
      expect(service.lastRuntimeMessageRequest['reasoningEffort'], 'high');
      expect(controller.lastError, isEmpty);
      expect(observedReplies, contains('Partial '));
      expect(observedReplies, contains('Partial routed '));
      expect(observedReplies, contains('Partial routed assistant '));
      expect(
        controller.selectedConversationSession!.threadMessages.map(
          (message) => (message.role, message.text),
        ),
        [
          ('user', 'Fix the failing tests'),
          ('assistant', 'Final routed assistant reply.'),
        ],
      );
      expect(
        controller.selectedConversationSession!.messages.any(
          (message) => message.text.contains('已发送'),
        ),
        isFalse,
      );
    },
  );

  test(
    'default orchestration A to A continues the exact native session',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-orchestration-same-session-',
      );
      addTearDown(() => deleteTempDirectory(directory));
      final service = FakeAgentService()
        ..scanTargetsResult = [
          TargetCandidate(
            target: 'codex',
            label: 'Codex',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 1,
            adapterStatus: 'implemented',
            modelCatalog: const {
              'status': 'available',
              'models': [
                {'name': 'gpt-test'},
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

      await controller.scanTargets();
      await controller.saveAgentOrchestrationPolicy(
        const AgentOrchestrationPolicy(
          commanderAgentId: 'codex',
          commanderModelName: 'gpt-test',
        ),
      );
      await controller.sendConversationMessage('First turn');
      await controller.sendConversationMessage('Second turn');

      expect(service.runtimeMessageRequests, hasLength(2));
      expect(
        service.runtimeMessageRequests.first.containsKey('sessionId'),
        isFalse,
      );
      expect(
        service.runtimeMessageRequests.last['sessionId'],
        'native-codex-1',
      );
    },
  );

  test(
    'persists default orchestration policy across controller initialize',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-orchestration-policy-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final targets = [
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
        TargetCandidate(
          target: 'claude-code',
          label: 'Claude Code',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 0.9,
          adapterStatus: 'implemented',
          modelCatalog: const {
            'status': 'available',
            'models': [
              {
                'name': 'deepseek-v4-flash',
                'reasoningEfforts': ['high'],
              },
            ],
          },
          adapterCapabilities: parityReadyAdapterCapabilities,
          supportedActions: const ['runtime.message.send'],
        ),
      ];
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final controller = ClientController(
        portableData: portableData,
        agentService: FakeAgentService()..scanTargetsResult = targets,
      );
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.saveAgentOrchestrationPolicy(
        AgentOrchestrationPolicy(
          label: 'Review Policy',
          commanderAgentId: 'codex',
          commanderModelName: 'gpt-5.5',
          commanderReasoningEffort: 'high',
          modelLibrary: const [
            AgentModelLibraryEntry(
              agentId: 'codex',
              modelName: 'gpt-5.5',
              reasoningEffort: 'high',
            ),
            AgentModelLibraryEntry(
              agentId: 'claude-code',
              modelName: 'deepseek-v4-flash',
              reasoningEffort: 'high',
            ),
          ],
        ),
      );

      final policyFile = File(
        p.join(directory.path, 'licoup', 'routing', 'routing-policy.json'),
      );
      expect(await policyFile.exists(), isTrue);

      final reloaded = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService()..scanTargetsResult = targets,
      );
      addTearDown(reloaded.dispose);

      await reloaded.initialize();

      expect(reloaded.agentOrchestrationPolicyConfigured, isTrue);
      expect(reloaded.effectiveAgentOrchestrationPolicy.label, 'Review Policy');
      expect(
        reloaded.effectiveAgentOrchestrationPolicy.commanderAgentId,
        'codex',
      );
      expect(
        reloaded.effectiveAgentOrchestrationPolicy.commanderModelName,
        'gpt-5.5',
      );
      expect(
        reloaded.effectiveAgentOrchestrationPolicy.commanderReasoningEffort,
        'high',
      );
      expect(
        reloaded.effectiveAgentOrchestrationPolicy.modelLibrary.map(
          (e) => e.key,
        ),
        [
          const AgentModelLibraryEntry(
            agentId: 'codex',
            modelName: 'gpt-5.5',
            reasoningEffort: 'high',
          ).key,
          const AgentModelLibraryEntry(
            agentId: 'claude-code',
            modelName: 'deepseek-v4-flash',
            reasoningEffort: 'high',
          ).key,
        ],
      );
    },
  );
}
