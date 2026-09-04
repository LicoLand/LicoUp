/// Canonical product identity for agent targets. Delivery channels such as
/// desktop, CLI, IDE, and plugin do not create a second product identity.
String agentProductId(String value) => value.trim().toLowerCase().replaceFirst(
  RegExp(r'-(?:desktop|cli|ide|plugin)$'),
  '',
);

/// Canonical display name for a known agent product.
String? agentProductDisplayName(String value) =>
    switch (agentProductId(value)) {
      'antigravity' => 'Antigravity',
      'claude' || 'claude-code' => 'Claude Code',
      'chatgpt' || 'codex' => 'Codex',
      'copilot' || 'github-copilot' => 'GitHub Copilot',
      'cursor' => 'Cursor',
      'deepseek-harness' || 'dsh' => 'DeepSeek Harness',
      'hermes' || 'hermes-agent' => 'Hermes Agent',
      'kilo' || 'kilo-code' => 'Kilo Code',
      'kimi' => 'Kimi',
      'kimi-code' => 'Kimi Code',
      'codebuddy' => 'CodeBuddy',
      'trae' || 'trae-agent' => 'Trae Agent',
      'trae-work' => 'Trae Work',
      'workbuddy' => 'WorkBuddy',
      'lico-agent' || 'lico' => 'Lico Agent',
      'openclaw' => 'OpenClaw',
      'opencode' => 'OpenCode',
      'pi' || 'pi-agent' || 'pi-coding-agent' => 'Pi Agent',
      _ => null,
    };

/// Display label without a delivery-channel suffix.
String agentProductLabel(String value) {
  final known = agentProductDisplayName(value);
  if (known != null) return known;
  return value
      .trim()
      .replaceFirst(
        RegExp(r'\s*-\s*(?:desktop|cli|ide|plugin)\s*$', caseSensitive: false),
        '',
      )
      .trim();
}
