import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('timeline models expose bounded totals and empty state', () {
    final timeline = AgentUsageTimelineData(
      snapshots: [
        AgentUsageSnapshot(
          time: DateTime.utc(2026, 7, 14),
          values: const {'Codex': 3, 'Claude': 2},
        ),
        AgentUsageSnapshot(
          time: DateTime.utc(2026, 7, 15),
          values: const {'Codex': 7},
        ),
      ],
      series: const [
        AgentUsageSeries(label: 'Codex'),
        AgentUsageSeries(label: 'Claude'),
      ],
      seriesTotals: const {'Codex': 10, 'Claude': 2},
      groupTotal: 12,
      hasDailyBreakdown: true,
    );

    expect(timeline.isEmpty, isFalse);
    expect(timeline.maxStackTotal, 7);
    expect(timeline.totalFor('Codex'), 10);
    expect(timeline.totalFor('Missing'), 0);
    expect(timeline.snapshots.first.total, 5);

    const empty = AgentUsageTimelineData(
      snapshots: [],
      series: [],
      seriesTotals: {},
      groupTotal: 0,
      hasDailyBreakdown: false,
    );
    expect(empty.isEmpty, isTrue);
  });
}
