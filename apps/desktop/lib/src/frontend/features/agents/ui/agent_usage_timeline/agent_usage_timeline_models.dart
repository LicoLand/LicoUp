import 'dart:math' as math;

enum AgentUsageChartGrouping { agent, model, workflow }

const int agentUsageWaveSeriesLimit = 10;
const int agentUsageShareSeriesLimit = 15;
const String agentUsageOverflowSeriesLabel = 'Others';

class AgentUsageTimelineData {
  const AgentUsageTimelineData({
    required this.snapshots,
    required this.series,
    required this.seriesTotals,
    required this.shareSeriesLabels,
    required this.groupTotal,
    required this.hasDailyBreakdown,
  });

  final List<AgentUsageSnapshot> snapshots;
  final List<AgentUsageSeries> series;
  final Map<String, double> seriesTotals;
  final List<String> shareSeriesLabels;
  final double groupTotal;
  final bool hasDailyBreakdown;

  bool get isEmpty =>
      snapshots.isEmpty ||
      series.isEmpty ||
      snapshots.every((snapshot) => snapshot.total <= 0);

  double get maxStackTotal => snapshots.fold<double>(
    0,
    (maxValue, snapshot) => math.max(maxValue, snapshot.total),
  );

  double totalFor(String label) => seriesTotals[label] ?? 0;

  double shareTotalFor(String label) {
    if (label != agentUsageOverflowSeriesLabel) {
      return totalFor(label);
    }
    final visible = shareSeriesLabels.toSet()
      ..remove(agentUsageOverflowSeriesLabel);
    return seriesTotals.entries
        .where((entry) => !visible.contains(entry.key))
        .fold<double>(0, (sum, entry) => sum + entry.value);
  }
}

List<String> agentUsageRankedShareLabels(
  Map<String, double> totals, {
  int maxNamed = agentUsageShareSeriesLimit,
}) {
  final ranked = totals.entries.toList()
    ..sort((a, b) {
      final byTokens = b.value.compareTo(a.value);
      return byTokens != 0 ? byTokens : a.key.compareTo(b.key);
    });
  if (ranked.isEmpty) {
    return const [];
  }
  if (ranked.length <= maxNamed) {
    return [for (final entry in ranked) entry.key];
  }
  final visible = [for (final entry in ranked.take(maxNamed - 1)) entry.key];
  final remainder = ranked
      .skip(maxNamed - 1)
      .fold<double>(0, (sum, entry) => sum + entry.value);
  if (remainder > 0) {
    visible.add(agentUsageOverflowSeriesLabel);
  }
  return visible;
}

class AgentUsageSnapshot {
  const AgentUsageSnapshot({required this.time, required this.values});

  final DateTime time;
  final Map<String, double> values;

  double get total =>
      values.values.fold<double>(0, (sum, value) => sum + value);
}

class AgentUsageSeries {
  const AgentUsageSeries({required this.label});

  final String label;
}
