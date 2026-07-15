import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/application/features/routing/broker/distillation_broker.dart';
import 'package:flutter_client/src/application/features/routing/controller/task_route_coordinator.dart';
import 'package:flutter_client/src/application/features/routing/engine/route_planner.dart';
import 'package:flutter_client/src/backend/features/routing/services/route_history_store.dart';
import 'package:flutter_client/src/backend/features/routing/services/route_session_binding_store.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/route_history.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late RouteHistoryStore history;
  late ProtectedRouteSessionBindingStore sessionBindings;
  late DateTime clock;
  late TaskRouteCoordinator coordinator;

  final turns = const [
    DistillationConversationTurn(
      role: 'user',
      text: 'Goal: finish mid-task switching.',
    ),
    DistillationConversationTurn(
      role: 'assistant',
      text: 'Current state: coordinator under test.',
    ),
    DistillationConversationTurn(
      role: 'assistant',
      text: 'Decision: evaluate only at message boundaries.',
    ),
    DistillationConversationTurn(
      role: 'user',
      text: 'Constraint: must not interrupt streaming.',
    ),
    DistillationConversationTurn(
      role: 'assistant',
      text: 'Open: remaining packaging nodes.',
    ),
  ];

  RoutingPolicyDocument policyFor({
    required String primary,
    required String fallback,
    int minimumIntervalSeconds = 0,
  }) {
    return RoutingPolicyDocument(
      schemaVersion: 2,
      id: 'switch-$primary',
      label: 'Switch Policy',
      agents: [
        RoutingPolicyAgent(
          id: primary,
          roles: const ['implementation'],
          priority: 1,
        ),
        RoutingPolicyAgent(
          id: fallback,
          roles: const ['implementation'],
          priority: 2,
        ),
        const RoutingPolicyAgent(
          id: 'fake-distiller',
          roles: ['distillation'],
          priority: 3,
        ),
      ],
      routing: RoutingPolicyRouting(
        switchPolicy: RoutingSwitchPolicy(
          minimumIntervalSeconds: minimumIntervalSeconds,
        ),
      ),
      distillation: const RoutingPolicyDistillation(
        defaultDistiller: 'fake-distiller',
        alternateDistiller: 'agent-a',
      ),
    );
  }

  RoutingSignals signals({
    bool aReady = true,
    bool bReady = true,
    bool distillerReady = true,
  }) {
    return RoutingSignals(
      byAgentId: {
        'agent-a': RoutingAgentSignal(
          agentId: 'agent-a',
          agentLabel: 'Agent A',
          ready: aReady,
        ),
        'agent-b': RoutingAgentSignal(
          agentId: 'agent-b',
          agentLabel: 'Agent B',
          ready: bReady,
        ),
        'fake-distiller': RoutingAgentSignal(
          agentId: 'fake-distiller',
          agentLabel: 'Distiller',
          ready: distillerReady,
        ),
      },
      now: () => clock,
    );
  }

  String goodPackage() => jsonEncode({
    'objective': 'Finish mid-task switching.',
    'currentState': 'Coordinator under test.',
    'decisions': ['Evaluate only at message boundaries.'],
    'constraints': ['Must not interrupt streaming.'],
    'openItems': ['Remaining packaging nodes.'],
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('route-switch-');
    history = RouteHistoryStore(rootDirectory: tempDir);
    sessionBindings = ProtectedRouteSessionBindingStore(rootDirectory: tempDir);
    clock = DateTime.utc(2026, 7, 11, 6, 0, 0);
    coordinator = TaskRouteCoordinator(
      historyStore: history,
      sessionBindingStore: sessionBindings,
      planner: const DefaultRoutePlanner(),
      broker: DefaultDistillationBroker(),
      now: () => clock,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('V-004 mid-task switch', () {
    test(
      'V-004-A re-routing at message boundary with distilled handoff',
      () async {
        coordinator.bindSession(
          taskId: 'task-1',
          agentId: 'agent-a',
          sessionId: 'session-a',
        );
        final opened = <String>[];
        final result = await coordinator.evaluateAtMessageBoundary(
          taskId: 'task-1',
          policy: policyFor(primary: 'agent-b', fallback: 'agent-a'),
          signals: signals(),
          task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
          turns: turns,
          send: (_) async => DistillationLaneResponse(
            ok: true,
            text: goodPackage(),
            promptTokens: 10,
            completionTokens: 10,
          ),
          openTargetSession:
              ({
                required agentId,
                required package,
                required sourceSessionId,
                required resumeSessionId,
              }) async {
                opened.add(agentId);
                expect(package.hasObjective, isTrue);
                expect(sourceSessionId, 'session-a');
                return 'session-b';
              },
        );

        expect(result, isA<TaskRouteSwitchCompleted>());
        final completed = result as TaskRouteSwitchCompleted;
        expect(completed.session.currentAgentId, 'agent-b');
        expect(completed.session.currentSessionId, 'session-b');
        expect(opened, ['agent-b']);
        expect(history.entriesFor('task-1'), hasLength(1));
      },
    );

    test('V-004-B no mid-stream interruption', () async {
      coordinator.bindSession(
        taskId: 'task-1',
        agentId: 'agent-a',
        sessionId: 'session-a',
      );
      coordinator.setStreaming('task-1', true);
      var distillCalls = 0;
      final result = await coordinator.evaluateAtMessageBoundary(
        taskId: 'task-1',
        policy: policyFor(primary: 'agent-b', fallback: 'agent-a'),
        signals: signals(),
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        turns: turns,
        send: (_) async {
          distillCalls += 1;
          return DistillationLaneResponse(ok: true, text: goodPackage());
        },
        openTargetSession:
            ({
              required agentId,
              required package,
              required sourceSessionId,
              required resumeSessionId,
            }) async => 'session-b',
      );
      expect(result, isA<TaskRouteSwitchSkipped>());
      expect(
        (result as TaskRouteSwitchSkipped).reason,
        'streaming_in_progress',
      );
      expect(distillCalls, 0);
      expect(coordinator.sessionFor('task-1')!.currentAgentId, 'agent-a');
    });

    test('V-004-C route history recording', () async {
      coordinator.bindSession(
        taskId: 'task-1',
        agentId: 'agent-a',
        sessionId: 'session-a',
      );
      await coordinator.evaluateAtMessageBoundary(
        taskId: 'task-1',
        policy: policyFor(primary: 'agent-b', fallback: 'agent-a'),
        signals: signals(),
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        turns: turns,
        send: (_) async =>
            DistillationLaneResponse(ok: true, text: goodPackage()),
        openTargetSession:
            ({
              required agentId,
              required package,
              required sourceSessionId,
              required resumeSessionId,
            }) async => 'session-b',
        switchReason: 'policy-reload',
      );
      final entry = history.entriesFor('task-1').single;
      expect(entry.sourceAgentId, 'agent-a');
      expect(entry.targetAgentId, 'agent-b');
      expect(entry.sourceSessionHandle, startsWith('rh_'));
      expect(entry.targetSessionHandle, startsWith('rh_'));
      expect(entry.sourceSessionHandle, isNot(entry.targetSessionHandle));
      expect(entry.distillationDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(entry.decision.chosenAgentId, 'agent-b');
      expect(entry.switchReason, 'policy-reload');
      expect(entry.timestamp, isNotEmpty);
      expect(await history.diskLineCount('task-1'), 1);
    });

    test(
      'V-004-D / V-004-E source and target sessions remain resumable',
      () async {
        coordinator.bindSession(
          taskId: 'task-1',
          agentId: 'agent-a',
          sessionId: 'session-a',
        );
        await coordinator.evaluateAtMessageBoundary(
          taskId: 'task-1',
          policy: policyFor(primary: 'agent-b', fallback: 'agent-a'),
          signals: signals(),
          task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
          turns: turns,
          send: (_) async =>
              DistillationLaneResponse(ok: true, text: goodPackage()),
          openTargetSession:
              ({
                required agentId,
                required package,
                required sourceSessionId,
                required resumeSessionId,
              }) async => 'session-b',
        );
        expect(
          coordinator.isSessionResumable(
            taskId: 'task-1',
            sessionId: 'session-a',
          ),
          isTrue,
        );
        expect(
          coordinator.isSessionResumable(
            taskId: 'task-1',
            sessionId: 'session-b',
          ),
          isTrue,
        );
      },
    );

    test(
      'returning A to B to A resumes the original A native session',
      () async {
        coordinator.bindSession(
          taskId: 'task-return',
          agentId: 'agent-a',
          sessionId: 'session-a',
        );
        final resumeRequests = <(String, String)>[];

        await coordinator.evaluateAtMessageBoundary(
          taskId: 'task-return',
          policy: policyFor(primary: 'agent-b', fallback: 'agent-a'),
          signals: signals(),
          task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
          turns: turns,
          send: (_) async =>
              DistillationLaneResponse(ok: true, text: goodPackage()),
          openTargetSession:
              ({
                required agentId,
                required package,
                required sourceSessionId,
                required resumeSessionId,
              }) async {
                resumeRequests.add((agentId, resumeSessionId));
                return 'session-b';
              },
        );
        await coordinator.evaluateAtMessageBoundary(
          taskId: 'task-return',
          policy: policyFor(primary: 'agent-a', fallback: 'agent-b'),
          signals: signals(),
          task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
          turns: turns,
          send: (_) async =>
              DistillationLaneResponse(ok: true, text: goodPackage()),
          openTargetSession:
              ({
                required agentId,
                required package,
                required sourceSessionId,
                required resumeSessionId,
              }) async {
                resumeRequests.add((agentId, resumeSessionId));
                return resumeSessionId;
              },
        );

        expect(resumeRequests, [('agent-b', ''), ('agent-a', 'session-a')]);
        expect(
          coordinator.sessionFor('task-return')!.currentAgentId,
          'agent-a',
        );
        expect(
          coordinator.sessionFor('task-return')!.currentSessionId,
          'session-a',
        );
      },
    );

    test(
      'REQ-ROUTE-001 history excludes private sessions and handoff content',
      () async {
        const privateSource = 'private-native-source';
        const privateTarget = 'private-native-target';
        coordinator.bindSession(
          taskId: 'task-private',
          agentId: 'agent-a',
          sessionId: privateSource,
        );
        await coordinator.evaluateAtMessageBoundary(
          taskId: 'task-private',
          policy: policyFor(primary: 'agent-b', fallback: 'agent-a'),
          signals: signals(),
          task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
          turns: turns,
          send: (_) async =>
              DistillationLaneResponse(ok: true, text: goodPackage()),
          openTargetSession:
              ({
                required agentId,
                required package,
                required sourceSessionId,
                required resumeSessionId,
              }) async => privateTarget,
        );

        final historyFile = File(
          '${tempDir.path}/lico-client/routing/history/task-private.jsonl',
        );
        final persisted = await historyFile.readAsString();
        expect(persisted, isNot(contains(privateSource)));
        expect(persisted, isNot(contains(privateTarget)));
        expect(persisted, isNot(contains('Finish mid-task switching.')));
        final persistedEntry =
            jsonDecode(persisted.trim()) as Map<String, dynamic>;
        expect(
          persistedEntry.keys,
          containsAll(<String>[
            'sourceSessionHandle',
            'targetSessionHandle',
            'distillationDigest',
          ]),
        );
      },
    );

    test('REQ-ROUTE-001 exact binding survives coordinator restart', () {
      coordinator.bindSession(
        taskId: 'task-restart',
        agentId: 'agent-a',
        sessionId: 'native-restart-session',
      );
      final before = coordinator.sessionFor('task-restart')!;

      final restarted = TaskRouteCoordinator(
        historyStore: RouteHistoryStore(rootDirectory: tempDir),
        sessionBindingStore: ProtectedRouteSessionBindingStore(
          rootDirectory: tempDir,
        ),
        planner: const DefaultRoutePlanner(),
        broker: DefaultDistillationBroker(),
        now: () => clock,
      );
      final restored = restarted.sessionFor('task-restart');

      expect(restored, isNotNull);
      expect(restored!.currentAgentId, 'agent-a');
      expect(restored.currentSessionId, 'native-restart-session');
      expect(restored.currentSessionHandle, before.currentSessionHandle);
      expect(
        restarted.isSessionResumable(
          taskId: 'task-restart',
          sessionId: 'native-restart-session',
        ),
        isTrue,
      );
    });

    test('V-004-F policy swap during distillation queues safely', () async {
      coordinator.bindSession(
        taskId: 'task-1',
        agentId: 'agent-a',
        sessionId: 'session-a',
      );
      final distillStarted = Completer<void>();
      final allowFinish = Completer<void>();

      final first = coordinator.evaluateAtMessageBoundary(
        taskId: 'task-1',
        policy: policyFor(primary: 'agent-b', fallback: 'agent-a'),
        signals: signals(),
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        turns: turns,
        send: (_) async {
          distillStarted.complete();
          await allowFinish.future;
          return DistillationLaneResponse(ok: true, text: goodPackage());
        },
        openTargetSession:
            ({
              required agentId,
              required package,
              required sourceSessionId,
              required resumeSessionId,
            }) async => 'session-b',
      );

      await distillStarted.future;
      coordinator.queuePolicy(
        policyFor(primary: 'agent-a', fallback: 'agent-b'),
      );
      expect(coordinator.hasQueuedPolicy, isTrue);

      allowFinish.complete();
      final result = await first;
      expect(result, isA<TaskRouteSwitchCompleted>());
      final queued = coordinator.takeQueuedPolicy();
      expect(queued, isNotNull);
      expect(queued!.agents.first.id, 'agent-a');
      // Handoff was not corrupted — session moved to B from the in-flight eval.
      expect(coordinator.sessionFor('task-1')!.currentAgentId, 'agent-b');
    });

    test('V-004-G switch frequency bounded', () async {
      coordinator.bindSession(
        taskId: 'task-1',
        agentId: 'agent-a',
        sessionId: 'session-a',
      );
      final policy = policyFor(
        primary: 'agent-b',
        fallback: 'agent-a',
        minimumIntervalSeconds: 30,
      );
      final first = await coordinator.evaluateAtMessageBoundary(
        taskId: 'task-1',
        policy: policy,
        signals: signals(),
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        turns: turns,
        send: (_) async =>
            DistillationLaneResponse(ok: true, text: goodPackage()),
        openTargetSession:
            ({
              required agentId,
              required package,
              required sourceSessionId,
              required resumeSessionId,
            }) async => 'session-b',
      );
      expect(first, isA<TaskRouteSwitchCompleted>());

      // Flip primary back to A immediately — should be bounded.
      clock = clock.add(const Duration(seconds: 5));
      final second = await coordinator.evaluateAtMessageBoundary(
        taskId: 'task-1',
        policy: policyFor(
          primary: 'agent-a',
          fallback: 'agent-b',
          minimumIntervalSeconds: 30,
        ),
        signals: signals(),
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        turns: turns,
        send: (_) async =>
            DistillationLaneResponse(ok: true, text: goodPackage()),
        openTargetSession:
            ({
              required agentId,
              required package,
              required sourceSessionId,
              required resumeSessionId,
            }) async => 'session-a2',
      );
      expect(second, isA<TaskRouteSwitchSkipped>());
      expect(
        (second as TaskRouteSwitchSkipped).reason,
        'switch_interval_bounded',
      );
      expect(coordinator.sessionFor('task-1')!.currentAgentId, 'agent-b');
    });

    test(
      'V-004-H failed switch stays on source with surfaced reason',
      () async {
        coordinator.bindSession(
          taskId: 'task-1',
          agentId: 'agent-a',
          sessionId: 'session-a',
        );
        final result = await coordinator.evaluateAtMessageBoundary(
          taskId: 'task-1',
          policy: policyFor(primary: 'agent-b', fallback: 'agent-a'),
          signals: signals(),
          task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
          turns: turns,
          send: (_) async => const DistillationLaneResponse(
            ok: false,
            errorMessage: 'distiller failed',
          ),
          openTargetSession:
              ({
                required agentId,
                required package,
                required sourceSessionId,
                required resumeSessionId,
              }) async => 'session-b',
        );
        expect(result, isA<TaskRouteSwitchFailed>());
        expect(
          (result as TaskRouteSwitchFailed).reason,
          contains('distiller failed'),
        );
        expect(coordinator.sessionFor('task-1')!.currentAgentId, 'agent-a');
        expect(coordinator.sessionFor('task-1')!.currentSessionId, 'session-a');
        expect(history.entriesFor('task-1').single.failed, isTrue);
      },
    );

    test(
      'controller bounds distillation input before broker dispatch',
      () async {
        final capturingBroker = _CapturingDistillationBroker();
        coordinator = TaskRouteCoordinator(
          historyStore: history,
          sessionBindingStore: sessionBindings,
          planner: const DefaultRoutePlanner(),
          broker: capturingBroker,
          now: () => clock,
        );
        coordinator.bindSession(
          taskId: 'task-bounded',
          agentId: 'agent-a',
          sessionId: 'session-a',
        );
        final largeInput = <DistillationConversationTurn>[
          const DistillationConversationTurn(
            role: 'user',
            text: 'Objective: retain bounded controller objective.',
          ),
          const DistillationConversationTurn(
            role: 'assistant',
            text: 'Decision: retain bounded controller decision.',
          ),
          const DistillationConversationTurn(
            role: 'user',
            text: 'Constraint: retain bounded controller constraint.',
          ),
          for (var index = 0; index < 100; index++)
            DistillationConversationTurn(
              role: 'assistant',
              text: 'controller recent $index ${List.filled(1024, 'z').join()}',
            ),
        ];
        final result = await coordinator.evaluateAtMessageBoundary(
          taskId: 'task-bounded',
          policy: policyFor(primary: 'agent-b', fallback: 'agent-a'),
          signals: signals(),
          task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
          turns: largeInput,
          send: (_) async => const DistillationLaneResponse(ok: false),
          openTargetSession:
              ({
                required agentId,
                required package,
                required sourceSessionId,
                required resumeSessionId,
              }) async => 'unused',
        );

        expect(result, isA<TaskRouteSwitchFailed>());
        final captured = capturingBroker.request!;
        final encoded = captured.turns.map((turn) => turn.text).join('\n');
        expect(
          captured.turns.length,
          lessThanOrEqualTo(distillationInputMaxTurns),
        );
        expect(
          utf8.encode(encoded).length,
          lessThanOrEqualTo(distillationInputMaxBytes),
        );
        expect(encoded, contains('bounded controller objective'));
        expect(encoded, contains('bounded controller decision'));
        expect(encoded, contains('bounded controller constraint'));
        expect(encoded, contains('controller recent 99'));
      },
    );
  });
}

class _CapturingDistillationBroker implements DistillationBroker {
  DistillationRequest? request;

  @override
  Future<DistillationResult> distill({
    required DistillationRequest request,
    required RoutingPolicyDocument policy,
    required DispatchLaneSend send,
  }) async {
    this.request = request;
    return const DistillationFailure(reason: 'captured_bounded_input');
  }
}
