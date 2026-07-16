import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

/// Aggregates readiness and breaker signals for [RoutePlanner].
class RouteEvaluator {
  const RouteEvaluator();

  RoutingSignals evaluate({
    required Iterable<TargetCandidate> targets,
    Map<String, RoutingCircuitBreakerState> circuitBreakerStates = const {},
    DateTime Function()? now,
  }) {
    final byAgentId = <String, RoutingAgentSignal>{};

    for (final target in targets) {
      final agentId = target.target.trim();
      if (agentId.isEmpty) {
        continue;
      }
      byAgentId[agentId] = RoutingAgentSignal(
        agentId: agentId,
        agentLabel: target.label.trim().isEmpty ? agentId : target.label,
        ready: target.canRelayRuntime,
        circuitBreaker:
            circuitBreakerStates[agentId] ?? const RoutingCircuitBreakerState(),
      );
    }

    return RoutingSignals(byAgentId: Map.unmodifiable(byAgentId), now: now);
  }
}
