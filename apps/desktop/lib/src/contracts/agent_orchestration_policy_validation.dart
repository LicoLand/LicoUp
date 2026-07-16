import 'package:flutter_client/src/contracts/agent_orchestration_policy_catalog.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

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
