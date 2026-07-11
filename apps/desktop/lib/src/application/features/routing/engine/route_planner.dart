import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

/// Pure routing decision function (REQ-MAR-002).
///
/// Deterministic: identical inputs produce identical outputs. No I/O.
abstract class RoutePlanner {
  RouteDecisionRecord plan({
    required RoutingTaskMetadata task,
    required RoutingPolicyDocument policy,
    required RoutingSignals signals,
  });
}

class DefaultRoutePlanner implements RoutePlanner {
  const DefaultRoutePlanner();

  @override
  RouteDecisionRecord plan({
    required RoutingTaskMetadata task,
    required RoutingPolicyDocument policy,
    required RoutingSignals signals,
  }) {
    final timestamp =
        (signals.now ?? DateTime.now).call().toUtc().toIso8601String();
    final excluded = <RouteExclusion>[];
    final eligible = <_ScoredCandidate>[];
    final requiredRoles = [
      for (final role in task.requiredRoles)
        if (role.trim().isNotEmpty) role.trim().toLowerCase(),
    ];
    final requiredCapabilities = [
      for (final capability in task.requiredCapabilities)
        if (capability.trim().isNotEmpty) capability.trim().toLowerCase(),
    ];
    final allowStale = policy.routing.allowStaleUsage;
    var staleUsageOverride = false;

    for (var index = 0; index < policy.agents.length; index += 1) {
      final agent = policy.agents[index];
      final signal = signals[agent.id];
      final label = signal?.agentLabel ?? agent.id;

      if (signal == null || !signal.ready) {
        excluded.add(
          RouteExclusion(
            agentId: agent.id,
            agentLabel: label,
            reason: RouteReasonCode.notReady,
            detail: signal == null ? 'missing_signal' : 'canRelayRuntime=false',
          ),
        );
        continue;
      }

      if (signal.circuitBroken) {
        excluded.add(
          RouteExclusion(
            agentId: agent.id,
            agentLabel: label,
            reason: RouteReasonCode.circuitBroken,
            detail:
                'cooldownSeconds=${policy.routing.circuitBreaker.cooldownSeconds}',
          ),
        );
        continue;
      }

      final hasThreshold = agent.allowanceThreshold.kind.trim().isNotEmpty;
      final hasAllowances = signal.allowances.isNotEmpty;
      if (hasThreshold || hasAllowances) {
        if (hasThreshold && !signal.usageAvailable) {
          excluded.add(
            RouteExclusion(
              agentId: agent.id,
              agentLabel: label,
              reason: RouteReasonCode.allowanceUnavailable,
            ),
          );
          continue;
        }
        if (hasThreshold && !signal.usageFresh) {
          if (allowStale) {
            staleUsageOverride = true;
          } else {
            excluded.add(
              RouteExclusion(
                agentId: agent.id,
                agentLabel: label,
                reason: RouteReasonCode.allowanceDataStale,
              ),
            );
            continue;
          }
        }
        if (signal.allowanceExhausted) {
          excluded.add(
            RouteExclusion(
              agentId: agent.id,
              agentLabel: label,
              reason: RouteReasonCode.allowanceExhausted,
            ),
          );
          continue;
        }
      }

      final agentRoles = [
        for (final role in agent.roles) role.trim().toLowerCase(),
      ];
      final matchedRoles = [
        for (final role in requiredRoles)
          if (agentRoles.contains(role)) role,
      ];
      if (requiredRoles.isNotEmpty && matchedRoles.isEmpty) {
        excluded.add(
          RouteExclusion(
            agentId: agent.id,
            agentLabel: label,
            reason: RouteReasonCode.roleMismatch,
            detail: 'required=${requiredRoles.join(",")}',
          ),
        );
        continue;
      }

      final agentCapabilities = [
        for (final capability in agent.capabilities)
          capability.trim().toLowerCase(),
      ];
      final missingCapabilities = [
        for (final capability in requiredCapabilities)
          if (!agentCapabilities.contains(capability)) capability,
      ];
      if (missingCapabilities.isNotEmpty) {
        excluded.add(
          RouteExclusion(
            agentId: agent.id,
            agentLabel: label,
            reason: RouteReasonCode.capabilityUnsatisfied,
            detail: 'missing=${missingCapabilities.join(",")}',
          ),
        );
        continue;
      }
      final satisfiedCapabilities = [
        for (final capability in requiredCapabilities)
          if (agentCapabilities.contains(capability)) capability,
      ];

      eligible.add(
        _ScoredCandidate(
          agent: agent,
          label: label,
          policyOrder: index,
          matchedRoles: matchedRoles.isEmpty ? agent.roles : matchedRoles,
          satisfiedCapabilities: satisfiedCapabilities.isEmpty
              ? agent.capabilities
              : satisfiedCapabilities,
          allowanceHeadroom: signal.allowanceHeadroom,
        ),
      );
    }

    // Priority ascending (1 before 2), then stable policy document order.
    eligible.sort((a, b) {
      final byPriority = a.agent.priority.compareTo(b.agent.priority);
      if (byPriority != 0) {
        return byPriority;
      }
      return a.policyOrder.compareTo(b.policyOrder);
    });

    if (eligible.isEmpty) {
      return RouteDecisionRecord(
        chosenAgentId: '',
        chosenAgentLabel: '',
        policyId: policy.id,
        policyVersion: policy.schemaVersion,
        alternatives: const [],
        excluded: List.unmodifiable(excluded),
        timestamp: timestamp,
        staleUsageOverride: staleUsageOverride,
      );
    }

    final alternatives = <RouteCandidate>[
      for (var i = 0; i < eligible.length; i += 1)
        RouteCandidate(
          agentId: eligible[i].agent.id,
          agentLabel: eligible[i].label,
          priority: eligible[i].agent.priority,
          matchedRoles: List.unmodifiable(eligible[i].matchedRoles),
          satisfiedCapabilities: List.unmodifiable(
            eligible[i].satisfiedCapabilities,
          ),
          allowanceHeadroom: eligible[i].allowanceHeadroom,
          reason: i == 0 ? RouteReasonCode.selected : RouteReasonCode.alternative,
          policyOrder: eligible[i].policyOrder,
        ),
    ];

    final chosen = alternatives.first;
    return RouteDecisionRecord(
      chosenAgentId: chosen.agentId,
      chosenAgentLabel: chosen.agentLabel,
      policyId: policy.id,
      policyVersion: policy.schemaVersion,
      alternatives: List.unmodifiable(alternatives),
      excluded: List.unmodifiable(excluded),
      timestamp: timestamp,
      staleUsageOverride: staleUsageOverride,
    );
  }
}

class _ScoredCandidate {
  const _ScoredCandidate({
    required this.agent,
    required this.label,
    required this.policyOrder,
    required this.matchedRoles,
    required this.satisfiedCapabilities,
    required this.allowanceHeadroom,
  });

  final RoutingPolicyAgent agent;
  final String label;
  final int policyOrder;
  final List<String> matchedRoles;
  final List<String> satisfiedCapabilities;
  final int allowanceHeadroom;
}
