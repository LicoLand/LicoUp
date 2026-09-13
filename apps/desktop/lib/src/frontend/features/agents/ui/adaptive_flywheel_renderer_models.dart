import 'package:licoup/src/contracts/target_candidate.dart';

/// Renderer-local value for one Adaptive Flywheel assignment capsule.
final class DailyConversationAgentAssignment {
  const DailyConversationAgentAssignment({
    this.id = '',
    this.agentId = '',
    this.modelName = '',
    this.reasoningEffort = '',
    this.fast = false,
  });

  final String id;
  final String agentId;
  final String modelName;
  final String reasoningEffort;
  final bool fast;

  bool get configured => agentId.trim().isNotEmpty;

  DailyConversationAgentAssignment copyWith({
    String? id,
    String? agentId,
    String? modelName,
    String? reasoningEffort,
    bool? fast,
  }) => DailyConversationAgentAssignment(
    id: id ?? this.id,
    agentId: agentId ?? this.agentId,
    modelName: modelName ?? this.modelName,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    fast: fast ?? this.fast,
  );
}

final class AgentOrchestrationModelGroup {
  const AgentOrchestrationModelGroup({
    required this.providerId,
    required this.providerLabel,
    required this.models,
  });

  final String providerId;
  final String providerLabel;
  final List<String> models;
}

List<TargetCandidate> agentOrchestrationCommanderTargets(
  Iterable<TargetCandidate> targets,
) {
  final result =
      targets
          .where(
            (target) => target.isConversationAgent && target.canRelayRuntime,
          )
          .toList(growable: false)
        ..sort((left, right) {
          final byLabel = left.label.toLowerCase().compareTo(
            right.label.toLowerCase(),
          );
          return byLabel != 0
              ? byLabel
              : left.target.toLowerCase().compareTo(right.target.toLowerCase());
        });
  return List.unmodifiable(result);
}

/// One renderer snapshot of the native catalog. Native order and display names
/// are retained; model lookup does not walk the catalog for every visible row.
final class AgentOrchestrationModelCatalog {
  AgentOrchestrationModelCatalog(TargetCandidate target) {
    final entries = _modelEntries(target.modelCatalog);
    _hasCatalogEntries = entries.isNotEmpty;
    final entriesByModel = <String, List<Map<String, dynamic>>>{};
    for (final entry in entries) {
      for (final name in _modelNames(entry)) {
        entriesByModel.putIfAbsent(name, () => []).add(entry);
      }
    }
    models = List.unmodifiable(
      entriesByModel.isNotEmpty
          ? entriesByModel.keys
          : _modelNames(target.adapterCapabilities),
    );
    final grouped =
        <String, ({String id, String label, List<String> models})>{};
    for (final model in models) {
      final matching = entriesByModel[model] ?? const [];
      final first = matching.firstOrNull;
      final last = matching.lastOrNull;
      final displayName = _firstString(first, const [
        'displayName',
        'display_name',
        'label',
        'name',
        'id',
      ]);
      _labels[model] = displayName.isEmpty ? model : displayName;
      _searchLabels[model] = _labels[model]!.toLowerCase();
      final efforts = _dedupe(
        entries.isEmpty
            ? _reasoningEfforts(target.adapterCapabilities)
            : matching.expand(_reasoningEfforts),
      );
      _efforts[model] = efforts;
      final preferred = matching
          .map(
            (entry) => _firstString(entry, const [
              'defaultReasoningEffort',
              'default_reasoning_effort',
            ]),
          )
          .where(efforts.contains)
          .firstOrNull;
      _defaults[model] = preferred ?? efforts.firstOrNull ?? '';
      final id = _firstString(last, const [
        'providerId',
        'providerID',
        'provider_id',
      ]);
      final label = _firstString(last, const [
        'provider',
        'providerName',
        'provider_name',
        'providerLabel',
        'provider_label',
      ]);
      final visibleLabel = label.isEmpty ? id : label;
      final key = (id.isNotEmpty ? id : visibleLabel).toLowerCase();
      grouped
          .putIfAbsent(
            key,
            () => (id: id, label: visibleLabel, models: <String>[]),
          )
          .models
          .add(model);
    }
    groups = List.unmodifiable([
      for (final group in grouped.values)
        AgentOrchestrationModelGroup(
          providerId: group.id,
          providerLabel: group.label,
          models: List.unmodifiable(group.models),
        ),
    ]);
    allEfforts = _dedupe(
      entries.isEmpty
          ? _reasoningEfforts(target.adapterCapabilities)
          : entries.expand(_reasoningEfforts),
    );
  }

  late final List<String> models;
  late final List<AgentOrchestrationModelGroup> groups;
  late final List<String> allEfforts;
  late final bool _hasCatalogEntries;
  final _labels = <String, String>{};
  final _searchLabels = <String, String>{};
  final _efforts = <String, List<String>>{};
  final _defaults = <String, String>{};

