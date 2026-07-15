import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/target_candidate.dart';

const String agentOrchestrationTargetId = 'lico-default-orchestrator';
const String defaultAgentOrchestrationPolicyId = 'default';

bool isAgentOrchestrationTargetId(String targetId) {
  return targetId.trim() == agentOrchestrationTargetId;
}

TargetCandidate agentOrchestrationTargetCandidate({String label = 'Default'}) {
  return TargetCandidate(
    target: agentOrchestrationTargetId,
    label: label,
    kind: 'multi-agent-orchestration',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'local-strategy',
    adapterCapabilities: const {'virtual': true},
    supportedActions: const ['runtime.message.send'],
    scanSource: 'local-ui',
  );
}

@immutable
class AgentOrchestrationPolicy {
  const AgentOrchestrationPolicy({
    this.id = defaultAgentOrchestrationPolicyId,
    this.label = '',
    this.commanderAgentId = '',
    this.commanderModelName = '',
    this.commanderReasoningEffort = '',
    this.modelLibrary = const [],
  });

  final String id;
  final String label;
  final String commanderAgentId;
  final String commanderModelName;
  final String commanderReasoningEffort;
  final List<AgentModelLibraryEntry> modelLibrary;

  bool get configured =>
      commanderAgentId.trim().isNotEmpty &&
      commanderModelName.trim().isNotEmpty;

  factory AgentOrchestrationPolicy.fromJson(Map<String, dynamic> json) {
    final commander = _jsonMap(json['commander']);
    return AgentOrchestrationPolicy(
      id: _jsonString(json['id'], fallback: defaultAgentOrchestrationPolicyId),
      label: _jsonString(json['label']),
      commanderAgentId: _jsonString(
        commander['agentId'] ?? json['commanderAgentId'],
      ),
      commanderModelName: _jsonString(
        commander['modelName'] ?? json['commanderModelName'],
      ),
      commanderReasoningEffort: _jsonString(
        commander['reasoningEffort'] ?? json['commanderReasoningEffort'],
      ),
      modelLibrary: List.unmodifiable([
        for (final item in _jsonList(json['modelLibrary']))
          AgentModelLibraryEntry.fromJson(_jsonMap(item)),
      ]),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': 1,
      'id': id,
      'label': label,
      'commander': {
        'agentId': commanderAgentId,
        'modelName': commanderModelName,
        'reasoningEffort': commanderReasoningEffort,
      },
      'modelLibrary': [for (final entry in modelLibrary) entry.toJson()],
    };
  }

  AgentOrchestrationPolicy copyWith({
    String? id,
    String? label,
    String? commanderAgentId,
    String? commanderModelName,
    String? commanderReasoningEffort,
    List<AgentModelLibraryEntry>? modelLibrary,
  }) {
    return AgentOrchestrationPolicy(
      id: id ?? this.id,
      label: label ?? this.label,
      commanderAgentId: commanderAgentId ?? this.commanderAgentId,
      commanderModelName: commanderModelName ?? this.commanderModelName,
      commanderReasoningEffort:
          commanderReasoningEffort ?? this.commanderReasoningEffort,
      modelLibrary: modelLibrary ?? this.modelLibrary,
    );
  }
}

@immutable
class AgentModelLibraryEntry {
  const AgentModelLibraryEntry({
    required this.agentId,
    required this.modelName,
    this.reasoningEffort = '',
  });

  final String agentId;
  final String modelName;
  final String reasoningEffort;

  bool get configured =>
      agentId.trim().isNotEmpty && modelName.trim().isNotEmpty;

  String get key =>
      '${agentId.trim()}\u001f${modelName.trim()}\u001f${reasoningEffort.trim()}';

  factory AgentModelLibraryEntry.fromJson(Map<String, dynamic> json) {
    return AgentModelLibraryEntry(
      agentId: _jsonString(json['agentId']),
      modelName: _jsonString(json['modelName']),
      reasoningEffort: _jsonString(json['reasoningEffort']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'agentId': agentId,
      'modelName': modelName,
      'reasoningEffort': reasoningEffort,
    };
  }

  AgentModelLibraryEntry copyWith({
    String? agentId,
    String? modelName,
    String? reasoningEffort,
  }) {
    return AgentModelLibraryEntry(
      agentId: agentId ?? this.agentId,
      modelName: modelName ?? this.modelName,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    );
  }
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const {};
}

List<Object?> _jsonList(Object? value) {
  if (value is List) {
    return value;
  }
  return const [];
}

String _jsonString(Object? value, {String fallback = ''}) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? fallback : normalized;
}

