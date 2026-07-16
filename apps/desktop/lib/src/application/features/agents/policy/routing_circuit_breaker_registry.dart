import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';

typedef RoutingCircuitBreakerStates = Map<String, RoutingCircuitBreakerState>;

final class RoutingCircuitBreakerFailureUpdate {
  const RoutingCircuitBreakerFailureUpdate({
    required this.states,
    required this.isOpen,
  });

  final RoutingCircuitBreakerStates states;
  final bool isOpen;
}

/// Pure immutable reducer for per-agent circuit-breaker state.
final class RoutingCircuitBreakerRegistry {
  const RoutingCircuitBreakerRegistry._();

  static Set<String> openAgentIds(
    RoutingCircuitBreakerStates states, {
    required int allowedFails,
    required Duration cooldown,
    required DateTime now,
  }) => Set.unmodifiable({
    for (final entry in states.entries)
      if (entry.value.isOpen(
        allowedFails: allowedFails,
        cooldown: cooldown,
        now: now,
      ))
        entry.key,
  });

  static RoutingCircuitBreakerFailureUpdate recordFailure(
    RoutingCircuitBreakerStates states,
    String agentId, {
    required int allowedFails,
    required Duration cooldown,
    required DateTime now,
  }) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      return RoutingCircuitBreakerFailureUpdate(states: states, isOpen: false);
    }
    final previous = states[normalized] ?? const RoutingCircuitBreakerState();
    final failedAt = previous.lastFailureAt;
    final expired =
        previous.failureCount > allowedFails &&
        failedAt != null &&
        !now.toUtc().isBefore(failedAt.toUtc().add(cooldown));
    final next = (expired ? const RoutingCircuitBreakerState() : previous)
        .recordFailure(now);
    return RoutingCircuitBreakerFailureUpdate(
      states: Map.unmodifiable({...states, normalized: next}),
      isOpen: next.isOpen(
        allowedFails: allowedFails,
        cooldown: cooldown,
        now: now,
      ),
    );
  }

  static RoutingCircuitBreakerStates recordSuccess(
    RoutingCircuitBreakerStates states,
    String agentId,
  ) {
    final normalized = agentId.trim();
    if (!states.containsKey(normalized)) {
      return states;
    }
    return Map.unmodifiable({
      for (final entry in states.entries)
        if (entry.key != normalized) entry.key: entry.value,
    });
  }

  static RoutingCircuitBreakerStates retainAgents(
    RoutingCircuitBreakerStates states,
    Set<String> agentIds,
  ) => Map.unmodifiable({
    for (final entry in states.entries)
      if (agentIds.contains(entry.key)) entry.key: entry.value,
  });
}
