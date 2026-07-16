import 'package:flutter_client/src/contracts/agent_orchestration_policy_models.dart';

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
  if (commander != null && seen.add(commander.key)) result.add(commander);
  for (final entry in policy.modelLibrary) {
    if (entry.configured && seen.add(entry.key)) result.add(entry);
  }
  return List.unmodifiable(result);
}
