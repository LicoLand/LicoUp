import 'dart:collection';

import 'package:licoup/src/contracts/agent_usage_models.dart';

/// Maximum calendar days retained in the long-lived daily cache.
const int agentUsageDailyCacheMaxDays = 90;

/// Persistent in-memory day-grain usage store. Historical days are stable;
/// [projectViewport] is the only path for 7/30/90 display windows.
final class AgentUsageDailyCache {
  AgentUsageDailyCache();

  final Map<String, _AgentDailySeries> _agents = <String, _AgentDailySeries>{};
  String? _lastIngestedAt;
  int _ingestedWindowDays = 0;
  List<AgentUsageWorkflow> _workflows = const [];
  AgentUsageTokenTotals _workflowSummary = const AgentUsageTokenTotals();

  bool get isEmpty => _agents.isEmpty;

  int get ingestedWindowDays => _ingestedWindowDays;

  String? get lastIngestedAt => _lastIngestedAt;

  /// Workflow usage is already bounded and rolled up by the native ledger.
  /// Keep the newest projection alongside the day cache without creating a
  /// second store or re-attributing any token values in Dart.
  List<AgentUsageWorkflow> get workflows => _workflows;

  AgentUsageTokenTotals get workflowSummary => _workflowSummary;

  bool hasFullCoverage() {
    return !isEmpty &&
        _ingestedWindowDays >= agentUsageDailyCacheMaxDays &&
        _agents.values.every(
          (series) => series.days.isNotEmpty || !series.hasAggregateFallback,
        );
  }

  bool hasFreshIngest({
    DateTime? now,
    Duration maxAge = const Duration(hours: 1),
  }) {
    final generated = DateTime.tryParse(_lastIngestedAt ?? '')?.toUtc();
    if (generated == null) {
      return false;
    }
    final age = (now ?? DateTime.now()).toUtc().difference(generated);
    return !age.isNegative && age <= maxAge;
  }

  bool hasFreshToday({
    DateTime? now,
    Duration maxAge = const Duration(hours: 1),
  }) {
    if (!hasFreshIngest(now: now, maxAge: maxAge)) {
      return false;
    }
    if (!hasDailyBreakdown) {
      return true;
    }
    final today = agentUsageWindowDateKeys(1, anchor: now).single;
    return _agents.values.any((series) => series.days.containsKey(today));
  }

  bool get hasDailyBreakdown =>
      _agents.values.any((series) => series.days.isNotEmpty);

  void clear() {
    _agents.clear();
    _lastIngestedAt = null;
    _ingestedWindowDays = 0;
    _workflows = const [];
    _workflowSummary = const AgentUsageTokenTotals();
  }

  /// Replaces the cache when [replace] is true; otherwise merges day buckets.
  void ingestReport(AgentUsageReport report, {bool replace = false}) {
    if (replace) {
      clear();
    }
    _mergeReport(report);
    _trimToMaxDays();
  }

  /// Merges retained reports oldest-first so newer day buckets win overlaps.
  void ingestReports(
    Iterable<AgentUsageReport> reports, {
    bool replace = false,
  }) {
    if (replace) {
      clear();
    }
    final sorted = reports.toList()
      ..sort((a, b) {
        final aTime = DateTime.tryParse(a.generatedAt)?.toUtc();
        final bTime = DateTime.tryParse(b.generatedAt)?.toUtc();
        if (aTime == null && bTime == null) {
          return 0;
        }
        if (aTime == null) {
          return -1;
        }
        if (bTime == null) {
          return 1;
        }
        return aTime.compareTo(bTime);
      });
    for (final report in sorted) {
      _mergeReport(report);
    }
    _trimToMaxDays();
  }

  /// Merges only the days present in [report], replacing overlapping buckets.
  void mergeReport(AgentUsageReport report) {
    ingestReport(report);
  }

  void _mergeReport(AgentUsageReport report) {
    final isNewer = _isNewerGeneratedAt(report.generatedAt, _lastIngestedAt);
    if (isNewer) {
      _lastIngestedAt = report.generatedAt;
      _workflows = List.unmodifiable(report.workflows);
      _workflowSummary = report.workflowSummary;
    }
    _ingestedWindowDays = _ingestedWindowDays < report.windowDays
        ? report.windowDays
        : _ingestedWindowDays;
    for (final agent in report.agents) {
      final series = _agents.putIfAbsent(
        agent.agentId,
        () => _AgentDailySeries(
          agentId: agent.agentId,
          label: agent.label,
          status: agent.status,
          confidence: agent.confidence,
        ),
      );
      series.ingest(agent);
    }
  }

