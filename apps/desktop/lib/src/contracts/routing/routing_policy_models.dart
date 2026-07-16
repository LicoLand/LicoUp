import 'package:flutter/foundation.dart';

const int routingPolicySchemaVersion = 2;

const Set<String> routingPolicySupportedStrategies = {
  'priority-fallback',
  'serial-all',
  'parallel-all',
  'coordinator-workers',
};
const Set<String> routingPolicySupportedMatchModes = {'role-first'};
const Set<String> routingPolicySupportedSwitchTriggers = {
  'policy-reload',
  'circuit-broken',
  'readiness-lost',
};

const Set<String> routingPolicyForbiddenCredentialKeys = {
  'apikey',
  'api_key',
  'api-key',
  'password',
  'secret',
  'secretkey',
  'secret_key',
  'secret-key',
  'accesstoken',
  'access_token',
  'access-token',
  'refreshtoken',
  'refresh_token',
  'refresh-token',
  'privatekey',
  'private_key',
  'private-key',
  'credentials',
  'authtoken',
  'auth_token',
  'auth-token',
  'bearer',
  'bearertoken',
  'token',
};

const RoutingPolicyDocument emptyRoutingPolicyDocument =
    RoutingPolicyDocument();

@immutable
class RoutingPolicyDocument {
  const RoutingPolicyDocument({
    this.schemaVersion = routingPolicySchemaVersion,
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
  String get identity => id.isEmpty ? '(empty)' : '$id@$schemaVersion';

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'id': id,
      'label': label,
      'agents': [for (final agent in agents) agent.toJson()],
      'routing': routing.toJson(),
      'distillation': distillation.toJson(),
    };
  }
}

@immutable
class RoutingPolicyAgent {
  const RoutingPolicyAgent({
    required this.id,
    this.modelName = '',
    this.reasoningEffort = '',
    this.coordinator = false,
    this.roles = const [],
    this.capabilities = const [],
    this.priority = 0,
    this.distillation = const RoutingAgentDistillation(),
  });

  final String id;
  final String modelName;
  final String reasoningEffort;
  final bool coordinator;
  final List<String> roles;
  final List<String> capabilities;
  final int priority;
  final RoutingAgentDistillation distillation;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'modelName': modelName,
      'reasoningEffort': reasoningEffort,
      'coordinator': coordinator,
      'roles': roles,
      'capabilities': capabilities,
      'priority': priority,
      'distillation': distillation.toJson(),
    };
  }
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

  Map<String, dynamic> toJson() {
    return {
      'distiller': distiller,
      'maxLength': maxLength,
      'preserveFields': preserveFields,
    };
  }
}

@immutable
class RoutingPolicyRouting {
  const RoutingPolicyRouting({
    this.strategy = 'priority-fallback',
    this.matchMode = 'role-first',
    this.circuitBreaker = const RoutingCircuitBreakerConfig(),
    this.switchPolicy = const RoutingSwitchPolicy(),
  });

  final String strategy;
  final String matchMode;
  final RoutingCircuitBreakerConfig circuitBreaker;
  final RoutingSwitchPolicy switchPolicy;

  Map<String, dynamic> toJson() {
    return {
      'strategy': strategy,
      'matchMode': matchMode,
      'circuitBreaker': circuitBreaker.toJson(),
      'switchPolicy': switchPolicy.toJson(),
    };
  }
}

@immutable
class RoutingCircuitBreakerConfig {
  const RoutingCircuitBreakerConfig({
    this.allowedFails = 3,
    this.cooldownSeconds = 60,
  });

  final int allowedFails;
  final int cooldownSeconds;

  Map<String, dynamic> toJson() {
    return {'allowedFails': allowedFails, 'cooldownSeconds': cooldownSeconds};
  }
}

@immutable
class RoutingSwitchPolicy {
  const RoutingSwitchPolicy({
    this.minimumIntervalSeconds = 30,
    this.triggerOn = const [
      'policy-reload',
      'circuit-broken',
      'readiness-lost',
    ],
  });

  final int minimumIntervalSeconds;
  final List<String> triggerOn;

  Map<String, dynamic> toJson() {
    return {
      'minimumIntervalSeconds': minimumIntervalSeconds,
      'triggerOn': triggerOn,
    };
  }
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

  Map<String, dynamic> toJson() {
    return {
      'defaultDistiller': defaultDistiller,
      'alternateDistiller': alternateDistiller,
      'fidelityContract': fidelityContract.toJson(),
    };
  }
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

  Map<String, dynamic> toJson() {
    return {
      'requiredSections': requiredSections,
      'maxPackageLength': maxPackageLength,
      'retryOnFailure': retryOnFailure,
      'maxRetries': maxRetries,
    };
  }
}
