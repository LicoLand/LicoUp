/// Mention token written into the composer draft (`@Display Label`).
String composerAgentMentionToken(String displayLabel) {
  final label = displayLabel.trim();
  return label.isEmpty ? '' : '@$label';
}

/// Resolve `@Label` / `@agentId` tokens against configured agents.
List<String> parseComposerAgentMentionIds({
  required String text,
  required Iterable<({String id, String label})> agents,
}) {
  final haystack = text;
  if (haystack.isEmpty) return const [];
  final catalog = [
    for (final agent in agents)
      if (agent.id.trim().isNotEmpty)
        (
          id: agent.id.trim(),
          label: agent.label.trim().isNotEmpty
              ? agent.label.trim()
              : agent.id.trim(),
        ),
  ];
  catalog.sort((a, b) {
    final byLabel = b.label.length.compareTo(a.label.length);
    if (byLabel != 0) return byLabel;
    return b.id.length.compareTo(a.id.length);
  });
  final found = <String>[];
  final seen = <String>{};
  for (final agent in catalog) {
    final needles = <String>{
      composerAgentMentionToken(agent.label),
      composerAgentMentionToken(agent.id),
    };
    for (final needle in needles) {
      if (needle.isEmpty) continue;
      if (haystack.contains(needle) && seen.add(agent.id)) {
        found.add(agent.id);
        break;
      }
    }
  }
  return found;
}
