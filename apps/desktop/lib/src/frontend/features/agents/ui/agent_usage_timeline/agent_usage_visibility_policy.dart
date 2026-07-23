import 'package:flutter_client/src/contracts/agent_usage_models.dart';

bool shouldShowAgentUsage(
  AgentUsageAgentSummary agent,
  Set<String> detectedAgentIds,
) {
  final agentId = agent.agentId.trim().toLowerCase();
  if (agentId.isEmpty ||
      agentId == 'code' ||
      agentId == 'vscode' ||
      agentId == 'vs-code' ||
      agent.status == 'not-detected') {
    return false;
  }
  final detected = detectedAgentIds
      .map(_normalizeAgentId)
      .where((id) => id.isNotEmpty)
      .toSet();
  if (detected.isEmpty) {
    return agent.totalTokens > 0 ||
        const {'detected', 'configured', 'manual'}.contains(agent.status);
  }
  return detected.contains(agentId) || agent.totalTokens > 0;
}

String _normalizeAgentId(String value) {
  return switch (value.trim().toLowerCase()) {
    'claude' => 'claude-code',
    'github-copilot' => 'copilot',
    'vscode' || 'vs-code' => 'code',
    'kilo' => 'kilo-code',
    'hermes-agent' => 'hermes',
    'pi-agent' || 'pi-coding-agent' => 'pi',
    final value => value,
  };
}
