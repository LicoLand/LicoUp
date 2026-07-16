import 'dart:math' as math;

enum AgentUsageChartGrouping { agent, model }

class AgentUsageTimelineData {
  const AgentUsageTimelineData({
    required this.snapshots,
    required this.series,
    required this.seriesTotals,
    required this.groupTotal,
    required this.hasDailyBreakdown,
  });

  final List<AgentUsageSnapshot> snapshots;
  final List<AgentUsageSeries> series;
  final Map<String, double> seriesTotals;
  final double groupTotal;
  final bool hasDailyBreakdown;

  bool get isEmpty {
    return snapshots.isEmpty ||
        series.isEmpty ||
        snapshots.every((snapshot) => snapshot.total <= 0);
  }

  double get maxStackTotal {
    var maxValue = 0.0;
    for (final snapshot in snapshots) {
      maxValue = math.max(maxValue, snapshot.total);
    }
    return maxValue;
  }

  double totalFor(String label) => seriesTotals[label] ?? 0;
}

class AgentUsageSnapshot {
  const AgentUsageSnapshot({required this.time, required this.values});

  final DateTime time;
  final Map<String, double> values;

  double get total {
    var total = 0.0;
    for (final value in values.values) {
      total += value;
    }
    return total;
  }
}

class AgentUsageSeries {
  const AgentUsageSeries({required this.label});

  final String label;
}
