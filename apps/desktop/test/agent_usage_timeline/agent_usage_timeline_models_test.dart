import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_models.dart';
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
      shareSeriesLabels: ['Codex', 'Claude'],
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
      shareSeriesLabels: [],
      groupTotal: 0,
      hasDailyBreakdown: false,
    );
    expect(empty.isEmpty, isTrue);
  });

  test('share labels keep significant models and overflow the long tail', () {
    final totals = {
      for (var index = 0; index < 16; index += 1)
        'Model ${String.fromCharCode(65 + index)}': (16 - index).toDouble(),
    };

    final labels = agentUsageRankedShareLabels(totals);

    expect(labels, hasLength(agentUsageShareSeriesLimit));
    expect(labels.first, 'Model A');
    expect(labels[13], 'Model N');
    expect(labels.last, agentUsageOverflowSeriesLabel);
  });

  test('share totals aggregate overflow into Others', () {
    const timeline = AgentUsageTimelineData(
      snapshots: [],
      series: [],
      seriesTotals: {
        'Grok 4.5': 100,
        'Composer 2.5': 40,
        'Tail A': 3,
        'Tail B': 2,
      },
      shareSeriesLabels: ['Grok 4.5', 'Composer 2.5', agentUsageOverflowSeriesLabel],
      groupTotal: 145,
      hasDailyBreakdown: true,
    );

    expect(timeline.shareTotalFor('Grok 4.5'), 100);
    expect(timeline.shareTotalFor(agentUsageOverflowSeriesLabel), 5);
  });
}
