import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Supported routing policy schema version.
const int routingPolicySchemaVersion = 2;

/// Policy values with executable semantics in the current routing engine.
/// Accepting other values would silently misrepresent planner behavior.
const Set<String> routingPolicySupportedStrategies = {
  'priority-fallback',
  'serial-all',
  'parallel-all',
  'coordinator-workers',
};
const Set<String> routingPolicySupportedMatchModes = {'role-first'};
const Set<String> routingPolicySupportedStaleBehaviors = {'conservative-skip'};
const Set<String> routingPolicySupportedSwitchTriggers = {
  'policy-reload',
  'allowance-exhausted',
  'circuit-broken',
  'readiness-lost',
};

/// Fail-closed disposition used by `priority-fallback` dispatch.
///
/// A retry on another agent is safe only when the adapter explicitly states
/// both that the failure is transient and that the first request's outcome is
/// known. Error-code spelling alone is never enough to authorize fallback.
enum RoutingDispatchFailureDisposition {
  none,
  transientKnown,
  terminal,
  unknownOutcome,
}

@immutable
class RoutingDispatchFailureFacts {
  const RoutingDispatchFailureFacts({
    required this.ok,
    required this.errorCode,
    required this.transient,
    required this.outcomeKnown,
  });

  factory RoutingDispatchFailureFacts.fromEnvelope({
    required bool ok,
    required String errorCode,
    required Map<String, dynamic> envelope,
  }) {
    final nested = envelope['error'];
    final error = nested is Map
        ? Map<String, dynamic>.from(nested)
        : const <String, dynamic>{};
    return RoutingDispatchFailureFacts(
      ok: ok,
      errorCode: errorCode.trim().toLowerCase(),
      transient: envelope['transient'] == true || error['transient'] == true,
      outcomeKnown:
          envelope['outcomeKnown'] == true || error['outcomeKnown'] == true,
    );
  }

  final bool ok;
  final String errorCode;
  final bool transient;
  final bool outcomeKnown;

  RoutingDispatchFailureDisposition get disposition {
    if (ok) {
      return RoutingDispatchFailureDisposition.none;
    }
    if (!outcomeKnown) {
      return RoutingDispatchFailureDisposition.unknownOutcome;
    }
    if (transient) {
      return RoutingDispatchFailureDisposition.transientKnown;
    }
    return RoutingDispatchFailureDisposition.terminal;
  }
}

/// Default empty policy returned when no policy file exists yet.
const RoutingPolicyDocument emptyRoutingPolicyDocument =
    RoutingPolicyDocument();

/// Field names that must never appear in operator-owned policy documents.
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

  /// Policy identity used in route decision audit records.
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
    this.allowanceThreshold = const RoutingAllowanceThreshold(),
    this.distillation = const RoutingAgentDistillation(),
  });

  final String id;
  final String modelName;
  final String reasoningEffort;
  final bool coordinator;
  final List<String> roles;
  final List<String> capabilities;
  final int priority;
  final RoutingAllowanceThreshold allowanceThreshold;
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
      'allowanceThreshold': allowanceThreshold.toJson(),
      'distillation': distillation.toJson(),
    };
  }
}

@immutable
class RoutingAllowanceThreshold {
  const RoutingAllowanceThreshold({this.kind = '', this.minimum = 0});

  final String kind;
  final int minimum;

