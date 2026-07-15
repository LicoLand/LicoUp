import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/agent_usage_models.dart';

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
    this.staleUsageOverride = false,
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
  final bool staleUsageOverride;
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
    required this.allowanceHeadroom,
    required this.reason,
    this.policyOrder = 0,
  });

  final String agentId;
  final String agentLabel;
  final int priority;
  final List<String> matchedRoles;
  final List<String> satisfiedCapabilities;
  final int allowanceHeadroom;
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
    this.allowances = const [],
    this.usageFresh = true,
    this.usageAvailable = true,
  });

  final String agentId;
  final String agentLabel;
  final bool ready;
  final RoutingCircuitBreakerState circuitBreaker;
  final List<AgentUsageAllowance> allowances;
  final bool usageFresh;
  final bool usageAvailable;

  bool get allowanceExhausted {
    return allowances.any((allowance) {
      final status = allowance.status.trim().toLowerCase();
      return status == 'blocked' ||
          status == 'depleted' ||
          status == 'exhausted';
    });
  }

  /// Remaining headroom heuristic from the first numeric allowance value.
  int get allowanceHeadroom {
    for (final allowance in allowances) {
      final parsed = int.tryParse(allowance.value.trim());
      if (parsed != null) {
        return parsed;
      }
    }
    return 0;
  }

  int allowanceHeadroomFor(String kind) {
    final allowance = allowanceFor(kind);
    if (allowance == null) {
      return 0;
    }
    return num.tryParse(allowance.value.trim().replaceAll(',', ''))?.floor() ??
        0;
  }

  AgentUsageAllowance? allowanceFor(String kind) {
    final normalizedKind = kind.trim().toLowerCase();
    for (final allowance in allowances) {
      if (allowance.kind.trim().toLowerCase() == normalizedKind) {
        return allowance;
      }
    }
    return null;
  }
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
  static const allowanceExhausted = 'allowance_exhausted';
  static const allowanceDataStale = 'allowance_data_stale';
  static const allowanceUnavailable = 'allowance_unavailable';
  static const roleMismatch = 'role_mismatch';
  static const capabilityUnsatisfied = 'capability_unsatisfied';
  static const selected = 'selected';
  static const alternative = 'alternative';
}
