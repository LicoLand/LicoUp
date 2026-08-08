/// Canonical product identity for agent targets. The Desktop / CLI / IDE /
/// Plugin distinction is a delivery-channel detail, not a product
/// distinction, so it is stripped from both ids and labels.
String agentProductId(String value) {
  return value.trim().toLowerCase().replaceFirst(
    RegExp(r'-(?:desktop|cli|ide|plugin)$'),
    '',
  );
}

/// Canonical product display name for a known agent id (for example both
/// Codex CLI and Codex Desktop surface as "Codex"), or null when the id is
/// not a recognized product.
String? agentProductDisplayName(String value) {
  return switch (agentProductId(value)) {
    'antigravity' => 'Antigravity',
    'claude' || 'claude-code' => 'Claude Code',
    'chatgpt' || 'codex' => 'Codex',
    'copilot' || 'github-copilot' => 'GitHub Copilot',
    'cursor' => 'Cursor',
    'hermes' || 'hermes-agent' => 'Hermes Agent',
    'kilo' || 'kilo-code' => 'Kilo Code',
    'kimi' => 'Kimi',
    'kimi-code' => 'Kimi Code',
    'lico-agent' || 'lico' => 'Lico Agent',
    'openclaw' => 'OpenClaw',
    'opencode' => 'OpenCode',
    'pi' || 'pi-agent' || 'pi-coding-agent' => 'Pi Agent',
    _ => null,
  };
}

/// Display label for an agent id or raw label without the delivery-channel
/// suffix. Known products resolve to their canonical product name; unknown
/// values are returned with any trailing channel suffix stripped.
String agentProductLabel(String value) {
  final known = agentProductDisplayName(value);
  if (known != null) {
    return known;
  }
  return value
      .trim()
      .replaceFirst(
        RegExp(r'\s*-\s*(?:desktop|cli|ide|plugin)\s*$', caseSensitive: false),
        '',
      )
      .trim();
}