AgentModelLibraryEntry? agentOrchestrationCommanderEntry(
  AgentOrchestrationPolicy policy,
) {
  if (policy.commanderAgentId.trim().isEmpty ||
      policy.commanderModelName.trim().isEmpty) {
    return null;
  }
  return AgentModelLibraryEntry(
    agentId: policy.commanderAgentId.trim(),
    modelName: policy.commanderModelName.trim(),
    reasoningEffort: policy.commanderReasoningEffort.trim(),
  );
}

List<AgentModelLibraryEntry> agentOrchestrationDispatchModelLibrary(
  AgentOrchestrationPolicy policy,
) {
  final result = <AgentModelLibraryEntry>[];
  final seen = <String>{};
  final commander = agentOrchestrationCommanderEntry(policy);
  if (commander != null && seen.add(commander.key)) {
    result.add(commander);
  }
  for (final entry in policy.modelLibrary) {
    if (entry.configured && seen.add(entry.key)) {
      result.add(entry);
    }
  }
  return List.unmodifiable(result);
}

AgentOrchestrationPolicy normalizeAgentOrchestrationPolicy(
  Iterable<TargetCandidate> targets,
  AgentOrchestrationPolicy policy,
) {
  final commanderAgentId = _normalizeCommanderAgentId(
    targets,
    policy.commanderAgentId,
  );
  final commanderModelName = _normalizeCommanderModelName(
    targets,
    commanderAgentId,
    policy.commanderModelName,
  );
  final modelLibrary = normalizeAgentModelLibrary(targets, policy.modelLibrary);
  return policy.copyWith(
    id: policy.id.trim().isEmpty
        ? defaultAgentOrchestrationPolicyId
        : policy.id.trim(),
    label: policy.label.trim(),
    commanderAgentId: commanderAgentId,
    commanderModelName: commanderModelName,
    commanderReasoningEffort: _normalizeCommanderReasoningEffort(
      targets,
      commanderAgentId,
      commanderModelName,
      policy.commanderReasoningEffort,
    ),
    modelLibrary: modelLibrary,
  );
}

List<TargetCandidate> agentOrchestrationCommanderTargets(
  Iterable<TargetCandidate> targets,
) {
  final result = targets
      .where(
        (target) =>
            target.isConversationAgent &&
            target.canRelayRuntime &&
            !isAgentOrchestrationTargetId(target.target),
      )
      .toList(growable: false);
  result.sort((a, b) {
    final labelCompare = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    if (labelCompare != 0) {
      return labelCompare;
    }
    return a.target.toLowerCase().compareTo(b.target.toLowerCase());
  });
  return List.unmodifiable(result);
}

List<String> agentOrchestrationCommanderModels(TargetCandidate target) {
  final catalogModels = _modelNamesFromModelCatalog(target.modelCatalog);
  if (catalogModels.isNotEmpty) {
    return catalogModels;
  }
  final models = _dedupe([
    ..._modelNamesFromMap(target.adapterCapabilities),
    ..._modelNamesFromMap(target.optionOverrides),
    ..._modelNamesFromMap(target.environment),
  ]);
  return models;
}

String agentOrchestrationModelDisplayName(
  TargetCandidate target,
  String modelName,
) {
  final normalized = modelName.trim();
  if (normalized.isEmpty) {
    return '';
  }
  for (final model in _modelCatalogEntries(target.modelCatalog)) {
    if (!_modelCatalogEntryMatchesName(model, normalized)) {
      continue;
    }
    final displayName = _modelDisplayNameFromValue(model);
    if (displayName.isNotEmpty) {
      return displayName;
    }
  }
  return normalized;
}

List<String> agentOrchestrationReasoningEffortsFor(TargetCandidate target) {
  return _dedupe([
    ..._reasoningEffortsFromModelCatalog(target.modelCatalog),
    ..._reasoningEffortsFromMap(target.adapterCapabilities),
    ..._reasoningEffortsFromMap(target.optionOverrides),
    ..._reasoningEffortsFromMap(target.environment),
  ]);
}

