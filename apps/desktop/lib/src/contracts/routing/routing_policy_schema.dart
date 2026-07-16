import 'dart:convert';

import 'package:flutter_client/src/contracts/routing/routing_policy_models.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_results.dart';

export 'package:flutter_client/src/contracts/routing/routing_dispatch_failure.dart';
export 'package:flutter_client/src/contracts/routing/routing_policy_models.dart';
export 'package:flutter_client/src/contracts/routing/routing_policy_results.dart';

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
    distillation: distillation,
  );
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
    'circuitBreaker',
    'switchPolicy',
  }, path: path);
  final strategy = _optionalString(
    json,
    'strategy',
    fallback: 'priority-fallback',
  );
  final matchMode = _optionalString(json, 'matchMode', fallback: 'role-first');
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
      : const ['policy-reload', 'circuit-broken', 'readiness-lost'];
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
