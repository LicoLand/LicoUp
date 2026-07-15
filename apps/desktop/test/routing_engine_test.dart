import 'dart:io';

import 'package:flutter_client/src/application/features/routing/engine/route_evaluator.dart';
import 'package:flutter_client/src/application/features/routing/engine/route_planner.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const planner = DefaultRoutePlanner();
  const evaluator = RouteEvaluator();

  final policy = RoutingPolicyDocument(
    schemaVersion: 2,
    id: 'decision-table',
    label: 'Decision Table',
    agents: const [
      RoutingPolicyAgent(
        id: 'agent-b',
        roles: ['implementation'],
        capabilities: ['tool-use'],
        priority: 2,
        allowanceThreshold: RoutingAllowanceThreshold(
          kind: 'token',
          minimum: 1,
        ),
      ),
      RoutingPolicyAgent(
        id: 'agent-a',
        roles: ['architecture', 'implementation'],
        capabilities: ['reasoning-deep', 'tool-use'],
        priority: 1,
        allowanceThreshold: RoutingAllowanceThreshold(
          kind: 'token',
          minimum: 1,
        ),
      ),
      RoutingPolicyAgent(
        id: 'agent-c',
        roles: ['review'],
        capabilities: ['tool-use'],
        priority: 1,
      ),
    ],
    routing: const RoutingPolicyRouting(
      allowStaleUsage: false,
      circuitBreaker: RoutingCircuitBreakerConfig(
        allowedFails: 3,
        cooldownSeconds: 90,
      ),
    ),
  );

  RoutingAgentSignal signal({
    required String id,
    String? label,
    bool ready = true,
    int circuitFailureCount = 0,
    DateTime? circuitLastFailureAt,
    bool usageFresh = true,
    bool usageAvailable = true,
    List<AgentUsageAllowance> allowances = const [
      AgentUsageAllowance(
        kind: 'token',
        label: 'tokens',
        provider: 'x',
        period: 'week',
        status: 'available',
        value: '100',
        unit: 'tokens',
        source: 'test',
        message: '',
      ),
    ],
  }) {
    return RoutingAgentSignal(
      agentId: id,
      agentLabel: label ?? id,
      ready: ready,
      circuitBreaker: RoutingCircuitBreakerState(
        failureCount: circuitFailureCount,
        lastFailureAt: circuitLastFailureAt,
      ),
      usageFresh: usageFresh,
      usageAvailable: usageAvailable,
      allowances: allowances,
    );
  }

  RoutingSignals allReady() {
    return RoutingSignals(
      byAgentId: {
        'agent-a': signal(id: 'agent-a', label: 'Agent A'),
        'agent-b': signal(id: 'agent-b', label: 'Agent B'),
        'agent-c': signal(id: 'agent-c', label: 'Agent C'),
      },
      now: () => DateTime.utc(2026, 7, 11, 5),
    );
  }

  group('V-002 routing engine decision table', () {
    test('V-002-A role matching selects intersecting roles only', () {
      final decision = planner.plan(
        task: const RoutingTaskMetadata(requiredRoles: ['architecture']),
        policy: policy,
        signals: allReady(),
      );
      expect(decision.chosenAgentId, 'agent-a');
      expect(
        decision.excluded.map((e) => e.agentId),
        containsAll(['agent-b', 'agent-c']),
      );
      expect(
        decision.excluded
            .where((e) => e.reason == RouteReasonCode.roleMismatch)
            .map((e) => e.agentId),
        containsAll(['agent-b', 'agent-c']),
      );
    });

    test('V-002-B capability matching excludes missing capabilities', () {
      final decision = planner.plan(
        task: const RoutingTaskMetadata(
          requiredCapabilities: ['reasoning-deep'],
        ),
        policy: policy,
        signals: allReady(),
      );
      expect(decision.chosenAgentId, 'agent-a');
      expect(
        decision.excluded
            .where((e) => e.reason == RouteReasonCode.capabilityUnsatisfied)
            .map((e) => e.agentId),
        containsAll(['agent-b', 'agent-c']),
      );
    });

    test('V-002-C priority ordering not insertion order', () {
      final decision = planner.plan(
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        policy: policy,
        signals: allReady(),
      );
      // agent-a priority 1 before agent-b priority 2, despite agent-b listed first.
      expect(decision.chosenAgentId, 'agent-a');
      expect(decision.alternatives.map((c) => c.agentId).toList(), [
        'agent-a',
        'agent-b',
      ]);
      expect(
        decision.alternatives.first.priority,
        lessThan(decision.alternatives.last.priority),
      );
    });

    test('V-002-D allowance exhaustion exclusion', () {
      final signals = RoutingSignals(
        byAgentId: {
          'agent-a': signal(
            id: 'agent-a',
            allowances: [
              const AgentUsageAllowance(
                kind: 'token',
                label: 'tokens',
                provider: 'x',
                period: 'week',
                status: 'exhausted',
                value: '0',
                unit: 'tokens',
                source: 'test',
                message: '',
              ),
            ],
          ),
          'agent-b': signal(id: 'agent-b'),
          'agent-c': signal(id: 'agent-c'),
        },
        now: () => DateTime.utc(2026, 7, 11, 5),
      );
      final decision = planner.plan(
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        policy: policy,
        signals: signals,
      );
      expect(decision.chosenAgentId, 'agent-b');
      expect(
        decision.excluded.singleWhere((e) => e.agentId == 'agent-a').reason,
        RouteReasonCode.allowanceExhausted,
      );
    });

    test('V-002-E circuit-breaker uses failure count and cooldown TTL', () {
      final clock = DateTime.utc(2026, 7, 11, 5);
      final signals = RoutingSignals(
        byAgentId: {
          'agent-a': signal(
            id: 'agent-a',
            circuitFailureCount: 4,
            circuitLastFailureAt: clock.subtract(const Duration(seconds: 30)),
          ),
          'agent-b': signal(id: 'agent-b'),
          'agent-c': signal(id: 'agent-c'),
        },
        now: () => clock,
      );
      final decision = planner.plan(
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        policy: policy,
        signals: signals,
      );
      final exclusion = decision.excluded.singleWhere(
        (e) => e.agentId == 'agent-a',
      );
      expect(exclusion.reason, RouteReasonCode.circuitBroken);
      expect(exclusion.detail, contains('cooldownSeconds=90'));
      expect(exclusion.detail, contains('failures=4'));
      expect(decision.chosenAgentId, 'agent-b');

      final cooledDown = planner.plan(
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        policy: policy,
        signals: RoutingSignals(
          byAgentId: signals.byAgentId,
          now: () => clock.add(const Duration(seconds: 61)),
        ),
      );
      expect(cooledDown.chosenAgentId, 'agent-a');
    });

    test('allowance threshold compares matching kind against minimum', () {
      final signals = RoutingSignals(
        byAgentId: {
          'agent-a': signal(
            id: 'agent-a',
            allowances: const [
              AgentUsageAllowance(
                kind: 'token',
                label: 'tokens',
                provider: 'x',
                period: 'week',
                status: 'available',
                value: '0',
                unit: 'tokens',
                source: 'test',
                message: '',
              ),
            ],
          ),
          'agent-b': signal(
            id: 'agent-b',
            allowances: const [
              AgentUsageAllowance(
                kind: 'token',
                label: 'tokens',
                provider: 'x',
                period: 'week',
                status: 'available',
                value: '1',
                unit: 'tokens',
                source: 'test',
                message: '',
              ),
            ],
          ),
          'agent-c': signal(id: 'agent-c'),
        },
        now: () => DateTime.utc(2026, 7, 11, 5),
      );
      final decision = planner.plan(
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        policy: policy,
        signals: signals,
      );
      expect(decision.chosenAgentId, 'agent-b');
      final excluded = decision.excluded.singleWhere(
        (entry) => entry.agentId == 'agent-a',
      );
      expect(excluded.reason, RouteReasonCode.allowanceExhausted);
      expect(excluded.detail, contains('minimum=1'));
    });

    test('prompt and content class derive explainable requirements', () {
      final requirements = inferRoutingTaskRequirements(
        const RoutingTaskMetadata(
          prompt: 'Please implement the approved system design.',
          contentClass: 'architecture',
        ),
      );
      expect(requirements.roles, ['architecture', 'implementation']);
      expect(requirements.capabilities, ['reasoning-deep', 'tool-use']);
      expect(requirements.reasons, contains('content_class:architecture'));
      expect(requirements.reasons, contains('prompt_keyword:implementation'));
    });

    test('V-002-F readiness hard-exclusion', () {
      final signals = RoutingSignals(
        byAgentId: {
          'agent-a': signal(id: 'agent-a', ready: false),
          'agent-b': signal(id: 'agent-b'),
          'agent-c': signal(id: 'agent-c'),
        },
        now: () => DateTime.utc(2026, 7, 11, 5),
      );
      final decision = planner.plan(
        task: const RoutingTaskMetadata(),
        policy: policy,
        signals: signals,
      );
      expect(
        decision.excluded.singleWhere((e) => e.agentId == 'agent-a').reason,
        RouteReasonCode.notReady,
      );
      expect(
        decision.alternatives.map((c) => c.agentId),
        isNot(contains('agent-a')),
      );
      expect(decision.chosenAgentId, isNot('agent-a'));
    });

    test('V-002-G deterministic tiebreak by policy order', () {
      final first = planner.plan(
        task: const RoutingTaskMetadata(requiredRoles: ['review']),
        policy: policy,
        signals: allReady(),
      );
      final second = planner.plan(
        task: const RoutingTaskMetadata(requiredRoles: ['review']),
        policy: policy,
        signals: allReady(),
      );
      expect(first.chosenAgentId, 'agent-c');
      expect(second.chosenAgentId, first.chosenAgentId);
      expect(
        second.alternatives.map((c) => c.agentId).toList(),
        first.alternatives.map((c) => c.agentId).toList(),
      );
    });

    test('V-002-H stale usage conservative skip', () {
      final signals = RoutingSignals(
        byAgentId: {
          'agent-a': signal(id: 'agent-a', usageFresh: false),
          'agent-b': signal(id: 'agent-b', usageFresh: false),
          'agent-c': signal(id: 'agent-c', usageFresh: false),
        },
        now: () => DateTime.utc(2026, 7, 11, 5),
      );
      final decision = planner.plan(
        task: const RoutingTaskMetadata(requiredRoles: ['implementation']),
        policy: policy,
        signals: signals,
      );
      // agent-a and agent-b have thresholds → stale skip; agent-c has no threshold.
      expect(
        decision.excluded
            .where((e) => e.reason == RouteReasonCode.allowanceDataStale)
            .map((e) => e.agentId),
        containsAll(['agent-a', 'agent-b']),
      );
      expect(decision.blocked, isTrue);
    });

    test('V-002-I decision record completeness', () {
      final decision = planner.plan(
        task: const RoutingTaskMetadata(
          requiredRoles: ['implementation'],
          requiredCapabilities: ['tool-use'],
        ),
        policy: policy,
        signals: allReady(),
      );
      expect(decision.chosenAgentId, isNotEmpty);
      expect(decision.policyId, 'decision-table');
      expect(decision.policyVersion, 2);
      expect(decision.alternatives, isNotEmpty);
      expect(decision.alternatives.first.reason, RouteReasonCode.selected);
      expect(decision.alternatives.first.matchedRoles, isNotEmpty);
      expect(
        decision.alternatives.first.satisfiedCapabilities,
        contains('tool-use'),
      );
      expect(decision.alternatives.first.allowanceHeadroom, isA<int>());
      expect(decision.timestamp, isNotEmpty);
    });
  });

  group('RouteEvaluator', () {
    test('maps TargetCandidate.canRelayRuntime into ready signals', () {
      final targets = [
        TargetCandidate(
          target: 'agent-a',
          label: 'Agent A',
          kind: 'agent',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'ready',
          adapterCapabilities: const {'conversationReadiness': 'ready'},
          supportedActions: const ['runtime.message.send'],
          scanSource: 'test',
        ),
        TargetCandidate(
          target: 'agent-b',
          label: 'Agent B',
          kind: 'agent',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'blocked',
          adapterCapabilities: const {'conversationReadiness': 'blocked'},
          supportedActions: const ['runtime.message.send'],
          scanSource: 'test',
        ),
      ];
      final signals = evaluator.evaluate(
        targets: targets,
        circuitBreakerStates: {
          'agent-a': RoutingCircuitBreakerState(
            failureCount: 4,
            lastFailureAt: DateTime.utc(2026, 7, 11, 5),
          ),
        },
      );
      expect(signals['agent-a']!.ready, isTrue);
      expect(signals['agent-a']!.circuitBreaker.failureCount, 4);
      expect(signals['agent-b']!.ready, isFalse);
    });
  });

  group('V-002-J production wiring', () {
    test('controller lifecycle uses the canonical routing authority', () {
      final controller = File(
        'lib/src/application/controller/client_controller.dart',
      ).readAsStringSync();
      final lifecycle = File(
        'lib/src/application/controller/controller_lifecycle_actions.dart',
      ).readAsStringSync();
      final orchestration = File(
        'lib/src/application/features/agents/controller/agent_orchestration_actions.dart',
      ).readAsStringSync();
      expect(controller, contains('RoutingModuleRegistration'));
      expect(lifecycle, contains('await registration.activate()'));
      expect(orchestration, contains('_routingModule?.activePolicy'));
      expect(orchestration, contains('planRoutingDispatch('));
    });
  });
}
