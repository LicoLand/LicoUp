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
        allowanceThreshold: RoutingAllowanceThreshold(kind: 'token', minimum: 1),
      ),
      RoutingPolicyAgent(
        id: 'agent-a',
        roles: ['architecture', 'implementation'],
        capabilities: ['reasoning-deep', 'tool-use'],
        priority: 1,
        allowanceThreshold: RoutingAllowanceThreshold(kind: 'token', minimum: 1),
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
    bool circuitBroken = false,
    bool usageFresh = true,
    bool usageAvailable = true,
    List<AgentUsageAllowance> allowances = const [],
  }) {
    return RoutingAgentSignal(
      agentId: id,
      agentLabel: label ?? id,
      ready: ready,
      circuitBroken: circuitBroken,
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
      expect(
        decision.alternatives.map((c) => c.agentId).toList(),
        ['agent-a', 'agent-b'],
      );
      expect(decision.alternatives.first.priority, lessThan(decision.alternatives.last.priority));
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

    test('V-002-E circuit-breaker exclusion is policy-tunable', () {
      final signals = RoutingSignals(
        byAgentId: {
          'agent-a': signal(id: 'agent-a', circuitBroken: true),
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
      final exclusion = decision.excluded.singleWhere(
        (e) => e.agentId == 'agent-a',
      );
      expect(exclusion.reason, RouteReasonCode.circuitBroken);
      expect(exclusion.detail, contains('cooldownSeconds=90'));
      expect(decision.chosenAgentId, 'agent-b');
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
      expect(decision.alternatives.map((c) => c.agentId), isNot(contains('agent-a')));
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
      expect(decision.alternatives.first.satisfiedCapabilities, contains('tool-use'));
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
          adapterCapabilities: const {
            'conversationReadiness': 'ready',
          },
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
          adapterCapabilities: const {
            'conversationReadiness': 'blocked',
          },
          supportedActions: const ['runtime.message.send'],
          scanSource: 'test',
        ),
      ];
      final signals = evaluator.evaluate(
        targets: targets,
        circuitBrokenAgentIds: {'agent-a'},
      );
      expect(signals['agent-a']!.ready, isTrue);
      expect(signals['agent-a']!.circuitBroken, isTrue);
      expect(signals['agent-b']!.ready, isFalse);
    });
  });

  group('V-002-J legacy removal', () {
    test('legacy resolver and rule types have no remaining references', () {
      final roots = [
        'lib/src',
        'test',
      ];
      final banned = [
        'resolveAgentDispatchPlan',
        'AgentOrchestrationRule',
        'AgentOrchestrationStrategy',
      ];
      final hits = <String>[];
      for (final root in roots) {
        for (final entity in Directory(root).listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) {
            continue;
          }
          if (entity.path.endsWith('routing_engine_test.dart')) {
            continue;
          }
          final source = entity.readAsStringSync();
          for (final token in banned) {
            if (source.contains(token)) {
              hits.add('${entity.path}: $token');
            }
          }
        }
      }
      expect(hits, isEmpty, reason: hits.join('\n'));
    });
  });
}