  AgentUsageReport? projectViewport(int targetDays, {DateTime? anchor}) {
    if (isEmpty) {
      return null;
    }
    final normalizedDays = targetDays
        .clamp(1, agentUsageDailyCacheMaxDays)
        .toInt();
    final bucketKeys = agentUsageWindowDateKeys(normalizedDays, anchor: anchor);
    final agents = [
      for (final series in _agents.values) series.project(bucketKeys),
    ]..sort((a, b) => a.agentId.compareTo(b.agentId));
    return AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: _lastIngestedAt ?? DateTime.now().toUtc().toIso8601String(),
      summary: _summaryFromAgents(agents),
      agents: agents,
      warnings: const [],
      mode: AgentUsageReport.currentMode,
      tokenSourceMode: AgentUsageReport.currentTokenSourceMode,
      window: {'days': normalizedDays},
      workflows: _workflows,
      workflowSummary: _workflowSummary,
    );
  }

  void _trimToMaxDays({DateTime? anchor}) {
    final keepKeys = agentUsageWindowDateKeys(
      agentUsageDailyCacheMaxDays,
      anchor: anchor,
    );
    for (final series in _agents.values) {
      series.days.removeWhere((date, _) => !keepKeys.contains(date));
    }
  }
}

final class AgentDailyBucket {
  const AgentDailyBucket({
    this.promptTokens = 0,
    this.cachedInputTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.sessionCount = 0,
    this.messageCount = 0,
    this.explicitRecords = 0,
    this.estimatedRecords = 0,
    this.modelUsage = const {},
    this.modelTokenUsage = const {},
  });

  final int promptTokens;
  final int cachedInputTokens;
  final int completionTokens;
  final int totalTokens;
  final int sessionCount;
  final int messageCount;
  final int explicitRecords;
  final int estimatedRecords;
  final Map<String, num> modelUsage;
  final Map<String, Map<String, dynamic>> modelTokenUsage;

  factory AgentDailyBucket.fromRaw(Object? raw) {
    if (raw is! Map) {
      return const AgentDailyBucket();
    }
    return AgentDailyBucket(
      promptTokens: _int(raw['promptTokens']),
      cachedInputTokens: _int(raw['cachedInputTokens']),
      completionTokens: _int(raw['completionTokens']),
      totalTokens: _int(raw['totalTokens']),
      sessionCount: _int(raw['sessionCount']),
      messageCount: _int(raw['messageCount']),
      explicitRecords: _int(raw['explicitRecords']),
      estimatedRecords: _int(raw['estimatedRecords']),
      modelUsage: _modelUsageMap(raw['modelUsage']),
      modelTokenUsage: _modelTokenUsageMap(raw['modelTokenUsage']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'promptTokens': promptTokens,
      'cachedInputTokens': cachedInputTokens,
      'completionTokens': completionTokens,
      'totalTokens': totalTokens,
      'sessionCount': sessionCount,
      'messageCount': messageCount,
      'explicitRecords': explicitRecords,
      'estimatedRecords': estimatedRecords,
      if (modelUsage.isNotEmpty) 'modelUsage': modelUsage,
      if (modelTokenUsage.isNotEmpty) 'modelTokenUsage': modelTokenUsage,
    };
  }

  AgentDailyBucket merge(AgentDailyBucket other) {
    final mergedModelUsage = Map<String, num>.from(modelUsage);
    _mergeModelUsage(mergedModelUsage, other.modelUsage);
    final mergedModelTokenUsage = {
      for (final entry in modelTokenUsage.entries)
        entry.key: Map<String, dynamic>.from(entry.value),
    };
    _mergeModelTokenUsage(mergedModelTokenUsage, other.modelTokenUsage);
    return AgentDailyBucket(
      promptTokens: promptTokens + other.promptTokens,
      cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
      completionTokens: completionTokens + other.completionTokens,
      totalTokens: totalTokens + other.totalTokens,
      sessionCount: sessionCount + other.sessionCount,
      messageCount: messageCount + other.messageCount,
      explicitRecords: explicitRecords + other.explicitRecords,
      estimatedRecords: estimatedRecords + other.estimatedRecords,
      modelUsage: mergedModelUsage,
      modelTokenUsage: mergedModelTokenUsage,
    );
  }
}

final class _AgentDailySeries {
  _AgentDailySeries({
    required this.agentId,
    required this.label,
    required this.status,
    required this.confidence,
  });

