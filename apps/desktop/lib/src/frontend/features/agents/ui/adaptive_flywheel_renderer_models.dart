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

List<String> agentOrchestrationCommanderModels(TargetCandidate target) {
  final fromCatalog = _modelEntries(
    target.modelCatalog,
  ).expand(_modelNames).toList(growable: false);
  return _dedupe(
    fromCatalog.isNotEmpty
        ? fromCatalog
        : _modelNames(target.adapterCapabilities),
  );
}

List<AgentOrchestrationModelGroup> agentOrchestrationCommanderModelGroups(
  TargetCandidate target,
) {
  final models = agentOrchestrationCommanderModels(target);
  if (models.isEmpty) return const [];
  final entries = _modelEntries(target.modelCatalog);
  final grouped = <String, ({String id, String label, List<String> models})>{};
  for (final model in models) {
    final entry = entries.cast<Map<String, dynamic>?>().firstWhere(
      (candidate) =>
          candidate != null && _modelNames(candidate).contains(model),
      orElse: () => null,
    );
    final id = _firstString(entry, const [
      'providerId',
      'providerID',
      'provider_id',
    ]);
    final label = _firstString(entry, const [
      'provider',
      'providerName',
      'provider_name',
      'providerLabel',
      'provider_label',
    ]);
    final key = (id.isNotEmpty ? id : label).toLowerCase();
    final current = grouped[key];
    grouped[key] = (
      id: current?.id ?? id,
      label: current?.label ?? label,
      models: [...?current?.models, model],
    );
  }
  return List.unmodifiable([
    for (final group in grouped.values)
      AgentOrchestrationModelGroup(
        providerId: group.id,
        providerLabel: group.label,
        models: List.unmodifiable(group.models),
      ),
  ]);
}

String agentOrchestrationModelDisplayName(
  TargetCandidate target,
  String modelName,
) {
  final normalized = modelName.trim();
  if (normalized.isEmpty) return '';
  for (final entry in _modelEntries(target.modelCatalog)) {
    if (!_modelNames(entry).contains(normalized)) continue;
    final label = _firstString(entry, const [
      'displayName',
      'display_name',
      'label',
      'name',
      'id',
    ]);
    if (label.isNotEmpty) return label;
  }
  return normalized;
}

List<String> agentOrchestrationReasoningEffortsFor(TargetCandidate target) =>
    _dedupe([
      for (final entry in _modelEntries(target.modelCatalog))
        ..._reasoningEfforts(entry),
      if (_modelEntries(target.modelCatalog).isEmpty)
        ..._reasoningEfforts(target.adapterCapabilities),
    ]);

List<String> agentOrchestrationReasoningEffortsForModel(
  TargetCandidate target,
  String modelName,
) {
  final matching = _modelEntries(target.modelCatalog)
      .where((entry) => _modelNames(entry).contains(modelName.trim()))
      .expand(_reasoningEfforts);
  final result = _dedupe(matching);
  return result.isEmpty
      ? agentOrchestrationReasoningEffortsFor(target)
      : result;
}

String agentOrchestrationDefaultReasoningEffortForModel(
  TargetCandidate target,
  String modelName,
) {
  final efforts = agentOrchestrationReasoningEffortsForModel(target, modelName);
  if (efforts.isEmpty) return '';
  for (final entry in _modelEntries(target.modelCatalog)) {
    if (!_modelNames(entry).contains(modelName.trim())) continue;
    final preferred = _firstString(entry, const [
      'defaultReasoningEffort',
      'default_reasoning_effort',
    ]);
    if (efforts.contains(preferred)) return preferred;
  }
  return efforts.first;
}

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
