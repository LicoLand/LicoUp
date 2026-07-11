import 'package:flutter/foundation.dart';

@immutable
class RoutingPolicyDocument {
  const RoutingPolicyDocument({
    this.schemaVersion = 2,
    this.id = '',
    this.label = '',
    this.agents = const [],
    this.routing = const RoutingPolicyRouting(),
    this.distillation = const RoutingPolicyDistillation(),
  });

  final int schemaVersion;
  final String id;
  final String label;
  final List<RoutingPolicyAgent> agents;
  final RoutingPolicyRouting routing;
  final RoutingPolicyDistillation distillation;

  bool get isEmpty => id.isEmpty && agents.isEmpty;
}

@immutable
class RoutingPolicyAgent {
  const RoutingPolicyAgent({
    required this.id,
    this.roles = const [],
    this.capabilities = const [],
    this.priority = 0,
    this.allowanceThreshold = const RoutingAllowanceThreshold(),
    this.distillation = const RoutingAgentDistillation(),
  });

  final String id;
  final List<String> roles;
  final List<String> capabilities;
  final int priority;
  final RoutingAllowanceThreshold allowanceThreshold;
  final RoutingAgentDistillation distillation;
}

@immutable
class RoutingAllowanceThreshold {
  const RoutingAllowanceThreshold({this.kind = '', this.minimum = 0});

  final String kind;
  final int minimum;
}

@immutable
class RoutingAgentDistillation {
  const RoutingAgentDistillation({
    this.distiller = 'self',
    this.maxLength = 4096,
    this.preserveFields = const [],
  });

  final String distiller;
  final int maxLength;
  final List<String> preserveFields;
}

@immutable
class RoutingPolicyRouting {
  const RoutingPolicyRouting({
    this.strategy = 'priority-fallback',
    this.matchMode = 'role-first',
    this.staleBehavior = 'conservative-skip',
    this.allowStaleUsage = false,
    this.circuitBreaker = const RoutingCircuitBreakerConfig(),
    this.switchPolicy = const RoutingSwitchPolicy(),
  });

  final String strategy;
  final String matchMode;
  final String staleBehavior;
  final bool allowStaleUsage;
  final RoutingCircuitBreakerConfig circuitBreaker;
  final RoutingSwitchPolicy switchPolicy;
}

@immutable
class RoutingCircuitBreakerConfig {
  const RoutingCircuitBreakerConfig({
    this.allowedFails = 3,
    this.cooldownSeconds = 60,
  });

  final int allowedFails;
  final int cooldownSeconds;
}

@immutable
class RoutingSwitchPolicy {
  const RoutingSwitchPolicy({
    this.minimumIntervalSeconds = 30,
    this.triggerOn = const [
      'policy-reload',
      'allowance-exhausted',
      'circuit-broken',
      'readiness-lost',
    ],
  });

  final int minimumIntervalSeconds;
  final List<String> triggerOn;
}

@immutable
class RoutingPolicyDistillation {
  const RoutingPolicyDistillation({
    this.defaultDistiller = '',
    this.alternateDistiller = '',
    this.fidelityContract = const RoutingFidelityContract(),
  });

  final String defaultDistiller;
  final String alternateDistiller;
  final RoutingFidelityContract fidelityContract;
}

@immutable
class RoutingFidelityContract {
  const RoutingFidelityContract({
    this.requiredSections = const [
      'objective',
      'currentState',
      'decisions',
      'constraints',
      'openItems',
    ],
    this.maxPackageLength = 8192,
    this.retryOnFailure = true,
    this.maxRetries = 1,
  });

  final List<String> requiredSections;
  final int maxPackageLength;
  final bool retryOnFailure;
  final int maxRetries;
}

@immutable
class RoutingPolicyValidationError {
  const RoutingPolicyValidationError({
    required this.path,
    required this.message,
    this.line = 0,
    this.column = 0,
  });

  final String path;
  final String message;
  final int line;
  final int column;

  @override
  String toString() => '$path: $message (line $line, col $column)';
}
