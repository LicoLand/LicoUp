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
    final now = (signals.now ?? DateTime.now).call().toUtc();
    final timestamp = now.toIso8601String();
    final excluded = <RouteExclusion>[];
    final eligible = <_ScoredCandidate>[];
    final requirements = inferRoutingTaskRequirements(task);
    final requiredRoles = requirements.roles;
    final requiredCapabilities = requirements.capabilities;
    final explicitRoles = _normalizedValues(task.requiredRoles);
    final explicitCapabilities = _normalizedValues(task.requiredCapabilities);

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

      if (signal.circuitBreaker.isOpen(
        allowedFails: policy.routing.circuitBreaker.allowedFails,
        cooldown: Duration(
          seconds: policy.routing.circuitBreaker.cooldownSeconds,
        ),
        now: now,
      )) {
        excluded.add(
          RouteExclusion(
            agentId: agent.id,
            agentLabel: label,
            reason: RouteReasonCode.circuitBroken,
            detail:
                'failures=${signal.circuitBreaker.failureCount};'
                'allowedFails=${policy.routing.circuitBreaker.allowedFails};'
                'cooldownSeconds=${policy.routing.circuitBreaker.cooldownSeconds}',
          ),
        );
        continue;
      }

      final agentRoles = [
        for (final role in agent.roles) role.trim().toLowerCase(),
      ];
      final matchedRoles = [
        for (final role in requiredRoles)
          if (agentRoles.contains(role)) role,
      ];
      final roleWildcard = agentRoles.isEmpty && explicitRoles.isEmpty;
      if (requiredRoles.isNotEmpty && matchedRoles.isEmpty && !roleWildcard) {
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
      final capabilityWildcard =
          agentCapabilities.isEmpty && explicitCapabilities.isEmpty;
      if (missingCapabilities.isNotEmpty && !capabilityWildcard) {
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
          matchedRoles: matchedRoles.isEmpty
              ? (roleWildcard ? requiredRoles : agent.roles)
              : matchedRoles,
          satisfiedCapabilities: satisfiedCapabilities.isEmpty
              ? (capabilityWildcard ? requiredCapabilities : agent.capabilities)
              : satisfiedCapabilities,
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
        requiredRoles: requirements.roles,
        requiredCapabilities: requirements.capabilities,
        requirementReasons: requirements.reasons,
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
          reason: i == 0
              ? RouteReasonCode.selected
              : RouteReasonCode.alternative,
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
      requiredRoles: requirements.roles,
      requiredCapabilities: requirements.capabilities,
      requirementReasons: requirements.reasons,
    );
  }
}

class RoutingTaskRequirements {
  const RoutingTaskRequirements({
    required this.roles,
    required this.capabilities,
    required this.reasons,
  });

  final List<String> roles;
  final List<String> capabilities;
  final List<String> reasons;
}

/// Deterministically derives explainable requirements without a model call.
RoutingTaskRequirements inferRoutingTaskRequirements(RoutingTaskMetadata task) {
  final roles = <String>{};
  final capabilities = <String>{};
  final reasons = <String>[];

  for (final role in task.requiredRoles) {
    final normalized = role.trim().toLowerCase();
    if (normalized.isNotEmpty) {
      roles.add(normalized);
    }
  }
  for (final capability in task.requiredCapabilities) {
    final normalized = capability.trim().toLowerCase();
    if (normalized.isNotEmpty) {
      capabilities.add(normalized);
    }
  }
  if (roles.isNotEmpty || capabilities.isNotEmpty) {
    reasons.add('explicit_requirements');
  }

  final contentClass = task.contentClass.trim().toLowerCase();
  final prompt = task.prompt.trim().toLowerCase();
  for (final rule in _routingRequirementRules) {
    final contentMatched = rule.contentClasses.contains(contentClass);
    final promptMatched = rule.promptTerms.any(prompt.contains);
    if (!contentMatched && !promptMatched) {
      continue;
    }
    roles.add(rule.role);
    capabilities.addAll(rule.capabilities);
    reasons.add(
      contentMatched
          ? 'content_class:${rule.explanation}'
          : 'prompt_keyword:${rule.explanation}',
    );
  }

  return RoutingTaskRequirements(
    roles: List.unmodifiable(roles),
    capabilities: List.unmodifiable(capabilities),
    reasons: List.unmodifiable(reasons),
  );
}

const _routingRequirementRules = <_RoutingRequirementRule>[
  _RoutingRequirementRule(
    explanation: 'architecture',
    role: 'architecture',
    capabilities: ['reasoning-deep'],
    contentClasses: {'architecture', 'system-design'},
    promptTerms: {'architecture', 'system design', '架构', '系统设计'},
  ),
  _RoutingRequirementRule(
    explanation: 'implementation',
    role: 'implementation',
    capabilities: ['tool-use'],
    contentClasses: {'code', 'implementation'},
    promptTerms: {
      'implement',
      'refactor',
      'fix the',
      'write code',
      '实现',
      '重构',
      '修复',
      '编码',
    },
  ),
  _RoutingRequirementRule(
    explanation: 'review',
    role: 'review',
    capabilities: ['reasoning-deep'],
    contentClasses: {'review', 'code-review', 'security-review'},
    promptTerms: {'review', 'audit', '代码审查', '评审', '审计'},
  ),
  _RoutingRequirementRule(
    explanation: 'research',
    role: 'research',
    capabilities: [],
    contentClasses: {'research', 'investigation'},
    promptTerms: {'research', 'investigate', '调研', '研究'},
  ),
  _RoutingRequirementRule(
    explanation: 'distillation',
    role: 'distillation',
    capabilities: [],
    contentClasses: {'distillation', 'context-compression'},
    promptTerms: {'distill context', 'compress context', '压缩上下文'},
  ),
];

class _RoutingRequirementRule {
  const _RoutingRequirementRule({
    required this.explanation,
    required this.role,
    required this.capabilities,
    required this.contentClasses,
    required this.promptTerms,
  });

  final String explanation;
  final String role;
  final List<String> capabilities;
  final Set<String> contentClasses;
  final Set<String> promptTerms;
}

Set<String> _normalizedValues(Iterable<String> values) {
  return {
    for (final value in values)
      if (value.trim().isNotEmpty) value.trim().toLowerCase(),
  };
}

class _ScoredCandidate {
  const _ScoredCandidate({
    required this.agent,
    required this.label,
    required this.policyOrder,
    required this.matchedRoles,
    required this.satisfiedCapabilities,
  });

  final RoutingPolicyAgent agent;
  final String label;
  final int policyOrder;
  final List<String> matchedRoles;
  final List<String> satisfiedCapabilities;
}
