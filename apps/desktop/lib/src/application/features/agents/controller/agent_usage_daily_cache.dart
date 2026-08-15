import 'package:licoup/src/contracts/agent_usage_models.dart';

/// Maximum calendar days retained in a native usage projection.
const int agentUsageDailyCacheMaxDays = 90;

/// Read-only slice of one immutable native usage report. Flutter does not
/// own or merge a full-report Map.
AgentUsageReport? projectViewport(
  AgentUsageReport? source,
  int targetDays, {
  DateTime? anchor,
}) {
  if (source == null) {
    return null;
  }
  final normalizedDays = targetDays
      .clamp(1, agentUsageDailyCacheMaxDays)
      .toInt();
  final bucketKeys = agentUsageWindowDateKeys(normalizedDays, anchor: anchor);
  final agents = [
    for (final agent in source.agents) _projectAgent(agent, bucketKeys),
  ]..sort((a, b) => a.agentId.compareTo(b.agentId));
  return AgentUsageReport(
    schemaVersion: source.schemaVersion,
    generatedAt: source.generatedAt,
    summary: _summaryFromAgents(agents),
    agents: agents,
    warnings: source.warnings,
    mode: source.mode,
    tokenSourceMode: source.tokenSourceMode,
    window: {'days': normalizedDays},
    workflows: source.workflows,
    workflowSummary: source.workflowSummary,
  );
}

Set<String> agentUsageWindowDateKeys(int dayCount, {DateTime? anchor}) {
  final value = (anchor ?? DateTime.now()).toLocal();
  final today = DateTime(value.year, value.month, value.day);
  return {
    for (var offset = dayCount - 1; offset >= 0; offset -= 1)
      _dateKey(DateTime(today.year, today.month, today.day - offset)),
  };
}

AgentUsageAgentSummary _projectAgent(
  AgentUsageAgentSummary agent,
  Set<String> bucketKeys,
) {
  final entries = _dailySourceEntries(agent.history['dailyUsage']);
  if (entries.isEmpty) {
    return agent;
  }
  final filteredDaily = [
    for (final entry in entries)
      if (bucketKeys.contains(entry.date))
        {'date': entry.date, ..._bucketJson(entry.raw)},
  ];
  return AgentUsageAgentSummary(
    agentId: agent.agentId,
    label: agent.label,
    status: agent.status,
    history: {
      'dailyUsage': filteredDaily,
      ..._aggregateDailyTotals(filteredDaily),
    },
    confidence: agent.confidence,
  );
}

class _DailySourceEntry {
  const _DailySourceEntry({required this.date, required this.raw});

  final String date;
  final Object? raw;
}

List<_DailySourceEntry> _dailySourceEntries(Object? source) {
  if (source == null) {
    return const [];
  }
  if (source is List) {
    return [for (final item in source) ..._dailySourceEntries(item)];
  }
  if (source is Map) {
    final directDate = _sourceDateKey(
      source['date'] ??
          source['day'] ??
          source['bucket'] ??
          source['generatedAt'] ??
          source['time'] ??
          source['timestamp'],
    );
    if (directDate.isNotEmpty) {
      return [_DailySourceEntry(date: directDate, raw: source)];
    }
    final entries = <_DailySourceEntry>[];
    for (final entry in source.entries) {
      final date = _sourceDateKey(entry.key);
      if (date.isEmpty) {
        continue;
      }
      entries.add(_DailySourceEntry(date: date, raw: entry.value));
    }
    return entries;
  }
  return const [];
}

Map<String, Object?> _bucketJson(Object? raw) {
  if (raw is! Map) {
    return const {};
  }
  return {
    'promptTokens': _int(raw['promptTokens']),
    'cachedInputTokens': _int(raw['cachedInputTokens']),
    'completionTokens': _int(raw['completionTokens']),
    'totalTokens': _int(raw['totalTokens']),
    'sessionCount': _int(raw['sessionCount']),
    'messageCount': _int(raw['messageCount']),
    'explicitRecords': _int(raw['explicitRecords']),
    'estimatedRecords': _int(raw['estimatedRecords']),
    if (raw['modelUsage'] != null) 'modelUsage': raw['modelUsage'],
    if (raw['modelTokenUsage'] != null)
      'modelTokenUsage': raw['modelTokenUsage'],
  };
}

String _sourceDateKey(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is DateTime) {
    return _dateKey(value);
  }
  final text = value.toString().trim();
  if (text.isEmpty) {
    return '';
  }
  final parsed = DateTime.tryParse(text);
  if (parsed != null) {
    return _dateKey(parsed.toLocal());
  }
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    return text;
  }
  return '';
}

String _dateKey(DateTime value) {
  final day = DateTime(value.year, value.month, value.day);
  return '${day.year}-${_twoDigits(day.month)}-${_twoDigits(day.day)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

Map<String, dynamic> _aggregateDailyTotals(List<Map<String, Object?>> entries) {
  var promptTokens = 0;
  var cachedInputTokens = 0;
  var completionTokens = 0;
  var totalTokens = 0;
  var sessionCount = 0;
  var messageCount = 0;
  var explicitRecords = 0;
  var estimatedRecords = 0;
  for (final entry in entries) {
    promptTokens += _int(entry['promptTokens']);
    cachedInputTokens += _int(entry['cachedInputTokens']);
    completionTokens += _int(entry['completionTokens']);
    totalTokens += _int(entry['totalTokens']);
    sessionCount += _int(entry['sessionCount']);
    messageCount += _int(entry['messageCount']);
    explicitRecords += _int(entry['explicitRecords']);
    estimatedRecords += _int(entry['estimatedRecords']);
  }
  return {
    'promptTokens': promptTokens,
    'cachedInputTokens': cachedInputTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
    'sessionCount': sessionCount,
    'messageCount': messageCount,
    'explicitRecords': explicitRecords,
    'estimatedRecords': estimatedRecords,
  };
}

Map<String, dynamic> _summaryFromAgents(List<AgentUsageAgentSummary> agents) {
  var agentCount = 0;
  var sessionCount = 0;
  var messageCount = 0;
  var promptTokens = 0;
  var cachedInputTokens = 0;
  var completionTokens = 0;
  var totalTokens = 0;
  for (final agent in agents) {
    if (agent.status != 'pending') {
      agentCount += 1;
    }
    sessionCount += agent.sessionCount;
    messageCount += agent.messageCount;
    promptTokens += agent.promptTokens;
    cachedInputTokens += agent.cachedInputTokens;
    completionTokens += agent.completionTokens;
    totalTokens += agent.totalTokens;
  }
  return {
    'agentCount': agentCount,
    'sessionCount': sessionCount,
    'messageCount': messageCount,
    'promptTokens': promptTokens,
    'cachedInputTokens': cachedInputTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
  };
}

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
