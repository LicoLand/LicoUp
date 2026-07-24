import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/platform/native_client/orchestrator_ipc/client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('single backend authority projection', () {
    test(
      'registers and activates policy in the backend before GUI submit',
      () async {
        final backend = _DurableFakeOrchestrator();
        final gui = NativeOrchestratorClient.forTesting(call: backend.call);
        final policy = _canonicalPolicy('policy-alpha');

        final registered = await gui.registerPolicy(
          policy: policy,
          idempotencyKey: 'register-alpha',
        );
        expect(registered.policyRevision, 'revision-alpha');
        expect(registered.state, 'registered');
        expect(backend.registerEffects, 1);

        final activated = await gui.activatePolicy(
          policyRevision: registered.policyRevision,
          idempotencyKey: 'activate-alpha',
        );
        expect(activated.policyRevision, registered.policyRevision);
        expect(activated.state, 'active');
        expect(backend.activateEffects, 1);

        final guiProjection = await gui.submit(
          intent: const {'kind': 'implementation', 'summary': 'synthetic'},
          policyRevision: registered.policyRevision,
          idempotencyKey: 'submit-equivalent',
        );
        final expected = <String, Object?>{
          'workflowId': 'workflow-alpha',
          'policyRevision': 'revision-alpha',
          'sequence': 4,
          'state': 'completed',
          'adapterDecision': 'acp',
          'terminalReceipt': const {
            'state': 'completed',
            'digest': 'sha256:terminal-alpha',
          },
        };
        expect(guiProjection.toJson(), expected);
        expect(backend.dispatchEffects, 1);
        expect(
          backend.observedMethods,
          containsAllInOrder(const [
            'policy.register',
            'policy.activate',
            'workflow.submit',
          ]),
        );
      },
    );

    test('real Rust activation harness proves GUI CLI and MCP equivalence plus '
        'durable restart idempotency', () async {
      final result = await Process.run('npm', const [
        'run',
        'client:native:test',
        '--',
        'agent_orchestration_atomic_cutover_acceptance_harness',
        '--',
        '--nocapture',
      ], workingDirectory: '../..');
      final output = '${result.stdout}\n${result.stderr}';
      expect(result.exitCode, 0, reason: 'managed Rust cutover harness failed');
      expect(
        output,
        contains('agent_orchestration_atomic_cutover_acceptance_harness'),
        reason: 'the uniquely named real harness must execute',
      );
      expect(
        output,
        matches(RegExp(r'test result: ok\. 1 passed; 0 failed')),
        reason: 'a zero-test cargo filter is not acceptance',
      );
      const marker = 'LICOUP_CUTOVER_ACCEPTANCE ';
      final summaryLine = const LineSplitter()
          .convert(output)
          .where((line) => line.startsWith(marker))
          .single;
      final summary = jsonDecode(summaryLine.substring(marker.length));
      expect(summary, {
        'surfaces': ['desktop', 'cli', 'codex-mcp'],
        'privateEndpointCount': 1,
        'samePolicyRevision': true,
        'sameSequences': true,
        'sameAdapterDecision': true,
        'sameTerminalReceipt': true,
        'serviceStoreRestarted': true,
        'dispatchEffects': 1,
        'oldSchemaRejected': true,
        'malformedPolicyRejected': true,
      });
    });

    test('unknown or inactive policy revisions fail before dispatch', () async {
      final backend = _DurableFakeOrchestrator();
      final client = NativeOrchestratorClient.forTesting(call: backend.call);

      await expectLater(
        client.submit(
          intent: const {'kind': 'implementation'},
          policyRevision: 'revision-missing',
          idempotencyKey: 'missing-policy',
        ),
        throwsA(
          isA<OrchestratorClientException>().having(
            (error) => error.code,
            'code',
            'policy_revision_unavailable',
          ),
        ),
      );
      expect(backend.dispatchEffects, 0);

      final registered = await client.registerPolicy(
        policy: _canonicalPolicy('policy-inactive'),
        idempotencyKey: 'register-inactive',
      );
      await expectLater(
        client.submit(
          intent: const {'kind': 'implementation'},
          policyRevision: registered.policyRevision,
          idempotencyKey: 'inactive-policy',
        ),
        throwsA(
          isA<OrchestratorClientException>().having(
            (error) => error.code,
            'code',
            'policy_revision_inactive',
          ),
        ),
      );
      expect(backend.dispatchEffects, 0);
    });

    test(
      'Local Bridge projects wakeable progress and explicit delivery mode',
      () async {
        final observed = <String>[];
        final client = NativeOrchestratorClient.forTesting(
          call:
              ({
                required method,
                required params,
                idempotencyKey = '',
                clientKind = 'desktop',
              }) async {
                observed.add(method);
                if (method == 'workflow.wait') {
                  expect(params['timeoutMs'], 30000);
                  return <String, Object?>{
                    'workflowId': 'workflow-alpha',
                    'events': <Object?>[
                      <String, Object?>{
                        'cursor': 7,
                        'type': 'child.output.progress',
                        'state': 'running',
                        'stepId': 'implement',
                        'agentId': 'codex',
                        'outputBytes': 4096,
                      },
                    ],
                    'nextCursor': 7,
                    'hasMore': false,
                    'cursorExpired': false,
                    'timedOut': false,
                    'active': true,
                    'terminal': false,
                  };
                }
                expect(method, 'workflow.message');
                expect(params['message'], 'tighten the regression');
                expect(idempotencyKey, 'message-once');
                return <String, Object?>{
                  'workflowId': 'workflow-alpha',
                  'messageId': 'message-alpha',
                  'state': 'delivered',
                  'deliveryMode': 'native_steer',
                };
              },
        );

        final wait = await client.waitForProgress(
          workflowId: 'workflow-alpha',
          afterCursor: 6,
        );
        expect(wait.workflowId, 'workflow-alpha');
        expect(wait.nextCursor, 7);
        expect(wait.active, isTrue);
        expect(wait.events.single.type, 'child.output.progress');
        expect(wait.events.single.outputBytes, 4096);

        final message = await client.sendMessage(
          workflowId: 'workflow-alpha',
          message: 'tighten the regression',
          idempotencyKey: 'message-once',
        );
        expect(message.deliveryMode, 'native_steer');
        expect(observed, ['workflow.wait', 'workflow.message']);
      },
    );

    test(
      'old and malformed policy documents are rejected by the backend',
      () async {
        final backend = _DurableFakeOrchestrator();
        final client = NativeOrchestratorClient.forTesting(call: backend.call);

        final old = Map<String, Object?>.from(_canonicalPolicy('policy-old'))
          ..['schemaVersion'] = 1;
        await expectLater(
          client.registerPolicy(policy: old, idempotencyKey: 'register-old'),
          throwsA(
            isA<OrchestratorClientException>().having(
              (error) => error.code,
              'code',
              'policy_schema_unsupported',
            ),
          ),
        );

        final malformed = Map<String, Object?>.from(
          _canonicalPolicy('policy-malformed'),
        )..['fallbackAgent'] = 'must-not-be-accepted';
        await expectLater(
          client.registerPolicy(
            policy: malformed,
            idempotencyKey: 'register-malformed',
          ),
          throwsA(
            isA<OrchestratorClientException>().having(
              (error) => error.code,
              'code',
              'policy_schema_invalid',
            ),
          ),
        );
        expect(backend.registerEffects, 0);
        expect(backend.dispatchEffects, 0);
      },
    );

    test(
      'GUI projection reconnect resumes backend cursor and replay receipt',
      () async {
        final backend = _DurableFakeOrchestrator();
        final firstGui = NativeOrchestratorClient.forTesting(
          call: backend.call,
        );
        final registered = await firstGui.registerPolicy(
          policy: _canonicalPolicy('policy-alpha'),
          idempotencyKey: 'register-restart',
        );
        await firstGui.activatePolicy(
          policyRevision: registered.policyRevision,
          idempotencyKey: 'activate-restart',
        );
        final submitted = await firstGui.submit(
          intent: const {'kind': 'implementation', 'summary': 'restart'},
          policyRevision: registered.policyRevision,
          idempotencyKey: 'submit-restart',
        );
        expect(backend.dispatchEffects, 1);

        // Durable process/store restart is proven by the real Rust harness. This
        // case proves that a new GUI projection retains no local run authority.
        final restartedGui = NativeOrchestratorClient.forTesting(
          call: backend.call,
        );
        final status = await restartedGui.status(
          workflowId: submitted.workflowId,
        );
        expect(status.toJson(), submitted.toJson());

        final replay = await restartedGui.submit(
          intent: const {'kind': 'implementation', 'summary': 'restart'},
          policyRevision: registered.policyRevision,
          idempotencyKey: 'submit-restart',
        );
        expect(replay.toJson(), submitted.toJson());
        expect(backend.dispatchEffects, 1);

        final resumed = await restartedGui
            .subscribe(workflowId: submitted.workflowId, afterSequence: 1)
            .toList();
        expect(resumed.map((projection) => projection.sequence), [2, 3, 4]);
        expect(
          backend.eventCursors,
          [1],
          reason: 'the restarted GUI must use the backend cursor it received',
        );
        expect(backend.dispatchEffects, 1);
      },
    );

    test(
      'projection is monotonic immutable bounded and privacy-minimal',
      () async {
        final backend = _DurableFakeOrchestrator(includePrivacyCanaries: true);
        final client = NativeOrchestratorClient.forTesting(
          call: backend.call,
          maxProjectedEvents: 3,
        );
        final registered = await client.registerPolicy(
          policy: _canonicalPolicy('policy-alpha'),
          idempotencyKey: 'register-privacy',
        );
        await client.activatePolicy(
          policyRevision: registered.policyRevision,
          idempotencyKey: 'activate-privacy',
        );
        final submitted = await client.submit(
          intent: const {'kind': 'implementation'},
          policyRevision: registered.policyRevision,
          idempotencyKey: 'submit-privacy',
        );

        final projections = await client
            .subscribe(workflowId: submitted.workflowId, afterSequence: 0)
            .toList();
        expect(projections.map((projection) => projection.sequence), [2, 3, 4]);
        expect(projections, hasLength(3));
        expect(
          () => projections.last.events.add(
            const OrchestratorWorkflowEvent(sequence: 5, state: 'failed'),
          ),
          throwsUnsupportedError,
        );

        final encoded = jsonEncode([
          submitted.toJson(),
          for (final projection in projections) projection.toJson(),
        ]).toLowerCase();
        for (final canary in const [
          'prompt-canary',
          'reasoning-canary',
          'raw-output-canary',
          'native-session-canary',
          'private-path-canary',
          'credential-canary',
        ]) {
          expect(encoded, isNot(contains(canary)));
        }
        expect(
          encoded,
          isNot(
            contains(
              RegExp(
                r'prompt|reasoning|rawoutput|nativesession|path|credential',
              ),
            ),
          ),
        );
      },
    );
  });

  group('atomic ownership source boundary', () {
    test('retired Dart execution policy and run authority is physically removed', () {
      const retiredPaths = [
        'lib/src/application/features/agents/orchestration/agent_orchestration_dispatch_models.dart',
        'lib/src/application/features/agents/orchestration/agent_orchestration_routing_boundary_controller.dart',
        'lib/src/application/features/agents/policy/routing_circuit_breaker_registry.dart',
        'lib/src/application/features/routing/broker/distillation_broker.dart',
        'lib/src/application/features/routing/broker/distillation_prompt.dart',
        'lib/src/application/features/routing/controller/routing_module_lifecycle_controller.dart',
        'lib/src/application/features/routing/controller/routing_policy_editor_adapter.dart',
        'lib/src/application/features/routing/controller/task_route_coordinator.dart',
        'lib/src/application/features/routing/engine/route_evaluator.dart',
        'lib/src/application/features/routing/engine/route_planner.dart',
        'lib/src/application/features/routing/engine/routing_dispatch_engine.dart',
        'lib/src/application/features/routing/engine/sequential_routing_state_machine.dart',
        'lib/src/application/features/routing/excluded_routing_module_registration.dart',
        'lib/src/application/features/routing/routing_module_flags.dart',
        'lib/src/application/features/routing/routing_module_registration_factory.dart',
        'lib/src/application/features/routing/routing_module_registration_impl.dart',
        'lib/src/backend/features/routing/services/policy_file_watcher.dart',
        'lib/src/backend/features/routing/services/policy_store.dart',
        'lib/src/backend/features/routing/services/route_history_store.dart',
        'lib/src/backend/features/routing/services/route_session_binding_store.dart',
        'lib/src/contracts/routing/route_decision_record.dart',
        'lib/src/contracts/routing/route_history.dart',
        'lib/src/contracts/routing/routing_dispatch_failure.dart',
        'lib/src/contracts/routing/routing_dispatch_plan.dart',
        'lib/src/contracts/routing/routing_policy_models.dart',
        'lib/src/contracts/routing/routing_policy_results.dart',
        'lib/src/contracts/routing/routing_policy_schema.dart',
        'lib/src/contracts/routing/routing_workflow_schema.dart',
        'lib/src/contracts/routing/task_route_coordinator_port.dart',
        'lib/src/contracts/routing/routing_module_registration.dart',
        'lib/src/contracts/agent_orchestration_policy.dart',
        'lib/src/contracts/agent_orchestration_policy_catalog.dart',
        'lib/src/contracts/agent_orchestration_policy_codec.dart',
        'lib/src/contracts/agent_orchestration_policy_merge.dart',
        'lib/src/contracts/agent_orchestration_policy_models.dart',
        'lib/src/contracts/agent_orchestration_policy_validation.dart',
      ];
      for (final path in retiredPaths) {
        expect(
          File(path).existsSync(),
          isFalse,
          reason: 'retired authority: $path',
        );
      }
    });

    test('no compatibility dual-write or direct adapter bypass remains', () {
      final dartSources = Directory('lib/src')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList(growable: false);
      final sourceByPath = <String, String>{
        for (final file in dartSources) file.path: file.readAsStringSync(),
      };
      final allSource = sourceByPath.values.join('\n');

      for (final retiredSymbol in const [
        'SequentialRoutingStateMachine',
        'TaskRouteCoordinator',
        'FileRoutingPolicyStore',
        'RoutingPolicyStore',
        'RoutingPolicyDocument',
        'RouteHistoryStore',
        'ProtectedRouteSessionBindingStore',
        'RoutingDispatchEngine',
        'RouteEvaluator',
        'RoutePlanner',
        'AgentOrchestrationPolicyCodec',
        'normalizeAgentOrchestrationPolicy',
        'agentOrchestrationDispatchModelLibrary',
      ]) {
        expect(
          allSource,
          isNot(contains(retiredSymbol)),
          reason: retiredSymbol,
        );
      }

      final authoritySurface = sourceByPath.entries
          .where(
            (entry) =>
                entry.key.contains('/agents/orchestration/') ||
                entry.key.contains('/features/routing/') ||
                entry.key.contains('/contracts/routing/') ||
                entry.key.contains('/controller/assembly/') ||
                entry.key.endsWith('/controller/client_routing_facade.dart') ||
                entry.key.endsWith(
                  '/agents/workspace/agent_workspace_coordinator.dart',
                ) ||
                entry.key.contains(
                  '/platform/native_client/orchestrator_ipc/',
                ) ||
                entry.key.endsWith(
                  '/platform/native_client/native_command_router.dart',
                ) ||
                entry.key.endsWith(
                  '/platform/native_client/native_cli_ports.dart',
                ),
          )
          .map((entry) => entry.value)
          .join('\n');
      for (final bypass in const [
        'conversationGateway.send(',
        'conversationGateway.sendStreaming(',
        'conversationGateway.cancel(',
        'dispatchOrchestrationRoute(',
        'takeQueuedPolicy(',
        'previewRoutingDispatchPlan(',
        'AgentDispatchLane',
      ]) {
        expect(authoritySurface, isNot(contains(bypass)), reason: bypass);
      }
      expect(
        authoritySurface,
        isNot(
          contains(
            RegExp(
              r'legacy|compat(?:ibility)?|dualWrite|fallbackDecoder|migrateRouting',
              caseSensitive: false,
            ),
          ),
        ),
      );
      for (final retiredStrategy in const [
        'serial-all',
        'parallel-all',
        'priority-fallback',
        'coordinator-workers',
      ]) {
        expect(
          authoritySurface,
          isNot(contains(retiredStrategy)),
          reason: 'retired embedded strategy: $retiredStrategy',
        );
      }

      final policyController = File(
        'lib/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart',
      ).readAsStringSync();
      expect(policyController, contains('NativeOrchestratorClient'));
      expect(policyController, contains('.registerPolicy('));
      expect(policyController, contains('.activatePolicy('));
      expect(policyController, isNot(contains('File(')));
      expect(policyController, isNot(contains('Directory(')));
    });

    test('desktop CLI and MCP are thin clients of the same IPC contract', () {
      final desktop = File(
        'lib/src/platform/native_client/orchestrator_ipc/client.dart',
      ).readAsStringSync();
      final cli = File(
        '../../crates/licoup-native/src/bin/licoup/orchestrator.rs',
      ).readAsStringSync();
      final mcp = File(
        '../../crates/licoup-native/src/bin/lico-codex-mcp.rs',
      ).readAsStringSync();

      expect(desktop, contains('NativeOrchestratorClient'));
      expect(desktop, contains("'policy.register'"));
      expect(desktop, contains("'policy.activate'"));
      for (final method in const [
        'workflow.submit',
        'workflow.status',
        'workflow.cancel',
        'workflow.approve',
        'workflow.events',
        'workflow.wait',
        'workflow.message',
      ]) {
        expect(desktop, contains("'$method'"), reason: 'desktop $method');
        expect(cli, contains('"$method"'), reason: 'CLI $method');
        expect(mcp, contains('"$method"'), reason: 'MCP $method');
      }
      expect(cli, contains('OrchestratorIpcClient'));
      expect(mcp, contains('OrchestratorIpcClient'));
      expect(mcp, contains('.with_client_kind("codex-mcp")'));
    });

    test(
      'existing client architecture and layout boundary oracle passes',
      () async {
        final result = await Process.run('npm', const [
          'run',
          'client:verify:architecture',
        ], workingDirectory: '../..');
        expect(
          result.exitCode,
          0,
          reason: 'existing deterministic architecture/layout oracle failed',
        );
      },
    );
  });
}

