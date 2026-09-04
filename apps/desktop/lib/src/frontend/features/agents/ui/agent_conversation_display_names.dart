import 'package:licoup/src/contracts/agent_product_identity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

export 'package:licoup/src/contracts/agent_product_identity.dart';

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

/// Short product labels for narrow, local-only identity surfaces. Full names
/// remain the accessible/hover label; unknown products keep their full label.
String agentConversationTargetCompactDisplayName(TargetCandidate target) {
  return switch (agentConversationProductId(target.target)) {
    'antigravity' => 'Antigravity',
    'claude' || 'claude-code' => 'Claude',
    'chatgpt' || 'codex' => 'Codex',
    'copilot' || 'github-copilot' => 'Copilot',
    'cursor' => 'Cursor',
    'hermes' || 'hermes-agent' => 'Hermes',
    'kilo' || 'kilo-code' => 'Kilo',
    'kimi' || 'kimi-code' => 'Kimi',
    'lico' || 'lico-agent' => 'Lico',
    'openclaw' => 'OpenClaw',
    'opencode' => 'OpenCode',
    'pi' || 'pi-agent' || 'pi-coding-agent' => 'Pi',
    'trae' || 'trae-agent' => 'Trae',
    _ => agentConversationTargetDisplayName(target),
  };
}