List<String> agentOrchestrationReasoningEffortsForModel(
  TargetCandidate target,
  String modelName,
) {
  final catalogEfforts = _reasoningEffortsFromModelCatalog(
    target.modelCatalog,
    modelName: modelName,
  );
  if (catalogEfforts.isNotEmpty) {
    return catalogEfforts;
  }
  return agentOrchestrationReasoningEffortsFor(target);
}

String defaultAgentOrchestrationCommanderAgentId(
  Iterable<TargetCandidate> targets,
) {
  final commanders = agentOrchestrationCommanderTargets(targets);
  return commanders.isEmpty ? '' : commanders.first.target;
}

List<AgentModelLibraryEntry> agentOrchestrationModelLibraryCandidates(
  Iterable<TargetCandidate> targets,
) {
  final entries = <AgentModelLibraryEntry>[];
  for (final target in agentOrchestrationCommanderTargets(targets)) {
    final models = agentOrchestrationCommanderModels(target);
    for (final modelName in models) {
      final reasoningEfforts = agentOrchestrationReasoningEffortsForModel(
        target,
        modelName,
      );
      if (reasoningEfforts.isEmpty) {
        entries.add(
          AgentModelLibraryEntry(agentId: target.target, modelName: modelName),
        );
        continue;
      }
      for (final reasoningEffort in reasoningEfforts) {
        entries.add(
          AgentModelLibraryEntry(
            agentId: target.target,
            modelName: modelName,
            reasoningEffort: reasoningEffort,
          ),
        );
      }
    }
  }
  return List.unmodifiable(entries);
}

List<AgentModelLibraryEntry> normalizeAgentModelLibrary(
  Iterable<TargetCandidate> targets,
  Iterable<AgentModelLibraryEntry> entries,
) {
  final candidateKeys = {
    for (final entry in agentOrchestrationModelLibraryCandidates(targets))
      entry.key,
  };
  final result = <AgentModelLibraryEntry>[];
  final seen = <String>{};
  for (final entry in entries) {
    final normalized = AgentModelLibraryEntry(
      agentId: entry.agentId.trim(),
      modelName: entry.modelName.trim(),
      reasoningEffort: entry.reasoningEffort.trim(),
    );
    if (!normalized.configured ||
        !candidateKeys.contains(normalized.key) ||
        !seen.add(normalized.key)) {
      continue;
    }
    result.add(normalized);
  }
  return List.unmodifiable(result);
}

String _normalizeCommanderAgentId(
  Iterable<TargetCandidate> targets,
  String configuredAgentId,
) {
  final commanders = agentOrchestrationCommanderTargets(targets);
  final normalized = configuredAgentId.trim();
  if (commanders.any((target) => target.target == normalized)) {
    return normalized;
  }
  return '';
}

String _normalizeCommanderModelName(
  Iterable<TargetCandidate> targets,
  String commanderAgentId,
  String configuredModelName,
) {
  final normalized = configuredModelName.trim();
  if (commanderAgentId.trim().isEmpty) {
    return '';
  }
  TargetCandidate? commander;
  for (final target in targets) {
    if (target.target == commanderAgentId) {
      commander = target;
      break;
    }
  }
  if (commander == null) {
    return '';
  }
  final models = agentOrchestrationCommanderModels(commander);
  if (models.isEmpty) {
    return '';
  }
  if (models.contains(normalized)) {
    return normalized;
  }
  return models.first;
}

String _normalizeCommanderReasoningEffort(
  Iterable<TargetCandidate> targets,
  String commanderAgentId,
  String commanderModelName,
  String configuredReasoningEffort,
) {
  final normalized = configuredReasoningEffort.trim();
  if (commanderAgentId.trim().isEmpty || commanderModelName.trim().isEmpty) {
    return '';
  }
  TargetCandidate? commander;
  for (final target in targets) {
    if (target.target == commanderAgentId) {
      commander = target;
      break;
    }
  }
  if (commander == null) {
    return '';
  }
  final efforts = agentOrchestrationReasoningEffortsForModel(
    commander,
    commanderModelName,
  );
  if (efforts.isEmpty) {
    return '';
  }
  if (efforts.contains(normalized)) {
    return normalized;
  }
  return efforts.first;
}

List<String> _modelNamesFromMap(Map<String, dynamic> source) {
  final names = <String>[];
  for (final key in const [
    'models',
    'supportedModels',
    'supported_models',
    'availableModels',
    'available_models',
    'modelOptions',
    'model_options',
    'modelProfiles',
    'model_profiles',
  ]) {
    names.addAll(_modelNamesFromValue(source[key]));
  }
  return names;
}

