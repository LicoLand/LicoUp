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
  if (detectedAgentIds.isEmpty) {
    return agent.totalTokens > 0 || agent.status != 'pending';
  }
  return detectedAgentIds.contains(agent.agentId) || agent.totalTokens > 0;
}
