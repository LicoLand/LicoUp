import 'package:flutter/foundation.dart';

const String defaultAgentOrchestrationPolicyId = 'default';

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
