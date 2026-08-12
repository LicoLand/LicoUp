import 'package:licoup/src/contracts/target_candidate.dart';

List<String> conversationReasoningEffortsForModel(
  TargetCandidate target,
  String modelName,
) {
  if (target.target == 'antigravity') return const [];
  final normalizedModel = modelName.trim();
  final efforts = <String>[];
  for (final raw
      in target.modelCatalog['models'] is Iterable
          ? target.modelCatalog['models'] as Iterable
          : const []) {
    if (raw is! Map) continue;
    final model = Map<String, dynamic>.from(raw);
    final names = <String>{
      for (final key in const ['name', 'model', 'modelName', 'id', 'modelId'])
        if ((model[key] ?? '').toString().trim().isNotEmpty)
          (model[key] ?? '').toString().trim(),
    };
    if (normalizedModel.isNotEmpty && !names.contains(normalizedModel)) {
      continue;
    }
    for (final key in const [
      'reasoningEfforts',
      'supportedReasoningEfforts',
      'thinkingLevels',
      'thinkingTypes',
      'efforts',
    ]) {
      final value = model[key];
      if (value is Iterable) {
        for (final item in value) {
          final name = item is Map
              ? (item['name'] ?? item['value'] ?? item['id'] ?? '')
                    .toString()
                    .trim()
              : item.toString().trim();
          if (name.isNotEmpty && !efforts.contains(name)) efforts.add(name);
        }
      }
    }
  }
  return List.unmodifiable(efforts);
}

String conversationDefaultReasoningEffortForModel(
  TargetCandidate target,
  String modelName,
) {
  final efforts = conversationReasoningEffortsForModel(target, modelName);
  if (efforts.isEmpty) return '';
  final normalizedModel = modelName.trim();
  for (final raw
      in target.modelCatalog['models'] is Iterable
          ? target.modelCatalog['models'] as Iterable
          : const []) {
    if (raw is! Map) continue;
    final model = Map<String, dynamic>.from(raw);
    final name = (model['name'] ?? model['model'] ?? model['id'] ?? '')
        .toString()
        .trim();
    if (normalizedModel.isNotEmpty && name != normalizedModel) continue;
    final selected =
        (model['defaultReasoningEffort'] ??
                model['default_reasoning_effort'] ??
                '')
            .toString()
            .trim();
    if (efforts.contains(selected)) return selected;
  }
  return efforts.first;
}
