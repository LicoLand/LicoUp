import 'package:flutter_client/src/contracts/agent_usage_models.dart';

import 'agent_usage_display_names.dart';
import 'agent_usage_source_parser.dart';
import 'agent_usage_timeline_models.dart';
import 'agent_usage_token_breakdown.dart';
import 'agent_usage_visibility_policy.dart';

const int agentUsageTimelineDayCount = 30;

AgentUsageTimelineData buildAgentUsageTimelineData(
  AgentUsageReport report,
  AgentUsageChartGrouping grouping,
  Set<String> detectedAgentIds, {
  DateTime? anchor,
}) {
  final bucketDates = _recentDayBuckets(anchor: anchor);
  final bucketKeys = bucketDates.map(agentUsageDateKey).toSet();
  final valuesByDay = {for (final key in bucketKeys) key: <String, double>{}};
  final modelShareTotals = <String, double>{};

  void addModelShare(String model, AgentUsageModelTokens usage) {
    final label = agentUsageModelDisplayName(model);
    _addUsageValue(modelShareTotals, label, usage.totalTokens);
  }

  var hasDailyBreakdown = false;
  for (final agent in report.agents) {
    if (!shouldShowAgentUsage(agent, detectedAgentIds)) {
      continue;
    }
    final dailyUsage = agent.history['dailyUsage'];
    hasDailyBreakdown =
        hasDailyBreakdown || dailyUsage is List || dailyUsage is Map;
    final dailyEntries = _dailyUsageEntries(dailyUsage);
    if (dailyEntries.isEmpty) {
      if (grouping == AgentUsageChartGrouping.model) {
        for (final model in agentUsageModelUsageMap(agent.history).entries) {
          addModelShare(model.key, model.value);
        }
      }
      continue;
    }
    for (final entry in dailyEntries) {
      final date = entry.date;
      if (!bucketKeys.contains(date)) {
        continue;
      }
      switch (grouping) {
        case AgentUsageChartGrouping.agent:
          final label = agentUsageAgentDisplayName(agent);
          _addUsageValue(valuesByDay[date]!, label, entry.totalTokens);
        case AgentUsageChartGrouping.model:
          for (final model in entry.modelUsage.entries) {
            final label = agentUsageModelDisplayName(model.key);
            _addUsageValue(valuesByDay[date]!, label, model.value.totalTokens);
            addModelShare(model.key, model.value);
          }
      }
    }
  }

  if (grouping == AgentUsageChartGrouping.model && modelShareTotals.isEmpty) {
    for (final model in agentUsageModelUsageMap(report.summary).entries) {
      addModelShare(model.key, model.value);
    }
  }

  final rawSnapshots = [
    for (final day in bucketDates)
      AgentUsageSnapshot(
        time: day,
        values: valuesByDay[agentUsageDateKey(day)] ?? const {},
      ),
  ];
  final totals = <String, double>{};
  for (final snapshot in rawSnapshots) {
    for (final entry in snapshot.values.entries) {
      totals.update(
        entry.key,
        (value) => value + entry.value,
        ifAbsent: () => entry.value,
      );
    }
  }
  final shareTotals = grouping == AgentUsageChartGrouping.model
      ? modelShareTotals
      : totals;
  final seriesLabels = shareTotals.entries.toList()
    ..sort((a, b) {
      final byTokens = b.value.compareTo(a.value);
      return byTokens != 0 ? byTokens : a.key.compareTo(b.key);
    });
  final visibleLabels = [for (final entry in seriesLabels.take(10)) entry.key];
  final visibleLabelSet = visibleLabels.toSet();
  final snapshots = [
    for (final snapshot in rawSnapshots)
      AgentUsageSnapshot(
        time: snapshot.time,
        values: {
          for (final entry in snapshot.values.entries)
            if (visibleLabelSet.contains(entry.key)) entry.key: entry.value,
        },
      ),
  ];
  return AgentUsageTimelineData(
    snapshots: snapshots,
    series: [for (final label in visibleLabels) AgentUsageSeries(label: label)],
    seriesTotals: Map.unmodifiable(shareTotals),
    groupTotal: shareTotals.values.fold<double>(0, (sum, value) => sum + value),
    hasDailyBreakdown: hasDailyBreakdown,
  );
}

class _DailyUsageEntry {
  const _DailyUsageEntry({
    required this.date,
    required this.totalTokens,
    required this.modelUsage,
    required this.breakdown,
    required this.hasEstimatedRecords,
  });

  final String date;
  final double totalTokens;
  final Map<String, AgentUsageModelTokens> modelUsage;
  final AgentUsageTokenBreakdown breakdown;
  final bool hasEstimatedRecords;
}

List<DateTime> _recentDayBuckets({DateTime? anchor}) {
  final value = (anchor ?? DateTime.now()).toLocal();
  final today = DateTime(value.year, value.month, value.day);
  return [
    for (var offset = agentUsageTimelineDayCount - 1; offset >= 0; offset -= 1)
      DateTime(today.year, today.month, today.day - offset),
  ];
}

void _addUsageValue(Map<String, double> values, String label, num tokens) {
  final normalized = label.trim();
  if (normalized.isEmpty || tokens <= 0) {
    return;
  }
  values.update(
    normalized,
    (value) => value + tokens.toDouble(),
    ifAbsent: () => tokens.toDouble(),
  );
}

List<_DailyUsageEntry> _dailyUsageEntries(Object? source) {
  return mapAgentUsageDailySource(source, _dailyUsageEntryFromValue);
}

_DailyUsageEntry? _dailyUsageEntryFromValue(String date, Object? value) {
  final modelUsage = agentUsageModelUsageMap(value);
  var totalTokens = agentUsageTokensFromSource(value);
  if (totalTokens <= 0 && modelUsage.isNotEmpty) {
    totalTokens = modelUsage.values.fold<double>(
      0,
      (sum, item) => sum + item.totalTokens,
    );
  }
  if (totalTokens <= 0 && modelUsage.isEmpty) {
    return null;
  }
  final breakdown = agentUsageTokenBreakdown(value, totalTokens: totalTokens);
  if (modelUsage.length == 1 && breakdown.isExact) {
    final entry = modelUsage.entries.single;
    if (!entry.value.breakdown.isExact &&
        (entry.value.totalTokens - totalTokens).abs() <= 0.5) {
      modelUsage[entry.key] = entry.value.withBreakdown(breakdown);
    }
  }
  return _DailyUsageEntry(
    date: date,
    totalTokens: totalTokens,
    modelUsage: Map.unmodifiable(modelUsage),
    breakdown: breakdown,
    hasEstimatedRecords:
        value is Map &&
        agentUsageTokensFromSource(
              value['estimatedRecords'] ?? value['estimated_records'],
            ) >
            0,
  );
}
