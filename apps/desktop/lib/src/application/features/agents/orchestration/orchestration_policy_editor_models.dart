import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_target_catalog.dart';

const String defaultAgentOrchestrationPolicyId = 'default';

/// Presentation draft for the policy editor. Backend ownership remains in the
/// native orchestrator; this type never executes or stores authority state.
@immutable
final class AgentOrchestrationPolicy {
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

  /// Builds a schemaVersion=3 policy map for backend register/activate.
  Map<String, Object?> toBackendPolicy() {
    final entries = orchestrationEditorOrderedEntries(this);
    final agents = <Map<String, Object?>>[
      for (final entry in entries)
        <String, Object?>{
          'id': entry.agentId,
          'roles': const <String>['implementation'],
          'capabilities': const <String>['conversation.send'],
        },
    ];
    final steps = <Map<String, Object?>>[
      for (var index = 0; index < entries.length; index += 1)
        <String, Object?>{
          'id': 'step-${index + 1}',
          'predecessorId': index == 0 ? null : 'step-$index',
          'purpose': 'action',
          'roleId': 'implementation',
          'agentId': entries[index].agentId,
          'modelId': entries[index].modelName,
          'reasoningLevel': _reasoningLevel(entries[index].reasoningEffort),
          'contextStepIds': index == 0
              ? const <String>[]
              : <String>['step-$index'],
          'maxContextBytes': 4096,
          'outputMode': 'text',
          'timeoutMs': 600000,
          'maxAttempts': 1,
          'failureAction': 'stop',
          'approval': const <String, Object?>{'required': false},
          'condition': null,
          'validation': null,
        },
    ];
    final commander = entries.isEmpty
        ? null
        : <String, Object?>{
            'agentId': commanderAgentId.trim().isEmpty
                ? entries.first.agentId
                : commanderAgentId.trim(),
            'modelId': commanderModelName.trim().isEmpty
                ? entries.first.modelName
                : commanderModelName.trim(),
            'reasoningLevel': _reasoningLevel(
              commanderReasoningEffort.trim().isEmpty
                  ? entries.first.reasoningEffort
                  : commanderReasoningEffort,
            ),
          };
    return <String, Object?>{
      'schemaVersion': 3,
      'id': id.trim().isEmpty ? defaultAgentOrchestrationPolicyId : id.trim(),
      'label': label.trim(),
      'commander': commander,
      'modelLibrary': <Map<String, Object?>>[
        for (final entry in entries)
          <String, Object?>{
            'agentId': entry.agentId,
            'modelId': entry.modelName,
            'reasoningLevel': _reasoningLevel(entry.reasoningEffort),
          },
      ],
      'agents': agents,
      'workflow': <String, Object?>{'steps': steps},
    };
  }

  static AgentOrchestrationPolicy fromBackendPolicy(
    Map<String, Object?> policy,
  ) {
    final commander = _asMap(policy['commander']);
    final library = <AgentModelLibraryEntry>[
      for (final item in _asList(policy['modelLibrary']))
        AgentModelLibraryEntry(
          agentId: _string(item['agentId']),
          modelName: _string(item['modelId'] ?? item['modelName']),
          reasoningEffort: _string(
            item['reasoningLevel'] ?? item['reasoningEffort'],
          ),
        ),
    ];
    return AgentOrchestrationPolicy(
      id: _string(policy['id'], fallback: defaultAgentOrchestrationPolicyId),
      label: _string(policy['label']),
      commanderAgentId: _string(commander['agentId']),
      commanderModelName: _string(
        commander['modelId'] ?? commander['modelName'],
      ),
      commanderReasoningEffort: _string(
        commander['reasoningLevel'] ?? commander['reasoningEffort'],
      ),
      modelLibrary: List.unmodifiable(library),
    );
  }
}

