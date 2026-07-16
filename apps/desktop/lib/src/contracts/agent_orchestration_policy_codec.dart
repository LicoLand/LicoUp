import 'package:flutter_client/src/contracts/agent_orchestration_policy_models.dart';

final class AgentOrchestrationPolicyCodec {
  const AgentOrchestrationPolicyCodec._();

  static AgentOrchestrationPolicy decode(Map<String, dynamic> json) {
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
          AgentModelLibraryEntryCodec.decode(_jsonMap(item)),
      ]),
    );
  }

  static Map<String, dynamic> encode(AgentOrchestrationPolicy policy) {
    return {
      'schemaVersion': 1,
      'id': policy.id,
      'label': policy.label,
      'commander': {
        'agentId': policy.commanderAgentId,
        'modelName': policy.commanderModelName,
        'reasoningEffort': policy.commanderReasoningEffort,
      },
      'modelLibrary': [
        for (final entry in policy.modelLibrary)
          AgentModelLibraryEntryCodec.encode(entry),
      ],
    };
  }
}

final class AgentModelLibraryEntryCodec {
  const AgentModelLibraryEntryCodec._();

  static AgentModelLibraryEntry decode(Map<String, dynamic> json) {
    return AgentModelLibraryEntry(
      agentId: _jsonString(json['agentId']),
      modelName: _jsonString(json['modelName']),
      reasoningEffort: _jsonString(json['reasoningEffort']),
    );
  }

  static Map<String, dynamic> encode(AgentModelLibraryEntry entry) {
    return {
      'agentId': entry.agentId,
      'modelName': entry.modelName,
      'reasoningEffort': entry.reasoningEffort,
    };
  }
}

extension AgentOrchestrationPolicyEncoding on AgentOrchestrationPolicy {
  Map<String, dynamic> toJson() => AgentOrchestrationPolicyCodec.encode(this);
}

extension AgentModelLibraryEntryEncoding on AgentModelLibraryEntry {
  Map<String, dynamic> toJson() => AgentModelLibraryEntryCodec.encode(this);
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}

List<Object?> _jsonList(Object? value) => value is List ? value : const [];

String _jsonString(Object? value, {String fallback = ''}) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? fallback : normalized;
}
