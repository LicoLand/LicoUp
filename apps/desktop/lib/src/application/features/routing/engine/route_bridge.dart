import 'package:flutter_client/src/application/features/routing/engine/route_evaluator.dart';
import 'package:flutter_client/src/application/features/routing/engine/route_planner.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

/// Builds a [RoutingPolicyDocument] from the orchestration model library order.
///
/// Used while the controller still persists commander/model-library settings;
/// the declarative policy file store is the long-term authority.
RoutingPolicyDocument routingPolicyFromModelLibrary({
  required String policyId,
  required String policyLabel,
  required List<AgentModelLibraryEntry> modelLibrary,
  bool allowStaleUsage = false,
}) {
  final agents = <RoutingPolicyAgent>[];
  final seen = <String>{};
  for (var index = 0; index < modelLibrary.length; index += 1) {
    final entry = modelLibrary[index];
    final agentId = entry.agentId.trim();
    if (agentId.isEmpty || !seen.add(agentId)) {
      continue;
    }
    agents.add(
      RoutingPolicyAgent(
        id: agentId,
        roles: const [],
        capabilities: const [],
        priority: index + 1,
      ),
    );
  }
  return RoutingPolicyDocument(
    schemaVersion: routingPolicySchemaVersion,
    id: policyId.trim().isEmpty ? 'orchestration' : policyId.trim(),
    label: policyLabel,
    agents: List.unmodifiable(agents),
    routing: RoutingPolicyRouting(allowStaleUsage: allowStaleUsage),
  );
}

/// Plans a route through the explainable engine (REQ-MAR-002).
RouteDecisionRecord planRouteDecision({
  required Iterable<TargetCandidate> targets,
  required RoutingPolicyDocument policy,
  RoutingTaskMetadata task = const RoutingTaskMetadata(),
  AgentUsageReport? usageReport,
  Map<String, List<AgentUsageAllowance>> allowanceOverrides = const {},
  Set<String> circuitBrokenAgentIds = const {},
  RoutePlanner planner = const DefaultRoutePlanner(),
  RouteEvaluator evaluator = const RouteEvaluator(),
  DateTime Function()? now,
}) {
  final signals = evaluator.evaluate(
    targets: targets,
    usageReport: usageReport,
    allowanceOverrides: allowanceOverrides,
    circuitBrokenAgentIds: circuitBrokenAgentIds,
    now: now,
  );
  return planner.plan(task: task, policy: policy, signals: signals);
}

/// Adapts a [RouteDecisionRecord] into the legacy dispatch plan shape used by
/// the orchestration send loop (model hints come from [modelLibrary]).
AgentDispatchPlan agentDispatchPlanFromDecision({
  required RouteDecisionRecord decision,
  List<AgentModelLibraryEntry> modelLibrary = const [],
}) {
  final byAgentId = <String, AgentModelLibraryEntry>{
    for (final entry in modelLibrary)
      if (entry.agentId.trim().isNotEmpty) entry.agentId.trim(): entry,
  };
  final routes = <AgentDispatchRoute>[
    for (var index = 0; index < decision.alternatives.length; index += 1)
      AgentDispatchRoute(
        agentId: decision.alternatives[index].agentId,
        agentLabel: decision.alternatives[index].agentLabel,
        role: index == 0 ? 'primary' : 'fallback',
        modelHint: byAgentId[decision.alternatives[index].agentId]?.modelName ?? '',
        modelName: byAgentId[decision.alternatives[index].agentId]?.modelName ?? '',
        reasoningEffort:
            byAgentId[decision.alternatives[index].agentId]?.reasoningEffort ??
            '',
        priority: decision.alternatives[index].priority,
        coordinator: index == 0,
        reason: decision.alternatives[index].reason,
      ),
  ];
  final skipped = <AgentDispatchSkip>[
    for (final exclusion in decision.excluded)
      AgentDispatchSkip(
        agentId: exclusion.agentId,
        agentLabel: exclusion.agentLabel,
        reason: exclusion.reason,
        circuitBroken:
            exclusion.reason == RouteReasonCode.circuitBroken ||
            exclusion.reason == RouteReasonCode.allowanceExhausted,
      ),
  ];
  return AgentDispatchPlan(
    strategy: 'priority-fallback',
    routes: List.unmodifiable(routes),
    skipped: List.unmodifiable(skipped),
    primaryAgentId: decision.chosenAgentId,
  );
}
