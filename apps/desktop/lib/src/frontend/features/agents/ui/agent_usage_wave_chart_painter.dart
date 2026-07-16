import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_chart_geometry.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

final class AgentUsageWaveChartPainter extends CustomPainter {
  const AgentUsageWaveChartPainter({
    required this.timeline,
    required this.colors,
    required this.hoveredSnapshotIndex,
  });

  final AgentUsageTimelineData timeline;
  final LicoThemeColors colors;
  final int? hoveredSnapshotIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || timeline.isEmpty) return;
    final chartWidth = math.max(
      1.0,
      size.width - agentUsageChartLeftPadding - agentUsageChartRightPadding,
    );
    final chartHeight = math.max(
      1.0,
      size.height - agentUsageChartTopPadding - agentUsageChartBottomPadding,
    );
    final baseline = agentUsageChartTopPadding + chartHeight;
    final maxValue = math.max(1.0, timeline.maxStackTotal);

    _paintGrid(canvas, size, chartHeight, baseline);
    _paintAxisLabel(
      canvas,
      formatCompactAgentUsageNumber(maxValue),
      const Offset(0, agentUsageChartTopPadding - 2),
    );
    _paintAxisLabel(canvas, '0', Offset(0, baseline - 10));

    final xPositions = _xPositions(chartWidth);
    if (xPositions.length == 1) {
      _paintSingleStack(
        canvas,
        xPositions.single,
        baseline,
        chartHeight,
        maxValue,
      );
    } else {
      _paintStackedAreas(
        canvas,
        xPositions: xPositions,
        baseline: baseline,
        chartHeight: chartHeight,
        maxValue: maxValue,
      );
    }
    _paintHoverIndicator(
      canvas,
      xPositions: xPositions,
      baseline: baseline,
      chartHeight: chartHeight,
      maxValue: maxValue,
    );
    _paintXAxisLabels(canvas, size, xPositions, baseline + 8);
  }

  void _paintGrid(
    Canvas canvas,
    Size size,
    double chartHeight,
    double baseline,
  ) {
    final gridPaint = Paint()
      ..color = colors.line.withValues(alpha: 0.42)
      ..strokeWidth = 1;
    final mutedGridPaint = Paint()
      ..color = colors.line.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    for (final fraction in const [0.0, 0.5, 1.0]) {
      final y = baseline - chartHeight * fraction;
      canvas.drawLine(
        Offset(agentUsageChartLeftPadding, y),
        Offset(size.width - agentUsageChartRightPadding, y),
        fraction == 1.0 ? gridPaint : mutedGridPaint,
      );
    }
  }

  List<double> _xPositions(double chartWidth) {
    final snapshots = timeline.snapshots;
    final firstTime = snapshots.first.time;
    final timeSpan = snapshots.last.time.difference(firstTime).inMilliseconds;
    return [
      for (final snapshot in snapshots)
        snapshots.length == 1 || timeSpan <= 0
            ? agentUsageChartLeftPadding + chartWidth / 2
            : agentUsageChartLeftPadding +
                  chartWidth *
                      snapshot.time.difference(firstTime).inMilliseconds /
                      timeSpan,
    ];
  }

  void _paintStackedAreas(
    Canvas canvas, {
    required List<double> xPositions,
    required double baseline,
    required double chartHeight,
    required double maxValue,
  }) {
    final cumulative = List<double>.filled(xPositions.length, 0);
    for (final series in timeline.series) {
      final bottomValues = List<double>.from(cumulative);
      for (var index = 0; index < cumulative.length; index += 1) {
        cumulative[index] +=
            timeline.snapshots[index].values[series.label] ?? 0;
      }
      final bottomOffsets = [
        for (var index = 0; index < bottomValues.length; index += 1)
          Offset(
            xPositions[index],
            baseline - chartHeight * (bottomValues[index] / maxValue),
          ),
      ];
      final topOffsets = [
        for (var index = 0; index < cumulative.length; index += 1)
          Offset(
            xPositions[index],
            baseline - chartHeight * (cumulative[index] / maxValue),
          ),
      ];
      _paintSeriesArea(
        canvas,
        topOffsets: topOffsets,
        bottomOffsets: bottomOffsets,
        color: agentUsageSeriesColor(colors, series.label),
      );
    }
  }

  void _paintHoverIndicator(
    Canvas canvas, {
    required List<double> xPositions,
    required double baseline,
    required double chartHeight,
    required double maxValue,
  }) {
    final index = hoveredSnapshotIndex;
    if (index == null || index < 0 || index >= xPositions.length) return;
    final x = xPositions[index];
    final linePaint = Paint()
      ..color = colors.text.withValues(alpha: 0.64)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var y = agentUsageChartTopPadding; y < baseline; y += 7) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, math.min(y + 3.5, baseline)),
        linePaint,
      );
    }
    final pointY =
        baseline - chartHeight * (timeline.snapshots[index].total / maxValue);
    canvas.drawCircle(
      Offset(x, pointY),
      4.2,
      Paint()
        ..color = colors.surface
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(x, pointY),
      3,
      Paint()
        ..color = colors.text
        ..style = PaintingStyle.fill,
    );
  }

  void _paintSingleStack(
    Canvas canvas,
    double x,
    double baseline,
    double chartHeight,
    double maxValue,
  ) {
    var cumulative = 0.0;
    const width = 32.0;
    for (final series in timeline.series) {
      final value = timeline.snapshots.single.values[series.label] ?? 0;
      if (value <= 0) continue;
      final bottom = baseline - chartHeight * (cumulative / maxValue);
      cumulative += value;
      final top = baseline - chartHeight * (cumulative / maxValue);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x - width / 2, top, x + width / 2, bottom),
        const Radius.circular(8),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = agentUsageSeriesColor(
            colors,
            series.label,
          ).withValues(alpha: 0.72)
          ..style = PaintingStyle.fill,
      );
    }
  }

  void _paintSeriesArea(
    Canvas canvas, {
    required List<Offset> topOffsets,
    required List<Offset> bottomOffsets,
    required Color color,
  }) {
    final areaPath = _smoothPath(topOffsets)
      ..lineTo(bottomOffsets.last.dx, bottomOffsets.last.dy);
    for (var index = bottomOffsets.length - 2; index >= 0; index -= 1) {
      final previous = bottomOffsets[index + 1];
      final current = bottomOffsets[index];
      final controlX = (previous.dx + current.dx) / 2;
      areaPath.cubicTo(
        controlX,
        previous.dy,
        controlX,
        current.dy,
        current.dx,
        current.dy,
      );
    }
    areaPath.close();
    canvas.drawPath(
      areaPath,
      Paint()
        ..color = color.withValues(alpha: 0.38)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      _smoothPath(topOffsets),
      Paint()
        ..color = color.withValues(alpha: 0.92)
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  Path _smoothPath(List<Offset> offsets) {
    final path = Path()..moveTo(offsets.first.dx, offsets.first.dy);
    for (var index = 1; index < offsets.length; index += 1) {
      final previous = offsets[index - 1];
      final current = offsets[index];
      final controlX = (previous.dx + current.dx) / 2;
      path.cubicTo(
        controlX,
        previous.dy,
        controlX,
        current.dy,
        current.dx,
        current.dy,
      );
    }
    return path;
  }

  void _paintAxisLabel(Canvas canvas, String label, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 40);
    painter.paint(canvas, offset);
  }

  void _paintXAxisLabels(
    Canvas canvas,
    Size size,
    List<double> xPositions,
    double y,
  ) {
    final painted = <Rect>[];
    for (final index in agentUsageAxisLabelCandidates(xPositions.length)) {
      final label = formatAgentUsageTimeLabel(timeline.snapshots[index].time);
      final painter = _xAxisLabelPainter(label)..layout(maxWidth: 88);
      final maxLeft = math.max(0.0, size.width - painter.width);
      final left = (xPositions[index] - painter.width / 2)
          .clamp(0.0, maxLeft)
          .toDouble();
      final rect = Rect.fromLTWH(left, y, painter.width, painter.height);
      if (painted.any((existing) => existing.inflate(10).overlaps(rect))) {
        continue;
      }
      painter.paint(canvas, rect.topLeft);
      painted.add(rect);
    }
  }

  TextPainter _xAxisLabelPainter(String label) {
    return TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
  }

  @override
  bool shouldRepaint(covariant AgentUsageWaveChartPainter oldDelegate) {
    return oldDelegate.timeline != timeline ||
        oldDelegate.colors != colors ||
        oldDelegate.hoveredSnapshotIndex != hoveredSnapshotIndex;
  }
}
