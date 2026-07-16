import 'package:flutter_client/src/application/features/routing/engine/route_evaluator.dart';
import 'package:flutter_client/src/application/features/routing/engine/route_planner.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/routing_dispatch_plan.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

RoutingDispatchPlan planRoutingDispatch({
  required Iterable<TargetCandidate> targets,
  required RoutingPolicyDocument policy,
  RoutingTaskMetadata task = const RoutingTaskMetadata(),
  Map<String, RoutingCircuitBreakerState> circuitBreakerStates = const {},
  RoutePlanner planner = const DefaultRoutePlanner(),
  RouteEvaluator evaluator = const RouteEvaluator(),
  DateTime Function()? now,
}) {
  final signals = evaluator.evaluate(
    targets: targets,
    circuitBreakerStates: circuitBreakerStates,
    now: now,
  );
  final decision = planner.plan(task: task, policy: policy, signals: signals);
  final policyAgents = {for (final agent in policy.agents) agent.id: agent};
  final routes = <RoutingDispatchRoute>[
    for (var index = 0; index < decision.orderedRoutes.length; index += 1)
      RoutingDispatchRoute(
        agentId: decision.orderedRoutes[index].agentId,
        agentLabel: decision.orderedRoutes[index].agentLabel,
        role:
            policyAgents[decision.orderedRoutes[index].agentId]
                ?.roles
                .firstOrNull ??
            (index == 0 ? 'primary' : 'fallback'),
        modelName:
            policyAgents[decision.orderedRoutes[index].agentId]?.modelName ??
            '',
        reasoningEffort:
            policyAgents[decision.orderedRoutes[index].agentId]
                ?.reasoningEffort ??
            '',
        priority: decision.orderedRoutes[index].priority,
        coordinator:
            policyAgents[decision.orderedRoutes[index].agentId]?.coordinator ??
            index == 0,
        reason: decision.orderedRoutes[index].reason,
      ),
  ];
  final skipped = <RoutingDispatchSkip>[
    for (final exclusion in decision.excluded)
      RoutingDispatchSkip(
        agentId: exclusion.agentId,
        agentLabel: exclusion.agentLabel,
        reason: exclusion.reason,
        circuitBroken: exclusion.reason == RouteReasonCode.circuitBroken,
      ),
  ];
  return RoutingDispatchPlan(
    strategy: policy.routing.strategy,
    routes: List.unmodifiable(routes),
    skipped: List.unmodifiable(skipped),
    primaryAgentId: decision.chosenAgentId,
  );
}