@immutable
final class AgentModelLibraryEntry {
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

AgentModelLibraryEntry? orchestrationEditorCommanderEntry(
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

List<AgentModelLibraryEntry> orchestrationEditorOrderedEntries(
  AgentOrchestrationPolicy policy,
) {
  final result = <AgentModelLibraryEntry>[];
  final seen = <String>{};
  final commander = orchestrationEditorCommanderEntry(policy);
  if (commander != null && seen.add(commander.key)) result.add(commander);
  for (final entry in policy.modelLibrary) {
    if (entry.configured && seen.add(entry.key)) result.add(entry);
  }
  return List.unmodifiable(result);
}

AgentOrchestrationPolicy sanitizeOrchestrationPolicyEditorDraft(
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
    modelLibrary: normalizeAgentModelLibrary(targets, policy.modelLibrary),
  );
}

List<AgentModelLibraryEntry> agentOrchestrationModelLibraryCandidates(
  Iterable<TargetCandidate> targets,
) {
  final entries = <AgentModelLibraryEntry>[];
  for (final target in agentOrchestrationCommanderTargets(targets)) {
    for (final modelName in agentOrchestrationCommanderModels(target)) {
      final reasoningEfforts = agentOrchestrationReasoningEffortsForModel(
        target,
        modelName,
      );
      if (reasoningEfforts.isEmpty) {
        entries.add(
          AgentModelLibraryEntry(agentId: target.target, modelName: modelName),
        );
      } else {
        entries.addAll([
          for (final reasoningEffort in reasoningEfforts)
            AgentModelLibraryEntry(
              agentId: target.target,
              modelName: modelName,
              reasoningEffort: reasoningEffort,
            ),
        ]);
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
    if (normalized.configured &&
        candidateKeys.contains(normalized.key) &&
        seen.add(normalized.key)) {
      result.add(normalized);
    }
  }
  return List.unmodifiable(result);
}

String _normalizeCommanderAgentId(
  Iterable<TargetCandidate> targets,
  String configuredAgentId,
) {
  final normalized = configuredAgentId.trim();
  return agentOrchestrationCommanderTargets(
        targets,
      ).any((target) => target.target == normalized)
      ? normalized
      : '';
}

String _normalizeCommanderModelName(
  Iterable<TargetCandidate> targets,
  String commanderAgentId,
  String configuredModelName,
) {
  final commander = _targetById(targets, commanderAgentId);
  if (commander == null) return '';
  final models = agentOrchestrationCommanderModels(commander);
  if (models.isEmpty) return '';
  final normalized = configuredModelName.trim();
  return models.contains(normalized) ? normalized : models.first;
}

String _normalizeCommanderReasoningEffort(
  Iterable<TargetCandidate> targets,
  String commanderAgentId,
  String commanderModelName,
  String configuredReasoningEffort,
) {
  if (commanderModelName.trim().isEmpty) return '';
  final commander = _targetById(targets, commanderAgentId);
  if (commander == null) return '';
  final efforts = agentOrchestrationReasoningEffortsForModel(
    commander,
    commanderModelName,
  );
  if (efforts.isEmpty) return '';
  final normalized = configuredReasoningEffort.trim();
  return efforts.contains(normalized) ? normalized : efforts.first;
}

TargetCandidate? _targetById(
  Iterable<TargetCandidate> targets,
  String targetId,
) {
  if (targetId.trim().isEmpty) return null;
  for (final target in targets) {
    if (target.target == targetId) return target;
  }
  return null;
}

Object? _reasoningLevel(String effort) {
  switch (effort.trim().toLowerCase()) {
    case 'low':
    case 'medium':
    case 'high':
    case 'max':
      return effort.trim().toLowerCase();
    default:
      return null;
  }
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return const {};
}

List<Map<String, Object?>> _asList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map)
        <String, Object?>{
          for (final entry in item.entries) entry.key.toString(): entry.value,
        },
  ];
}

String _string(Object? value, {String fallback = ''}) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? fallback : normalized;
}
