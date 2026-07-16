import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

/// Maps the orchestration editor view model onto the canonical routing policy.
/// This conversion exists only at the UI boundary; dispatch reads the resulting
/// [RoutingPolicyDocument] directly from the routing module.
RoutingPolicyDocument routingPolicyFromEditor(
  AgentOrchestrationPolicy editorPolicy, {
  RoutingPolicyDocument basePolicy = emptyRoutingPolicyDocument,
}) {
  final entries = agentOrchestrationDispatchModelLibrary(editorPolicy);
  final existingById = {
    for (final agent in basePolicy.agents) agent.id.trim(): agent,
  };
  return RoutingPolicyDocument(
    schemaVersion: routingPolicySchemaVersion,
    id: editorPolicy.id.trim().isEmpty
        ? defaultAgentOrchestrationPolicyId
        : editorPolicy.id.trim(),
    label: editorPolicy.label.trim(),
    agents: List.unmodifiable([
      for (var index = 0; index < entries.length; index += 1)
        RoutingPolicyAgent(
          id: entries[index].agentId.trim(),
          modelName: entries[index].modelName.trim(),
          reasoningEffort: entries[index].reasoningEffort.trim(),
          coordinator: index == 0,
          roles: existingById[entries[index].agentId.trim()]?.roles ?? const [],
          capabilities:
              existingById[entries[index].agentId.trim()]?.capabilities ??
              const [],
          priority: index + 1,
          distillation:
              existingById[entries[index].agentId.trim()]?.distillation ??
              const RoutingAgentDistillation(),
        ),
    ]),
    routing: basePolicy.routing,
    distillation: basePolicy.distillation,
  );
}

AgentOrchestrationPolicy orchestrationEditorFromRoutingPolicy(
  RoutingPolicyDocument policy,
) {
  if (policy.isEmpty) {
    return const AgentOrchestrationPolicy();
  }
  final indexed = <({RoutingPolicyAgent agent, int order})>[
    for (var index = 0; index < policy.agents.length; index += 1)
      (agent: policy.agents[index], order: index),
  ];
  indexed.sort((left, right) {
    final priority = left.agent.priority.compareTo(right.agent.priority);
    if (priority != 0) {
      return priority;
    }
    return left.order.compareTo(right.order);
  });
  final ordered = indexed.map((entry) => entry.agent).toList(growable: false);
  final coordinatorIndex = ordered.indexWhere((agent) => agent.coordinator);
  final commander = coordinatorIndex >= 0
      ? ordered[coordinatorIndex]
      : ordered.first;
  final library = <AgentModelLibraryEntry>[
    for (final agent in ordered)
      AgentModelLibraryEntry(
        agentId: agent.id,
        modelName: agent.modelName,
        reasoningEffort: agent.reasoningEffort,
      ),
  ];
  return AgentOrchestrationPolicy(
    id: policy.id,
    label: policy.label,
    commanderAgentId: commander.id,
    commanderModelName: commander.modelName,
    commanderReasoningEffort: commander.reasoningEffort,
    modelLibrary: List.unmodifiable(library),
  );
}
