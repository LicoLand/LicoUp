import 'package:flutter/foundation.dart';

@immutable
class RouteDecisionRecord {
  const RouteDecisionRecord({
    required this.chosenAgentId,
    required this.chosenAgentLabel,
    required this.policyId,
    required this.policyVersion,
    required this.alternatives,
    required this.excluded,
    required this.timestamp,
    this.requiredRoles = const [],
    this.requiredCapabilities = const [],
    this.requirementReasons = const [],
  });

  final String chosenAgentId;
  final String chosenAgentLabel;
  final String policyId;
  final int policyVersion;
  final List<RouteCandidate> alternatives;
  final List<RouteExclusion> excluded;
  final String timestamp;
  final List<String> requiredRoles;
  final List<String> requiredCapabilities;
  final List<String> requirementReasons;

  bool get blocked => chosenAgentId.trim().isEmpty;

  /// Chosen agent plus ordered alternatives (chosen first).
  List<RouteCandidate> get orderedRoutes {
    if (blocked) {
      return const [];
    }
    final chosen = alternatives.where((c) => c.agentId == chosenAgentId);
    final rest = alternatives.where((c) => c.agentId != chosenAgentId);
    if (chosen.isEmpty) {
      return List.unmodifiable(alternatives);
    }
    return List.unmodifiable([...chosen, ...rest]);
  }
}

@immutable
class RouteCandidate {
  const RouteCandidate({
    required this.agentId,
    required this.agentLabel,
    required this.priority,
    required this.matchedRoles,
    required this.satisfiedCapabilities,
    required this.reason,
    this.policyOrder = 0,
  });

  final String agentId;
  final String agentLabel;
  final int priority;
  final List<String> matchedRoles;
  final List<String> satisfiedCapabilities;
  final String reason;
  final int policyOrder;
}

@immutable
class RouteExclusion {
  const RouteExclusion({
    required this.agentId,
    required this.agentLabel,
    required this.reason,
    this.detail = '',
  });

  final String agentId;
  final String agentLabel;
  final String reason;
  final String detail;
}

/// Task-side inputs to the pure planner.
@immutable
class RoutingTaskMetadata {
  const RoutingTaskMetadata({
    this.prompt = '',
    this.requiredRoles = const [],
    this.requiredCapabilities = const [],
    this.contentClass = '',
  });

  final String prompt;
  final List<String> requiredRoles;
  final List<String> requiredCapabilities;
  final String contentClass;
}

/// Per-agent runtime signals aggregated by [RouteEvaluator].
@immutable
class RoutingAgentSignal {
  const RoutingAgentSignal({
    required this.agentId,
    required this.agentLabel,
    required this.ready,
    this.circuitBreaker = const RoutingCircuitBreakerState(),
  });

  final String agentId;
  final String agentLabel;
  final bool ready;
  final RoutingCircuitBreakerState circuitBreaker;
}

/// Consecutive-failure state supplied to the pure planner.
///
/// The breaker opens only after more than [allowedFails] consecutive failures
/// and automatically closes once the cooldown TTL has elapsed.
@immutable
class RoutingCircuitBreakerState {
  const RoutingCircuitBreakerState({this.failureCount = 0, this.lastFailureAt});

  final int failureCount;
  final DateTime? lastFailureAt;

  bool isOpen({
    required int allowedFails,
    required Duration cooldown,
    required DateTime now,
  }) {
    final failedAt = lastFailureAt?.toUtc();
    if (failureCount <= allowedFails || failedAt == null) {
      return false;
    }
    return now.toUtc().isBefore(failedAt.add(cooldown));
  }

  RoutingCircuitBreakerState recordFailure(DateTime at) {
    return RoutingCircuitBreakerState(
      failureCount: failureCount + 1,
      lastFailureAt: at.toUtc(),
    );
  }
}

@immutable
class RoutingSignals {
  const RoutingSignals({this.byAgentId = const {}, this.now});

  final Map<String, RoutingAgentSignal> byAgentId;
  final DateTime Function()? now;

  RoutingAgentSignal? operator [](String agentId) => byAgentId[agentId];
}

/// Exclusion / selection reason codes used in decision records and tests.
abstract final class RouteReasonCode {
  static const notReady = 'not_ready';
  static const circuitBroken = 'circuit_broken';
  static const roleMismatch = 'role_mismatch';
  static const capabilityUnsatisfied = 'capability_unsatisfied';
  static const selected = 'selected';
  static const alternative = 'alternative';
}
