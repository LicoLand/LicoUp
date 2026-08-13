/// Native boundary for aggregate-only local skill usage reports.
abstract interface class SkillUsageGateway {
  Future<Map<String, dynamic>> reportSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  });

  /// Incremental history backfill. Idempotent and cheap after the first run
  /// (watermarks); failures leave previously backfilled data intact.
  Future<Map<String, dynamic>> scanSkillUsage({
    String agent = '',
    bool forceRefresh = false,
  });
}

abstract interface class SkillUsageViewModel {
  bool get isSkillUsageBusy;

  Map<String, dynamic>? get skillUsageReport;

  Future<void> loadSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  });

  /// Background scan + report refresh for card invocation counts. Silent on
  /// failure: counts are an enhancement, never a panel error state.
  Future<void> loadSkillUsageCounts();
}

/// Normalizes a catalog skill id to the ledger's sanitized form (trim,
/// lowercase ASCII alphanumerics plus `-`/`_`, every other character
/// collapses to `-`, leading/trailing `-` stripped) so catalog ids like
/// `MySkill` join to ledger ids like `myskill`.
String normalizeSkillUsageId(String value) {
  final buffer = StringBuffer();
  for (final rune in value.trim().runes) {
    final isAlnum =
        (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A);
    if (isAlnum || rune == 0x2D || rune == 0x5F) {
      buffer.write(String.fromCharCode(rune).toLowerCase());
    } else {
      buffer.write('-');
    }
  }
  return buffer.toString().replaceAll(RegExp(r'^-+|-+$'), '');
}

/// Per-skill ALL-TIME invocation counts keyed by normalized skill id, parsed
/// from the report's `totalsBySkill` list (window-independent).
Map<String, int> skillUsageTotalsBySkill(Map<String, dynamic>? report) {
  return _skillUsageCountMap(report?['totalsBySkill']);
}

/// Per-skill invocation counts inside the report window, keyed by normalized
/// skill id, parsed from the report's `bySkill` list.
Map<String, int> skillUsageWindowedBySkill(Map<String, dynamic>? report) {
  return _skillUsageCountMap(report?['bySkill']);
}

Map<String, int> _skillUsageCountMap(Object? items) {
  if (items is! List) {
    return const {};
  }
  final counts = <String, int>{};
  for (final item in items) {
    if (item is! Map) {
      continue;
    }
    final id = normalizeSkillUsageId((item['skillId'] ?? '').toString());
    final count = item['count'];
    if (id.isEmpty || count is! num || count <= 0) {
      continue;
    }
    counts[id] = (counts[id] ?? 0) + count.round();
  }
  return Map<String, int>.unmodifiable(counts);
}