  final String agentId;
  String label;
  String status;
  String confidence;
  final SplayTreeMap<String, AgentDailyBucket> days = SplayTreeMap();
  Map<String, dynamic> _aggregateFallback = const {};
  var _hadDailyBuckets = false;

  bool get hasAggregateFallback =>
      _aggregateFallback.isNotEmpty && !_hadDailyBuckets;

  void ingest(AgentUsageAgentSummary agent) {
    label = agent.label;
    status = agent.status;
    confidence = agent.confidence;
    final entries = _dailySourceEntries(agent.history['dailyUsage']);
    for (final entry in entries) {
      days[entry.date] = AgentDailyBucket.fromRaw(entry.raw);
    }
    if (entries.isNotEmpty) {
      _hadDailyBuckets = true;
      _aggregateFallback = const {};
      return;
    }
    if (!_hadDailyBuckets &&
        (agent.totalTokens > 0 ||
            agent.sessionCount > 0 ||
            agent.messageCount > 0)) {
      _aggregateFallback = {
        'totalTokens': agent.totalTokens,
        'promptTokens': agent.promptTokens,
        'cachedInputTokens': agent.cachedInputTokens,
        'completionTokens': agent.completionTokens,
        'sessionCount': agent.sessionCount,
        'messageCount': agent.messageCount,
        if (agent.history['modelUsage'] != null)
          'modelUsage': agent.history['modelUsage'],
        if (agent.history['modelTokenUsage'] != null)
          'modelTokenUsage': agent.history['modelTokenUsage'],
      };
    }
  }

