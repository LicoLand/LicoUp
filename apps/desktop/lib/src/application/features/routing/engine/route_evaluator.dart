import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

/// Aggregates readiness, allowance, and breaker signals for [RoutePlanner].
class RouteEvaluator {
  const RouteEvaluator();

  RoutingSignals evaluate({
    required Iterable<TargetCandidate> targets,
    AgentUsageReport? usageReport,
    Map<String, List<AgentUsageAllowance>> allowanceOverrides = const {},
    Set<String> circuitBrokenAgentIds = const {},
    DateTime Function()? now,
    Duration usageMaxAge = const Duration(hours: 1),
  }) {
    final usageFresh =
        usageReport == null ||
        usageReport.isFresh(now: now?.call(), maxAge: usageMaxAge);
    final usageAvailable = usageReport != null;
    final byAgentId = <String, RoutingAgentSignal>{};

    for (final target in targets) {
      final agentId = target.target.trim();
      if (agentId.isEmpty) {
        continue;
      }
      final allowances =
          allowanceOverrides[agentId] ??
          usageReport?.agent(agentId)?.allowances ??
          const <AgentUsageAllowance>[];
      byAgentId[agentId] = RoutingAgentSignal(
        agentId: agentId,
        agentLabel: target.label.trim().isEmpty ? agentId : target.label,
        ready: target.canRelayRuntime,
        circuitBroken: circuitBrokenAgentIds.contains(agentId),
        allowances: List.unmodifiable(allowances),
        usageFresh: usageFresh,
        usageAvailable: usageAvailable,
      );
    }

    return RoutingSignals(byAgentId: Map.unmodifiable(byAgentId), now: now);
  }
}