List<String> _modelNamesFromModelCatalog(Map<String, dynamic> catalog) {
  return _dedupe([
    for (final model in _modelCatalogEntries(catalog))
      ..._modelNamesFromValue(model),
  ]);
}

List<String> _reasoningEffortsFromModelCatalog(
  Map<String, dynamic> catalog, {
  String modelName = '',
}) {
  final normalizedModel = modelName.trim();
  final names = <String>[];
  for (final map in _modelCatalogEntries(catalog)) {
    if (normalizedModel.isNotEmpty) {
      if (!_modelCatalogEntryMatchesName(map, normalizedModel)) {
        continue;
      }
    }
    names.addAll(_reasoningEffortsFromMap(map));
  }
  return _dedupe(names);
}

List<Map<String, dynamic>> _modelCatalogEntries(Map<String, dynamic> catalog) {
  final models = catalog['models'];
  if (models is! Iterable) {
    return const [];
  }
  final entries = <Map<String, dynamic>>[];
  for (final model in models) {
    if (model is Map) {
      entries.add(Map<String, dynamic>.from(model));
    }
  }
  return List.unmodifiable(entries);
}

List<String> _reasoningEffortsFromMap(Map<String, dynamic> source) {
  final names = <String>[];
  for (final key in const [
    'reasoningEfforts',
    'reasoning_efforts',
    'supportedReasoningEfforts',
    'supported_reasoning_efforts',
    'reasoningEffortOptions',
    'reasoning_effort_options',
    'thinkingLevels',
    'thinking_levels',
    'thinkingLevelOptions',
    'thinking_level_options',
    'thinkingTypes',
    'thinking_types',
    'thinkingTypeOptions',
    'thinking_type_options',
    'thinkingOptions',
    'thinking_options',
    'effortOptions',
    'effort_options',
    'efforts',
  ]) {
    names.addAll(_optionNamesFromValue(source[key]));
  }
  for (final nestedKey in const ['reasoning', 'thinking']) {
    final nested = source[nestedKey];
    if (nested is Map) {
      names.addAll(_reasoningEffortsFromMap(Map<String, dynamic>.from(nested)));
    }
  }
  return names;
}

List<String> _modelNamesFromValue(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? const [] : [trimmed];
  }
  if (value is Iterable) {
    return [for (final item in value) ..._modelNamesFromValue(item)];
  }
  if (value is Map) {
    for (final key in const [
      'name',
      'model',
      'modelName',
      'model_name',
      'id',
      'modelId',
      'model_id',
      'label',
    ]) {
      final name = value[key]?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        return [name];
      }
    }
  }
  return const [];
}

bool _modelCatalogEntryMatchesName(
  Map<String, dynamic> model,
  String modelName,
) {
  final normalized = modelName.trim();
  if (normalized.isEmpty) {
    return false;
  }
  if (_modelNamesFromValue(model).contains(normalized)) {
    return true;
  }
  return _modelDisplayNameFromValue(model) == normalized;
}

String _modelDisplayNameFromValue(Object? value) {
  if (value is String) {
    return value.trim();
  }
  if (value is Map) {
    for (final key in const ['displayName', 'display_name', 'label', 'title']) {
      final name = value[key]?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        return name;
      }
    }
    final names = _modelNamesFromValue(value);
    return names.isEmpty ? '' : names.first;
  }
  return '';
}

List<String> _optionNamesFromValue(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? const [] : [trimmed];
  }
  if (value is Iterable) {
    return [for (final item in value) ..._optionNamesFromValue(item)];
  }
  if (value is Map) {
    for (final key in const [
      'name',
      'value',
      'id',
      'label',
      'title',
      'displayName',
      'display_name',
    ]) {
      final name = value[key]?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        return [name];
      }
    }
    final enabledKeys = <String>[];
    for (final entry in value.entries) {
      if (entry.value == true) {
        enabledKeys.add(entry.key.toString());
      }
    }
    return enabledKeys;
  }
  return const [];
}

List<String> _dedupe(Iterable<String> ids) {
  final result = <String>[];
  final seen = <String>{};
  for (final id in ids) {
    final normalized = id.trim();
    if (normalized.isNotEmpty && seen.add(normalized)) {
      result.add(normalized);
    }
  }
  return result;
}
