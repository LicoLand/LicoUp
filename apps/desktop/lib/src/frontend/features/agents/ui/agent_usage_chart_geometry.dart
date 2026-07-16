import 'dart:math' as math;

import 'package:flutter/widgets.dart';

const double agentUsageChartHeight = 178;
const double agentUsageChartLeftPadding = 44;
const double agentUsageChartRightPadding = 10;
const double agentUsageChartTopPadding = 8;
const double agentUsageChartBottomPadding = 28;

int? agentUsageSnapshotIndexAt({
  required Offset position,
  required Size size,
  required int snapshotCount,
}) {
  if (snapshotCount <= 0) return null;
  final plotRight = size.width - agentUsageChartRightPadding;
  final plotBottom = size.height - agentUsageChartBottomPadding;
  if (position.dx < agentUsageChartLeftPadding ||
      position.dx > plotRight ||
      position.dy < agentUsageChartTopPadding ||
      position.dy > plotBottom) {
    return null;
  }
  if (snapshotCount == 1) return 0;
  final chartWidth = math.max(
    1.0,
    size.width - agentUsageChartLeftPadding - agentUsageChartRightPadding,
  );
  return (((position.dx - agentUsageChartLeftPadding) / chartWidth) *
          (snapshotCount - 1))
      .round()
      .clamp(0, snapshotCount - 1);
}

Offset agentUsageTooltipOrigin({
  required Offset pointer,
  required Size screenSize,
  required double tooltipWidth,
  required double estimatedHeight,
  double gap = 12,
  double viewportPadding = 8,
}) {
  var left = pointer.dx + gap;
  if (left + tooltipWidth > screenSize.width - viewportPadding) {
    left = pointer.dx - tooltipWidth - gap;
  }
  left = left
      .clamp(
        viewportPadding,
        math.max(
          viewportPadding,
          screenSize.width - tooltipWidth - viewportPadding,
        ),
      )
      .toDouble();
  var top = pointer.dy + gap;
  if (top + estimatedHeight > screenSize.height - viewportPadding) {
    top = pointer.dy - estimatedHeight - gap;
  }
  top = top
      .clamp(
        viewportPadding,
        math.max(
          viewportPadding,
          screenSize.height - estimatedHeight - viewportPadding,
        ),
      )
      .toDouble();
  return Offset(left, top);
}

List<int> agentUsageAxisLabelCandidates(int count) {
  if (count <= 0) return const [];
  if (count == 1) return const [0];
  final ordered = <int>[];
  void add(int index) {
    final clamped = index.clamp(0, count - 1);
    if (!ordered.contains(clamped)) ordered.add(clamped);
  }

  add(0);
  add(count - 1);
  add(((count - 1) * 0.5).round());
  add(((count - 1) * 0.25).round());
  add(((count - 1) * 0.75).round());
  if (count <= 8) {
    for (var index = 0; index < count; index += 1) {
      add(index);
    }
  }
  return List<int>.unmodifiable(ordered);
}
