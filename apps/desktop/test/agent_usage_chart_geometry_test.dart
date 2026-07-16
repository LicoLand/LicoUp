import 'package:flutter/widgets.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chart hit testing maps only plot coordinates to bounded snapshots', () {
    const size = Size(354, 178);
    expect(
      agentUsageSnapshotIndexAt(
        position: const Offset(agentUsageChartLeftPadding, 20),
        size: size,
        snapshotCount: 3,
      ),
      0,
    );
    expect(
      agentUsageSnapshotIndexAt(
        position: const Offset(199, 20),
        size: size,
        snapshotCount: 3,
      ),
      1,
    );
    expect(
      agentUsageSnapshotIndexAt(
        position: const Offset(10, 20),
        size: size,
        snapshotCount: 3,
      ),
      isNull,
    );
  });

  test('tooltip placement and axis labels stay inside bounded viewport', () {
    expect(
      agentUsageTooltipOrigin(
        pointer: const Offset(390, 290),
        screenSize: const Size(400, 300),
        tooltipWidth: 240,
        estimatedHeight: 100,
      ),
      const Offset(138, 178),
    );
    expect(agentUsageAxisLabelCandidates(0), isEmpty);
    expect(agentUsageAxisLabelCandidates(1), [0]);
    expect(agentUsageAxisLabelCandidates(5), [0, 4, 2, 1, 3]);
  });
}