Map<String, Object?> _canonicalPolicy(String id) => <String, Object?>{
  'schemaVersion': 3,
  'id': id,
  'label': 'Synthetic cutover policy',
  'commander': null,
  'modelLibrary': const [
    {
      'agentId': 'fixture-agent',
      'modelId': 'fixture-model',
      'reasoningLevel': 'max',
    },
  ],
  'agents': const [
    {
      'id': 'fixture-agent',
      'roles': ['implementation'],
      'capabilities': ['conversation.send'],
    },
  ],
  'workflow': const {
    'steps': [
      {
        'id': 'implement',
        'predecessorId': null,
        'purpose': 'action',
        'roleId': 'implementation',
        'agentId': 'fixture-agent',
        'modelId': 'fixture-model',
        'reasoningLevel': 'max',
        'contextStepIds': <String>[],
        'maxContextBytes': 4096,
        'outputMode': 'text',
        'timeoutMs': 1000,
        'maxAttempts': 1,
        'failureAction': 'stop',
        'approval': {'required': false},
        'condition': null,
        'validation': null,
      },
    ],
  },
};

final class _DurableFakeOrchestrator {
  _DurableFakeOrchestrator({this.includePrivacyCanaries = false});

  final bool includePrivacyCanaries;
  final List<String> observedMethods = [];
  final List<int> eventCursors = [];
  final Map<String, Map<String, Object?>> _receipts = {};
  final Set<String> _registered = {};
  String _activeRevision = '';
  int registerEffects = 0;
  int activateEffects = 0;
  int dispatchEffects = 0;

