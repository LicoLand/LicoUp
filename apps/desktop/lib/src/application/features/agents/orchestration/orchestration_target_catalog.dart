import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

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
    return labelCompare != 0
        ? labelCompare
        : a.target.toLowerCase().compareTo(b.target.toLowerCase());
  });
  return List.unmodifiable(result);
}

List<String> agentOrchestrationCommanderModels(TargetCandidate target) {
  final catalogModels = _modelNamesFromModelCatalog(target.modelCatalog);
  return catalogModels.isNotEmpty
      ? catalogModels
      : _dedupe(_modelNamesFromMap(target.adapterCapabilities));
}

String agentOrchestrationModelDisplayName(
  TargetCandidate target,
  String modelName,
) {
  final normalized = modelName.trim();
  if (normalized.isEmpty) return '';
  for (final model in _modelCatalogEntries(target.modelCatalog)) {
    if (_modelCatalogEntryMatchesName(model, normalized)) {
      final displayName = _modelDisplayNameFromValue(model);
      if (displayName.isNotEmpty) return displayName;
    }
  }
  return normalized;
}

List<String> agentOrchestrationReasoningEffortsFor(TargetCandidate target) {
  if (target.target == 'antigravity') return const [];
  return _dedupe([
    ..._reasoningEffortsFromModelCatalog(target.modelCatalog),
    ..._reasoningEffortsFromMap(target.adapterCapabilities),
  ]);
}

List<String> agentOrchestrationReasoningEffortsForModel(
  TargetCandidate target,
  String modelName,
) {
  if (target.target == 'antigravity') return const [];
  final catalogEfforts = _reasoningEffortsFromModelCatalog(
    target.modelCatalog,
    modelName: modelName,
  );
  return catalogEfforts.isNotEmpty
      ? catalogEfforts
      : agentOrchestrationReasoningEffortsFor(target);
}

/// Catalog-declared default reasoning effort for [modelName], or the first
/// supported effort when the catalog omits an explicit default.
String agentOrchestrationDefaultReasoningEffortForModel(
  TargetCandidate target,
  String modelName,
) {
  if (target.target == 'antigravity') return '';
  final efforts = agentOrchestrationReasoningEffortsForModel(target, modelName);
  if (efforts.isEmpty) return '';
  final fromCatalog = _defaultReasoningEffortFromModelCatalog(
    target.modelCatalog,
    modelName: modelName,
  );
  if (fromCatalog.isNotEmpty && efforts.contains(fromCatalog)) {
    return fromCatalog;
  }
  return efforts.first;
}

String _defaultReasoningEffortFromModelCatalog(
  Map<String, dynamic> catalog, {
  required String modelName,
}) {
  final normalizedModel = modelName.trim();
  for (final map in _modelCatalogEntries(catalog)) {
    if (normalizedModel.isNotEmpty &&
        !_modelCatalogEntryMatchesName(map, normalizedModel)) {
      continue;
    }
    for (final key in const [
      'defaultReasoningEffort',
      'default_reasoning_effort',
    ]) {
      final value = map[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
  }
  return '';
}

String defaultAgentOrchestrationCommanderAgentId(
  Iterable<TargetCandidate> targets,
) {
  final commanders = agentOrchestrationCommanderTargets(targets);
  return commanders.isEmpty ? '' : commanders.first.target;
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
    if (normalizedModel.isNotEmpty &&
        !_modelCatalogEntryMatchesName(map, normalizedModel)) {
      continue;
    }
    names.addAll(_reasoningEffortsFromMap(map));
  }
  return _dedupe(names);
}

List<Map<String, dynamic>> _modelCatalogEntries(Map<String, dynamic> catalog) {
  final models = catalog['models'];
  if (models is! Iterable) return const [];
  return List.unmodifiable([
    for (final model in models)
      if (model is Map) Map<String, dynamic>.from(model),
  ]);
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
      if (name.isNotEmpty) return [name];
    }
  }
  return const [];
}

bool _modelCatalogEntryMatchesName(
  Map<String, dynamic> model,
  String modelName,
) {
  final normalized = modelName.trim();
  return normalized.isNotEmpty &&
      (_modelNamesFromValue(model).contains(normalized) ||
          _modelDisplayNameFromValue(model) == normalized);
}

String _modelDisplayNameFromValue(Object? value) {
  if (value is String) return value.trim();
  if (value is Map) {
    for (final key in const ['displayName', 'display_name', 'label', 'title']) {
      final name = value[key]?.toString().trim() ?? '';
      if (name.isNotEmpty) return name;
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
      if (name.isNotEmpty) return [name];
    }
    return [
      for (final entry in value.entries)
        if (entry.value == true) entry.key.toString(),
    ];
  }
  return const [];
}

List<String> _dedupe(Iterable<String> ids) {
  final result = <String>[];
  final seen = <String>{};
  for (final id in ids) {
    final normalized = id.trim();
    if (normalized.isNotEmpty && seen.add(normalized)) result.add(normalized);
  }
  return result;
}