  Map<String, dynamic> toJson() {
    return {'kind': kind, 'minimum': minimum};
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

  Map<String, dynamic> toJson() {
    return {
      'strategy': strategy,
      'matchMode': matchMode,
      'staleBehavior': staleBehavior,
      'allowStaleUsage': allowStaleUsage,
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
      'allowance-exhausted',
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
  String toString() {
    if (line > 0) {
      return '$path: $message (line $line, col $column)';
    }
    return '$path: $message';
  }
}

/// Result of parsing a routing policy document.
sealed class RoutingPolicyParseResult {
  const RoutingPolicyParseResult();
}

class RoutingPolicyParseSuccess extends RoutingPolicyParseResult {
  const RoutingPolicyParseSuccess(this.document);

  final RoutingPolicyDocument document;
}

class RoutingPolicyParseFailure extends RoutingPolicyParseResult {
  const RoutingPolicyParseFailure(this.error);

  final RoutingPolicyValidationError error;
}

/// Events emitted by [RoutingPolicyStore.watch].
sealed class RoutingPolicyStoreEvent {
  const RoutingPolicyStoreEvent();
}

class RoutingPolicyStoreLoaded extends RoutingPolicyStoreEvent {
  const RoutingPolicyStoreLoaded(this.document);

  final RoutingPolicyDocument document;
}

class RoutingPolicyStoreReloaded extends RoutingPolicyStoreEvent {
  const RoutingPolicyStoreReloaded(this.document);

  final RoutingPolicyDocument document;
}

class RoutingPolicyStoreValidationFailed extends RoutingPolicyStoreEvent {
  const RoutingPolicyStoreValidationFailed(this.error);

  final RoutingPolicyValidationError error;
}

/// Active policy snapshot manager. Implementations live in backend services.
abstract class RoutingPolicyStore {
  /// Load the policy from persistent storage. Returns the default empty policy
  /// if no file exists yet.
  Future<RoutingPolicyDocument> load();

  /// Atomically persist and activate a validated policy snapshot.
  Future<void> save(RoutingPolicyDocument policy);

  /// Remove the persisted policy and activate the empty snapshot.
  Future<void> clear();

  /// Start watching the policy directory for changes. On valid change, swaps
  /// the active snapshot and notifies listeners. On invalid change, retains
  /// last good snapshot and reports the validation error.
  Stream<RoutingPolicyStoreEvent> watch();

  /// The current active policy snapshot. Never null after [load] completes.
  RoutingPolicyDocument get active;

  /// The most recent validation error, or null if the active snapshot is valid.
  RoutingPolicyValidationError? get lastError;

  /// Stop watching and release resources.
  Future<void> dispose();
}

/// Parse and validate a routing policy JSON string.
RoutingPolicyParseResult parseRoutingPolicyDocument(
  String source, {
  String sourcePath = '',
}) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (error) {
    final position = _offsetToLineColumn(source, error.offset ?? 0);
    return RoutingPolicyParseFailure(
      RoutingPolicyValidationError(
        path: sourcePath.isEmpty ? '/' : sourcePath,
        message: 'Invalid JSON: ${error.message}',
        line: position.$1,
        column: position.$2,
      ),
    );
  }

  if (decoded is! Map) {
    return const RoutingPolicyParseFailure(
      RoutingPolicyValidationError(
        path: '/',
        message: 'Policy document must be a JSON object.',
        line: 1,
        column: 1,
      ),
    );
  }

  final root = Map<String, dynamic>.from(decoded);
  return parseRoutingPolicyMap(root, source: source, sourcePath: sourcePath);
}

/// Parse and validate an already-decoded policy map.
RoutingPolicyParseResult parseRoutingPolicyMap(
  Map<String, dynamic> json, {
  String source = '',
  String sourcePath = '',
}) {
  try {
    _rejectCredentialFields(json, path: '/');
    final document = _parseDocument(json, source: source);
    return RoutingPolicyParseSuccess(document);
  } on _PolicyValidationException catch (error) {
    final position = _locatePath(source, error.path);
    return RoutingPolicyParseFailure(
      RoutingPolicyValidationError(
        path: error.path,
        message: error.message,
        line: position.$1,
        column: position.$2,
      ),
    );
  }
}

RoutingPolicyDocument _parseDocument(
  Map<String, dynamic> json, {
  required String source,
}) {
  _rejectUnknownKeys(json, const {
    'schemaVersion',
    'id',
    'label',
    'agents',
    'routing',
    'distillation',
  }, path: '/');
  final schemaVersion = _requireInt(
    json,
    'schemaVersion',
    path: '/schemaVersion',
  );
  if (schemaVersion != routingPolicySchemaVersion) {
    throw _PolicyValidationException(
      path: '/schemaVersion',
      message:
          'Unsupported schemaVersion $schemaVersion; expected $routingPolicySchemaVersion.',
    );
  }

  final id = _requireNonEmptyString(json, 'id', path: '/id');
  final label = _optionalString(json, 'label');
  final agentsRaw = _requireList(json, 'agents', path: '/agents');
  if (agentsRaw.isEmpty) {
    throw const _PolicyValidationException(
      path: '/agents',
      message: 'At least one agent entry is required.',
    );
  }

  final seenIds = <String>{};
  final agents = <RoutingPolicyAgent>[];
  for (var i = 0; i < agentsRaw.length; i++) {
    final item = agentsRaw[i];
    final path = '/agents/$i';
    if (item is! Map) {
      throw _PolicyValidationException(
        path: path,
        message: 'Agent entry must be a JSON object.',
      );
    }
    final agent = _parseAgent(Map<String, dynamic>.from(item), path: path);
    if (!seenIds.add(agent.id)) {
      throw _PolicyValidationException(
        path: '$path/id',
        message: 'Duplicate agent id "${agent.id}".',
      );
    }
    agents.add(agent);
  }

  final routingRaw = json['routing'];
  final routing = routingRaw == null
      ? const RoutingPolicyRouting()
      : _parseRouting(
          _requireMapAt(routingRaw, path: '/routing'),
          path: '/routing',
        );

  final distillationRaw = json['distillation'];
  final distillation = distillationRaw == null
      ? const RoutingPolicyDistillation()
      : _parseDistillation(
          _requireMapAt(distillationRaw, path: '/distillation'),
          path: '/distillation',
        );

  return RoutingPolicyDocument(
    schemaVersion: schemaVersion,
    id: id,
    label: label,
    agents: List.unmodifiable(agents),
    routing: routing,
    distillation: distillation,
  );
}

RoutingPolicyAgent _parseAgent(
  Map<String, dynamic> json, {
  required String path,
}) {
  _rejectCredentialFields(json, path: path);
  _rejectUnknownKeys(json, const {
    'id',
    'modelName',
    'reasoningEffort',
    'coordinator',
    'roles',
    'capabilities',
    'priority',
    'allowanceThreshold',
    'distillation',
  }, path: path);
  final id = _requireNonEmptyString(json, 'id', path: '$path/id');
  final modelName = _optionalString(json, 'modelName');
  final reasoningEffort = _optionalString(json, 'reasoningEffort');
  final coordinator = _optionalBool(
    json,
    'coordinator',
    fallback: false,
    path: '$path/coordinator',
  );
  final roles = _stringList(json, 'roles', path: '$path/roles');
  final capabilities = _stringList(
    json,
    'capabilities',
    path: '$path/capabilities',
  );
  final priority = _optionalInt(
    json,
    'priority',
    fallback: 0,
    path: '$path/priority',
  );
  if (priority < 0) {
    throw _PolicyValidationException(
      path: '$path/priority',
      message: 'priority must be >= 0.',
    );
  }

  final thresholdRaw = json['allowanceThreshold'];
  final threshold = thresholdRaw == null
      ? const RoutingAllowanceThreshold()
      : _parseAllowanceThreshold(
          _requireMapAt(thresholdRaw, path: '$path/allowanceThreshold'),
          path: '$path/allowanceThreshold',
        );

  final distillationRaw = json['distillation'];
  final distillation = distillationRaw == null
      ? const RoutingAgentDistillation()
      : _parseAgentDistillation(
          _requireMapAt(distillationRaw, path: '$path/distillation'),
          path: '$path/distillation',
        );

  return RoutingPolicyAgent(
    id: id,
    modelName: modelName,
    reasoningEffort: reasoningEffort,
    coordinator: coordinator,
    roles: List.unmodifiable(roles),
    capabilities: List.unmodifiable(capabilities),
    priority: priority,
    allowanceThreshold: threshold,
    distillation: distillation,
  );
}

RoutingAllowanceThreshold _parseAllowanceThreshold(
  Map<String, dynamic> json, {
  required String path,
}) {
  _rejectUnknownKeys(json, const {'kind', 'minimum'}, path: path);
  final kind = _optionalString(json, 'kind');
  final minimum = _optionalInt(
    json,
    'minimum',
    fallback: 0,
    path: '$path/minimum',
  );
  if (minimum < 0) {
    throw _PolicyValidationException(
      path: '$path/minimum',
      message: 'minimum must be >= 0.',
    );
  }
  if (minimum > 0 && kind.isEmpty) {
    throw _PolicyValidationException(
      path: '$path/kind',
      message: 'kind is required when minimum is greater than zero.',
    );
  }
  return RoutingAllowanceThreshold(kind: kind, minimum: minimum);
}

RoutingAgentDistillation _parseAgentDistillation(
  Map<String, dynamic> json, {
  required String path,
}) {
  _rejectUnknownKeys(json, const {
    'distiller',
    'maxLength',
    'preserveFields',
  }, path: path);
  final distiller = _optionalString(json, 'distiller', fallback: 'self');
  final maxLength = _optionalInt(
    json,
    'maxLength',
    fallback: 4096,
    path: '$path/maxLength',
  );
  if (maxLength <= 0) {
    throw _PolicyValidationException(
      path: '$path/maxLength',
      message: 'maxLength must be > 0.',
    );
  }
  final preserveFields = _stringList(
    json,
    'preserveFields',
    path: '$path/preserveFields',
  );
  return RoutingAgentDistillation(
    distiller: distiller,
    maxLength: maxLength,
    preserveFields: List.unmodifiable(preserveFields),
  );
}

RoutingPolicyRouting _parseRouting(
  Map<String, dynamic> json, {
  required String path,
}) {
  _rejectCredentialFields(json, path: path);
  _rejectUnknownKeys(json, const {
    'strategy',
    'matchMode',
    'staleBehavior',
    'allowStaleUsage',
    'circuitBreaker',
    'switchPolicy',
  }, path: path);
  final strategy = _optionalString(
    json,
    'strategy',
    fallback: 'priority-fallback',
  );
  final matchMode = _optionalString(json, 'matchMode', fallback: 'role-first');
  final staleBehavior = _optionalString(
    json,
    'staleBehavior',
    fallback: 'conservative-skip',
  );
  final allowStaleUsage = _optionalBool(
    json,
    'allowStaleUsage',
    fallback: false,
    path: '$path/allowStaleUsage',
  );
  _requireSupportedValue(
    strategy,
    routingPolicySupportedStrategies,
    path: '$path/strategy',
  );
  _requireSupportedValue(
    matchMode,
    routingPolicySupportedMatchModes,
    path: '$path/matchMode',
  );
  _requireSupportedValue(
    staleBehavior,
    routingPolicySupportedStaleBehaviors,
    path: '$path/staleBehavior',
  );

  final breakerRaw = json['circuitBreaker'];
  final circuitBreaker = breakerRaw == null
      ? const RoutingCircuitBreakerConfig()
      : _parseCircuitBreaker(
          _requireMapAt(breakerRaw, path: '$path/circuitBreaker'),
          path: '$path/circuitBreaker',
        );

  final switchRaw = json['switchPolicy'];
  final switchPolicy = switchRaw == null
      ? const RoutingSwitchPolicy()
      : _parseSwitchPolicy(
          _requireMapAt(switchRaw, path: '$path/switchPolicy'),
          path: '$path/switchPolicy',
        );

  return RoutingPolicyRouting(
    strategy: strategy,
    matchMode: matchMode,
    staleBehavior: staleBehavior,
    allowStaleUsage: allowStaleUsage,
    circuitBreaker: circuitBreaker,
    switchPolicy: switchPolicy,
  );
}

RoutingCircuitBreakerConfig _parseCircuitBreaker(
  Map<String, dynamic> json, {
  required String path,
}) {
  _rejectUnknownKeys(json, const {
    'allowedFails',
    'cooldownSeconds',
  }, path: path);
  final allowedFails = _optionalInt(
    json,
    'allowedFails',
    fallback: 3,
    path: '$path/allowedFails',
  );
  final cooldownSeconds = _optionalInt(
    json,
    'cooldownSeconds',
    fallback: 60,
    path: '$path/cooldownSeconds',
  );
  if (allowedFails < 0) {
    throw _PolicyValidationException(
      path: '$path/allowedFails',
      message: 'allowedFails must be >= 0.',
    );
  }
  if (cooldownSeconds < 0) {
    throw _PolicyValidationException(
      path: '$path/cooldownSeconds',
      message: 'cooldownSeconds must be >= 0.',
    );
  }
  return RoutingCircuitBreakerConfig(
    allowedFails: allowedFails,
    cooldownSeconds: cooldownSeconds,
  );
}

RoutingSwitchPolicy _parseSwitchPolicy(
  Map<String, dynamic> json, {
  required String path,
}) {
  _rejectUnknownKeys(json, const {
    'minimumIntervalSeconds',
    'triggerOn',
  }, path: path);
  final minimumIntervalSeconds = _optionalInt(
    json,
    'minimumIntervalSeconds',
    fallback: 30,
    path: '$path/minimumIntervalSeconds',
  );
  if (minimumIntervalSeconds < 0) {
    throw _PolicyValidationException(
      path: '$path/minimumIntervalSeconds',
      message: 'minimumIntervalSeconds must be >= 0.',
    );
  }
  final triggerOn = json.containsKey('triggerOn')
      ? _stringList(json, 'triggerOn', path: '$path/triggerOn')
      : const [
          'policy-reload',
          'allowance-exhausted',
          'circuit-broken',
          'readiness-lost',
        ];
  for (var i = 0; i < triggerOn.length; i += 1) {
    _requireSupportedValue(
      triggerOn[i],
      routingPolicySupportedSwitchTriggers,
      path: '$path/triggerOn/$i',
    );
  }
  return RoutingSwitchPolicy(
    minimumIntervalSeconds: minimumIntervalSeconds,
    triggerOn: List.unmodifiable(triggerOn),
  );
}

RoutingPolicyDistillation _parseDistillation(
  Map<String, dynamic> json, {
  required String path,
}) {
  _rejectCredentialFields(json, path: path);
  _rejectUnknownKeys(json, const {
    'defaultDistiller',
    'alternateDistiller',
    'fidelityContract',
  }, path: path);
  final defaultDistiller = _optionalString(json, 'defaultDistiller');
  final alternateDistiller = _optionalString(json, 'alternateDistiller');
  final fidelityRaw = json['fidelityContract'];
  final fidelity = fidelityRaw == null
      ? const RoutingFidelityContract()
      : _parseFidelityContract(
          _requireMapAt(fidelityRaw, path: '$path/fidelityContract'),
          path: '$path/fidelityContract',
        );
  return RoutingPolicyDistillation(
    defaultDistiller: defaultDistiller,
    alternateDistiller: alternateDistiller,
    fidelityContract: fidelity,
  );
}

RoutingFidelityContract _parseFidelityContract(
  Map<String, dynamic> json, {
  required String path,
}) {
  _rejectUnknownKeys(json, const {
    'requiredSections',
    'maxPackageLength',
    'retryOnFailure',
    'maxRetries',
  }, path: path);
  final requiredSections = json.containsKey('requiredSections')
      ? _stringList(json, 'requiredSections', path: '$path/requiredSections')
      : const [
          'objective',
          'currentState',
          'decisions',
          'constraints',
          'openItems',
        ];
  final maxPackageLength = _optionalInt(
    json,
    'maxPackageLength',
    fallback: 8192,
    path: '$path/maxPackageLength',
  );
  if (maxPackageLength <= 0) {
    throw _PolicyValidationException(
      path: '$path/maxPackageLength',
      message: 'maxPackageLength must be > 0.',
    );
  }
  final retryOnFailure = _optionalBool(
    json,
    'retryOnFailure',
    fallback: true,
    path: '$path/retryOnFailure',
  );
  final maxRetries = _optionalInt(
    json,
    'maxRetries',
    fallback: 1,
    path: '$path/maxRetries',
  );
  if (maxRetries < 0) {
    throw _PolicyValidationException(
      path: '$path/maxRetries',
      message: 'maxRetries must be >= 0.',
    );
  }
  return RoutingFidelityContract(
    requiredSections: List.unmodifiable(requiredSections),
    maxPackageLength: maxPackageLength,
    retryOnFailure: retryOnFailure,
    maxRetries: maxRetries,
  );
}

void _rejectCredentialFields(
  Map<String, dynamic> json, {
  required String path,
}) {
  for (final entry in json.entries) {
    final key = entry.key;
    final normalized = key.toLowerCase().replaceAll(' ', '');
    if (routingPolicyForbiddenCredentialKeys.contains(normalized)) {
      throw _PolicyValidationException(
        path: path == '/' ? '/$key' : '$path/$key',
        message: 'Credential-like field "$key" is forbidden in routing policy.',
      );
    }
    final value = entry.value;
    if (value is Map) {
      _rejectCredentialFields(
        Map<String, dynamic>.from(value),
        path: path == '/' ? '/$key' : '$path/$key',
      );
    } else if (value is List) {
      for (var i = 0; i < value.length; i++) {
        final item = value[i];
        if (item is Map) {
          _rejectCredentialFields(
            Map<String, dynamic>.from(item),
            path: path == '/' ? '/$key/$i' : '$path/$key/$i',
          );
        }
      }
    }
  }
}

void _rejectUnknownKeys(
  Map<String, dynamic> json,
  Set<String> allowed, {
  required String path,
}) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw _PolicyValidationException(
        path: path == '/' ? '/$key' : '$path/$key',
        message: 'Unknown policy field "$key".',
      );
    }
  }
}

