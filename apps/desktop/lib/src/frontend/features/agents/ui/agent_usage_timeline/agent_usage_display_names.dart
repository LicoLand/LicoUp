import 'package:licoup/src/presentation/agents/agent_product_identity.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';

String agentUsageAgentDisplayName(AgentUsageAgentSummary agent) {
  final known = agentProductDisplayName(agent.agentId);
  if (known != null) {
    return known;
  }
  final fallback = agent.label.trim().isEmpty
      ? agent.agentId.trim()
      : agent.label.trim();
  final productLabel = fallback.replaceFirst(
    RegExp(r'\s*-\s*(?:desktop|cli|ide|plugin)\s*$', caseSensitive: false),
    '',
  );
  return agentUsageTitleCase(productLabel.replaceAll(RegExp(r'[-_]+'), ' '));
}

String agentUsageTitleCase(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  return '${trimmed[0].toUpperCase()}${trimmed.substring(1).toLowerCase()}';
}