  AgentUsageAgentSummary project(Set<String> bucketKeys) {
    final filteredDaily = [
      for (final date in bucketKeys)
        if (days.containsKey(date)) {'date': date, ...days[date]!.toJson()},
    ];
    if (filteredDaily.isNotEmpty) {
      return AgentUsageAgentSummary(
        agentId: agentId,
        label: label,
        status: status,
        history: {
          'dailyUsage': filteredDaily,
          ..._aggregateDailyTotals(filteredDaily),
        },
        confidence: confidence,
      );
    }
    if (_aggregateFallback.isNotEmpty && !_hadDailyBuckets) {
      return AgentUsageAgentSummary(
        agentId: agentId,
        label: label,
        status: status,
        history: Map<String, dynamic>.from(_aggregateFallback),
        confidence: confidence,
      );
    }
    return AgentUsageAgentSummary(
      agentId: agentId,
      label: label,
      status: status,
      history: const {
        'totalTokens': 0,
        'promptTokens': 0,
        'cachedInputTokens': 0,
        'completionTokens': 0,
        'sessionCount': 0,
        'messageCount': 0,
      },
      confidence: confidence,
    );
  }
}

Set<String> agentUsageWindowDateKeys(int dayCount, {DateTime? anchor}) {
  final value = (anchor ?? DateTime.now()).toLocal();
  final today = DateTime(value.year, value.month, value.day);
  return {
    for (var offset = dayCount - 1; offset >= 0; offset -= 1)
      _dateKey(DateTime(today.year, today.month, today.day - offset)),
  };
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

bool _isNewerGeneratedAt(String candidate, String? baseline) {
  if (baseline == null || baseline.isEmpty) {
    return true;
  }
  final candidateTime = DateTime.tryParse(candidate)?.toUtc();
  final baselineTime = DateTime.tryParse(baseline)?.toUtc();
  if (candidateTime == null || baselineTime == null) {
    return false;
  }
  return candidateTime.isAfter(baselineTime);
}

Map<String, dynamic> _aggregateDailyTotals(List<Map<String, Object?>> entries) {
  var promptTokens = 0;
  var cachedInputTokens = 0;
  var completionTokens = 0;
  var totalTokens = 0;
  var sessionCount = 0;
  var messageCount = 0;
  var explicitRecords = 0;
  var estimatedRecords = 0;
  final modelUsage = <String, num>{};
  final modelTokenUsage = <String, Map<String, dynamic>>{};

  for (final entry in entries) {
    promptTokens += _int(entry['promptTokens']);
    cachedInputTokens += _int(entry['cachedInputTokens']);
    completionTokens += _int(entry['completionTokens']);
    totalTokens += _int(entry['totalTokens']);
    sessionCount += _int(entry['sessionCount']);
    messageCount += _int(entry['messageCount']);
    explicitRecords += _int(entry['explicitRecords']);
    estimatedRecords += _int(entry['estimatedRecords']);
    _mergeModelUsage(modelUsage, entry['modelUsage']);
    _mergeModelTokenUsage(modelTokenUsage, entry['modelTokenUsage']);
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
    if (modelUsage.isNotEmpty) 'modelUsage': modelUsage,
    if (modelTokenUsage.isNotEmpty) 'modelTokenUsage': modelTokenUsage,
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
    'confidence': _tokenConfidence(agents),
  };
}

String _tokenConfidence(List<AgentUsageAgentSummary> agents) {
  final hasHigh = agents.any((agent) => agent.confidence == 'high');
  final hasMedium = agents.any((agent) => agent.confidence == 'medium');
  final hasLow = agents.any((agent) => agent.confidence == 'low');
  if (hasMedium || (hasHigh && hasLow)) {
    return 'medium';
  }
  if (hasHigh) {
    return 'high';
  }
  if (hasLow) {
    return 'low';
  }
  return '';
}

void _mergeModelUsage(Map<String, num> target, Object? source) {
  if (source is Map) {
    for (final entry in source.entries) {
      final model = entry.key.toString().trim();
      if (model.isEmpty) {
        continue;
      }
      target.update(
        model,
        (value) => value + _num(entry.value),
        ifAbsent: () => _num(entry.value),
      );
    }
    return;
  }
  if (source is List) {
    for (final item in source) {
      if (item is! Map) {
        continue;
      }
      final model = (item['model'] ?? item['name'] ?? item['id'] ?? '')
          .toString()
          .trim();
      if (model.isEmpty) {
        continue;
      }
      final tokens = _num(
        item['totalTokens'] ?? item['tokens'] ?? item['value'] ?? item['count'],
      );
      target.update(model, (value) => value + tokens, ifAbsent: () => tokens);
    }
  }
}

Map<String, num> _modelUsageMap(Object? source) {
  final target = <String, num>{};
  _mergeModelUsage(target, source);
  return Map.unmodifiable(target);
}

void _mergeModelTokenUsage(
  Map<String, Map<String, dynamic>> target,
  Object? source,
) {
  if (source is! Map) {
    return;
  }
  for (final entry in source.entries) {
    final model = entry.key.toString().trim();
    if (model.isEmpty || entry.value is! Map) {
      continue;
    }
    final value = Map<String, dynamic>.from(entry.value as Map);
    final existing = target[model];
    if (existing == null) {
      target[model] = {
        'promptTokens': _int(value['promptTokens']),
        'cachedInputTokens': _int(value['cachedInputTokens']),
        'completionTokens': _int(value['completionTokens']),
        'totalTokens': _int(value['totalTokens']),
      };
      continue;
    }
    target[model] = {
      'promptTokens':
          _int(existing['promptTokens']) + _int(value['promptTokens']),
      'cachedInputTokens':
          _int(existing['cachedInputTokens']) +
          _int(value['cachedInputTokens']),
      'completionTokens':
          _int(existing['completionTokens']) + _int(value['completionTokens']),
      'totalTokens': _int(existing['totalTokens']) + _int(value['totalTokens']),
    };
  }
}

Map<String, Map<String, dynamic>> _modelTokenUsageMap(Object? source) {
  final target = <String, Map<String, dynamic>>{};
  _mergeModelTokenUsage(target, source);
  return Map.unmodifiable(
    target.map((key, value) => MapEntry(key, Map<String, dynamic>.from(value))),
  );
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

num _num(Object? value) {
  if (value is num) {
    return value;
  }
  return num.tryParse(value?.toString() ?? '') ?? 0;
}