void _requireSupportedValue(
  String value,
  Set<String> supported, {
  required String path,
}) {
  if (!supported.contains(value)) {
    throw _PolicyValidationException(
      path: path,
      message: 'Unsupported policy value "$value".',
    );
  }
}

int _requireInt(Map<String, dynamic> json, String key, {required String path}) {
  final value = json[key];
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  throw _PolicyValidationException(
    path: path,
    message: 'Expected integer for "$key".',
  );
}

int _optionalInt(
  Map<String, dynamic> json,
  String key, {
  required int fallback,
  required String path,
}) {
  if (!json.containsKey(key) || json[key] == null) {
    return fallback;
  }
  return _requireInt(json, key, path: path);
}

String _requireNonEmptyString(
  Map<String, dynamic> json,
  String key, {
  required String path,
}) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw _PolicyValidationException(
      path: path,
      message: 'Expected non-empty string for "$key".',
    );
  }
  return value.trim();
}

String _optionalString(
  Map<String, dynamic> json,
  String key, {
  String fallback = '',
}) {
  final value = json[key];
  if (value is! String) {
    return fallback;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? fallback : trimmed;
}

bool _optionalBool(
  Map<String, dynamic> json,
  String key, {
  required bool fallback,
  required String path,
}) {
  if (!json.containsKey(key) || json[key] == null) {
    return fallback;
  }
  final value = json[key];
  if (value is bool) {
    return value;
  }
  throw _PolicyValidationException(
    path: path,
    message: 'Expected boolean for "$key".',
  );
}

List<Object?> _requireList(
  Map<String, dynamic> json,
  String key, {
  required String path,
}) {
  final value = json[key];
  if (value is! List) {
    throw _PolicyValidationException(
      path: path,
      message: 'Expected array for "$key".',
    );
  }
  return value;
}

List<String> _stringList(
  Map<String, dynamic> json,
  String key, {
  required String path,
}) {
  if (!json.containsKey(key) || json[key] == null) {
    return const [];
  }
  final value = json[key];
  if (value is! List) {
    throw _PolicyValidationException(
      path: path,
      message: 'Expected string array for "$key".',
    );
  }
  final result = <String>[];
  for (var i = 0; i < value.length; i++) {
    final item = value[i];
    if (item is! String || item.trim().isEmpty) {
      throw _PolicyValidationException(
        path: '$path/$i',
        message: 'Expected non-empty string.',
      );
    }
    result.add(item.trim());
  }
  return result;
}

Map<String, dynamic> _requireMapAt(Object? value, {required String path}) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  throw _PolicyValidationException(
    path: path,
    message: 'Expected JSON object.',
  );
}

