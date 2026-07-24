import 'package:licoup/src/application/features/agents/agent_product_names.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

export 'package:licoup/src/application/features/agents/agent_product_names.dart';

/// Canonical product identity for conversation surfaces. The Desktop / CLI /
/// IDE / Plugin distinction is a delivery-channel detail, not a product
/// distinction, so it is stripped from both ids and labels.
String agentConversationProductId(String value) => agentProductId(value);

/// Display name for a conversation target without the delivery-channel
/// suffix, aligned with the monitoring panel's product names (for example
/// both Codex CLI and Codex Desktop surface as "Codex").
String agentConversationTargetDisplayName(TargetCandidate target) {
  final known = agentProductDisplayName(target.target);
  if (known != null) {
    return known;
  }
  final fallback = target.label.trim().isEmpty
      ? target.target.trim()
      : target.label.trim();
  return agentProductLabel(fallback);
}