  Future<Map<String, Object?>> call({
    required String method,
    required Map<String, Object?> params,
    String idempotencyKey = '',
    String clientKind = 'desktop',
  }) async {
    observedMethods.add(method);
    switch (method) {
      case 'policy.register':
        final policy = params['policy']! as Map<String, Object?>;
        _validateCanonicalPolicy(policy);
        return _idempotent(idempotencyKey, () {
          registerEffects += 1;
          final id = policy['id']! as String;
          final revision = id.endsWith('inactive')
              ? 'revision-inactive'
              : 'revision-alpha';
          _registered.add(revision);
          return {
            'policyRevision': revision,
            'state': 'registered',
            'digest': 'sha256:policy-alpha',
          };
        });
      case 'policy.activate':
        return _idempotent(idempotencyKey, () {
          final revision = params['policyRevision']! as String;
          if (!_registered.contains(revision)) {
            throw const OrchestratorClientException(
              code: 'policy_revision_unavailable',
            );
          }
          activateEffects += 1;
          _activeRevision = revision;
          return {'policyRevision': revision, 'state': 'active'};
        });
      case 'workflow.submit':
        final revision = params['policyRevision']! as String;
        if (!_registered.contains(revision)) {
          throw const OrchestratorClientException(
            code: 'policy_revision_unavailable',
          );
        }
        if (_activeRevision != revision) {
          throw const OrchestratorClientException(
            code: 'policy_revision_inactive',
          );
        }
        return _idempotent(idempotencyKey, () {
          dispatchEffects += 1;
          return _terminalReceipt;
        });
      case 'workflow.status':
        return _terminalReceipt;
      case 'workflow.events':
        final cursor = params['afterSequence']! as int;
        eventCursors.add(cursor);
        return {
          'events': [
            _event(4, 'completed'),
            _event(2, 'running'),
            _event(3, 'validating'),
            _event(3, 'validating'),
            _event(1, 'admitted'),
          ],
          'terminal': true,
          'nextSequence': 4,
        };
      default:
        throw OrchestratorClientException(code: 'unsupported_method:$method');
    }
  }