(int, int) _offsetToLineColumn(String source, int offset) {
  if (source.isEmpty || offset <= 0) {
    return (1, 1);
  }
  var line = 1;
  var column = 1;
  final limit = offset.clamp(0, source.length);
  for (var i = 0; i < limit; i++) {
    if (source.codeUnitAt(i) == 0x0A) {
      line += 1;
      column = 1;
    } else {
      column += 1;
    }
  }
  return (line, column);
}

(int, int) _locatePath(String source, String path) {
  if (source.isEmpty || path.isEmpty || path == '/') {
    return (1, 1);
  }
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) {
    return (1, 1);
  }
  // Prefer the leaf key for actionable editor positions.
  final leaf = segments.last;
  if (RegExp(r'^\d+$').hasMatch(leaf)) {
    if (segments.length >= 2) {
      return _findKeyPosition(source, segments[segments.length - 2]);
    }
    return (1, 1);
  }
  return _findKeyPosition(source, leaf);
}

(int, int) _findKeyPosition(String source, String key) {
  final pattern = RegExp('"${RegExp.escape(key)}"\\s*:');
  final match = pattern.firstMatch(source);
  if (match == null) {
    return (1, 1);
  }
  return _offsetToLineColumn(source, match.start);
}

class _PolicyValidationException implements Exception {
  const _PolicyValidationException({required this.path, required this.message});

  final String path;
  final String message;
}