  bool contains(String model) => _labels.containsKey(model);
  String displayName(String model) => _labels[model.trim()] ?? model.trim();
  List<String> reasoningEfforts(String model) =>
      _hasCatalogEntries ? _efforts[model.trim()] ?? const [] : allEfforts;
  String defaultReasoningEffort(String model) =>
      _defaults[model.trim()] ?? reasoningEfforts(model).firstOrNull ?? '';

  List<AgentOrchestrationModelGroup> matchingGroups(String normalizedQuery) {
    if (normalizedQuery.isEmpty) return groups;
    final result = <AgentOrchestrationModelGroup>[];
    for (final group in groups) {
      final matches = [
        for (final model in group.models)
          if (model.toLowerCase().contains(normalizedQuery) ||
              _searchLabels[model]!.contains(normalizedQuery))
            model,
      ];
      if (matches.isNotEmpty) {
        result.add(
          AgentOrchestrationModelGroup(
            providerId: group.providerId,
            providerLabel: group.providerLabel,
            models: List.unmodifiable(matches),
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }
}

/// Scoped to an open assignment picker. Catalog replacement invalidates the
/// projection; pointer movement, scrolling and unrelated target metadata do not.
final class AgentOrchestrationModelCatalogCache {
  final _entries =
      <
        String,
        ({
          Map<String, dynamic> catalog,
          Map<String, dynamic> capabilities,
          AgentOrchestrationModelCatalog projection,
        })
      >{};

  AgentOrchestrationModelCatalog forTarget(TargetCandidate target) {
    final cached = _entries[target.target];
    if (cached != null &&
        identical(cached.catalog, target.modelCatalog) &&
        identical(cached.capabilities, target.adapterCapabilities)) {
      return cached.projection;
    }
    final projection = AgentOrchestrationModelCatalog(target);
    _entries[target.target] = (
      catalog: target.modelCatalog,
      capabilities: target.adapterCapabilities,
      projection: projection,
    );
    return projection;
  }
}

List<String> agentOrchestrationCommanderModels(TargetCandidate target) =>
    AgentOrchestrationModelCatalog(target).models;

List<AgentOrchestrationModelGroup> agentOrchestrationCommanderModelGroups(
  TargetCandidate target,
) => AgentOrchestrationModelCatalog(target).groups;

String agentOrchestrationModelDisplayName(
  TargetCandidate target,
  String modelName,
) => AgentOrchestrationModelCatalog(target).displayName(modelName);

/// Scores and capability tags are native planning data, not picker copy.
String agentOrchestrationModelPickerLabel(
  TargetCandidate target,
  String modelName,
) => agentOrchestrationModelDisplayName(target, modelName);

List<String> agentOrchestrationReasoningEffortsFor(TargetCandidate target) =>
    AgentOrchestrationModelCatalog(target).allEfforts;

List<String> agentOrchestrationReasoningEffortsForModel(
  TargetCandidate target,
  String modelName,
) => AgentOrchestrationModelCatalog(target).reasoningEfforts(modelName);

String agentOrchestrationDefaultReasoningEffortForModel(
  TargetCandidate target,
  String modelName,
) => AgentOrchestrationModelCatalog(target).defaultReasoningEffort(modelName);

List<Map<String, dynamic>> _modelEntries(Map<String, dynamic> catalog) =>
    switch (catalog['models']) {
      final Iterable values => [
        for (final value in values)
          if (value is Map) Map<String, dynamic>.from(value),
      ],
      _ => const [],
    };

List<String> _modelNames(Object? value) {
  if (value is String) return value.trim().isEmpty ? const [] : [value.trim()];
  if (value is Iterable) return _dedupe(value.expand(_modelNames));
  if (value is! Map) return const [];
  final map = Map<String, dynamic>.from(value);
  return _dedupe([
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
      'id',
      'name',
      'model',
      'modelId',
      'model_id',
    ])
      ..._modelNames(map[key]),
  ]);
}

List<String> _reasoningEfforts(Map<String, dynamic> map) => _dedupe([
  for (final key in const [
    'reasoningEfforts',
    'reasoning_efforts',
    'supportedReasoningEfforts',
    'supported_reasoning_efforts',
    'reasoningOptions',
    'reasoning_options',
  ])
    ..._modelNames(map[key]),
]);

String _firstString(Map<String, dynamic>? map, List<String> keys) {
  if (map == null) return '';
  for (final key in keys) {
    final value = map[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return '';
}

List<String> _dedupe(Iterable<String> values) => List.unmodifiable({
  for (final value in values)
    if (value.trim().isNotEmpty) value.trim(),
});