  void _validateCanonicalPolicy(Map<String, Object?> policy) {
    if (policy['schemaVersion'] != 3) {
      throw const OrchestratorClientException(
        code: 'policy_schema_unsupported',
      );
    }
    const keys = {
      'schemaVersion',
      'id',
      'label',
      'commander',
      'modelLibrary',
      'agents',
      'workflow',
    };
    if (policy.keys.toSet().difference(keys).isNotEmpty ||
        !policy.keys.toSet().containsAll(keys)) {
      throw const OrchestratorClientException(code: 'policy_schema_invalid');
    }
    final workflow = policy['workflow'];
    if (workflow is! Map<String, Object?> ||
        workflow.keys.toSet().difference(const {'steps'}).isNotEmpty ||
        workflow['steps'] is! List<Object?>) {
      throw const OrchestratorClientException(code: 'policy_schema_invalid');
    }
  }

  Map<String, Object?> _idempotent(
    String key,
    Map<String, Object?> Function() effect,
  ) => _receipts.putIfAbsent(key, effect);

  Map<String, Object?> get _terminalReceipt => {
    'workflowId': 'workflow-alpha',
    'policyRevision': 'revision-alpha',
    'sequence': 4,
    'state': 'completed',
    'adapterDecision': 'acp',
    'terminalReceipt': const {
      'state': 'completed',
      'digest': 'sha256:terminal-alpha',
    },
    if (includePrivacyCanaries) ...const {
      'prompt': 'prompt-canary',
      'reasoning': 'reasoning-canary',
      'rawOutput': 'raw-output-canary',
      'nativeSessionId': 'native-session-canary',
      'privatePath': 'private-path-canary',
      'credential': 'credential-canary',
    },
  };

  Map<String, Object?> _event(int sequence, String state) => {
    'workflowId': 'workflow-alpha',
    'policyRevision': 'revision-alpha',
    'sequence': sequence,
    'state': state,
    'adapterDecision': sequence < 2 ? '' : 'acp',
    if (sequence == 4)
      'terminalReceipt': const {
        'state': 'completed',
        'digest': 'sha256:terminal-alpha',
      },
    if (includePrivacyCanaries) ...const {
      'prompt': 'prompt-canary',
      'rawOutput': 'raw-output-canary',
    },
  };
}
