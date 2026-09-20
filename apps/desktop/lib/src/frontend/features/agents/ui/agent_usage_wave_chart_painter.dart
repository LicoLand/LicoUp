import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_usage_chart_geometry.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class AgentUsageWaveChartPainter extends CustomPainter {
  const AgentUsageWaveChartPainter({
    required this.timeline,
    required this.colors,
    required this.hoveredSnapshotIndex,
    required this.labelStyle,
  });

  /// Clearance between the axis labels and the plot's left edge.
  static const double _gutterGap = 8;
  static const double _hairline = 0.5;
  static const double _edgeStrokeWidth = 1;
  static const List<double> _gridFractions = [1 / 3, 2 / 3, 1];
  static const List<double> _valueFractions = [1, 2 / 3, 1 / 3, 0];
  static const double _barWidth = 32;
  static const double _barGap = 1;
  static const double _markerRadius = 1.75;
  static const double _markerHaloWidth = 1.5;

  final AgentUsageTimelineData timeline;
  final LicoThemeColors colors;
  final int? hoveredSnapshotIndex;
  final TextStyle labelStyle;

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
    _paintValueLabels(canvas, chartHeight, baseline, maxValue);

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

  /// Half-pixel alignment. A 0.5px stroke then covers one device pixel at 2x
  /// and a single half-intensity row at 1x, instead of smearing across two
  /// rows at half strength.
  static double _hairlineCenter(double value) => value.floorToDouble() + 0.25;

  /// Integer alignment, so a 1px stroke covers one row exactly.
  static double _lineCenter(double value) => value.floorToDouble() + 0.5;

  /// Four horizontal lines — zero, both thirds and the axis maximum — with
  /// the zero baseline emphasized. Everything else is a hairline so the fills
  /// stay the loudest element in the frame.
  void _paintGrid(
    Canvas canvas,
    Size size,
    double chartHeight,
    double baseline,
  ) {
    final left = agentUsageChartLeftPadding;
    final right = size.width - agentUsageChartRightPadding;
    final gridPaint = Paint()
      ..color = colors.line.withValues(alpha: 0.28)
      ..strokeWidth = _hairline;
    for (final fraction in _gridFractions) {
      final y = _hairlineCenter(baseline - chartHeight * fraction);
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);
    }
    final zero = _lineCenter(baseline);
    canvas.drawLine(
      Offset(left, zero),
      Offset(right, zero),
      Paint()
        ..color = colors.lineStrong.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );
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

  /// Stacked areas are drawn bottom-up, fills first and separation edges
  /// second, so a lower series' edge is not overpainted by the fill stacked
  /// directly above it. Fills are translucent vertical gradients and every
  /// band owns a crisp luminous top edge: depth comes from light, not from
  /// opaque pastel masses.
  void _paintStackedAreas(
    Canvas canvas, {
    required List<double> xPositions,
    required double baseline,
    required double chartHeight,
    required double maxValue,
  }) {
    final count = xPositions.length;
    final cumulative = List<double>.filled(count, 0);
    final layers = <_StackedLayer>[];
    // Low-usage series hug the baseline and the highest-usage series closes
    // the top: a small series reads as its own low line instead of a band
    // floating on another agent's bulk.
    for (final series in _stackedSeries()) {
      final values = [
        for (final snapshot in timeline.snapshots)
          snapshot.values[series.label] ?? 0.0,
      ];
      if (!values.any((value) => value > 0)) continue;
      final bottomValues = List<double>.from(cumulative);
      for (var index = 0; index < count; index += 1) {
        cumulative[index] += values[index];
      }
      final topY = _plotOffsets(cumulative, baseline, chartHeight, maxValue);
      final bottomY = _plotOffsets(
        bottomValues,
        baseline,
        chartHeight,
        maxValue,
      );
      final fill = agentUsageSeriesColor(
        colors,
        series.label,
        grouping: timeline.grouping,
        displayName: timeline.displayNameFor(series.label),
      );
      layers.add(
        _StackedLayer(
          values: values,
          topY: topY,
          topSlopes: _monotoneSlopes(xPositions, topY),
          bottomY: bottomY,
          bottomSlopes: _monotoneSlopes(xPositions, bottomY),
          fill: fill,
        ),
      );
    }
    final fillPaint = Paint()..style = PaintingStyle.fill;
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _edgeStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final bloomPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _edgeStrokeWidth * 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    for (final layer in layers) {
      for (final (start, end) in layer.positiveRuns) {
        // Each positive run closes at its neighboring zero samples. No path or
        // outline crosses a zero-only interval, including above another series.
        final first = math.max(0, start - 1);
        final afterLast = math.min(count, end + 2);
        final area = _monotonePath(
          xPositions,
          layer.topY,
          layer.topSlopes,
          first,
          afterLast - 1,
        )..lineTo(xPositions[afterLast - 1], layer.bottomY[afterLast - 1]);
        _appendMonotone(
          area,
          xPositions,
          layer.bottomY,
          layer.bottomSlopes,
          afterLast - 1,
          first,
        );
        var topMost = double.infinity;
        var bottomMost = double.negativeInfinity;
        for (var index = first; index < afterLast; index += 1) {
          topMost = math.min(topMost, layer.topY[index]);
          bottomMost = math.max(bottomMost, layer.bottomY[index]);
        }
        fillPaint.shader = ui.Gradient.linear(
          Offset(0, topMost),
          Offset(0, bottomMost),
          [
            layer.fill.withValues(alpha: 0.34),
            layer.fill.withValues(alpha: 0.05),
          ],
        );
        canvas.drawPath(area..close(), fillPaint);
      }
    }
    for (final layer in layers) {
      bloomPaint.color = layer.fill.withValues(alpha: 0.3);
      edgePaint.color = layer.fill.withValues(alpha: 0.95);
      for (final (start, end) in layer.positiveRuns) {
        final first = math.max(0, start - 1);
        final last = math.min(count, end + 2) - 1;
        if (last <= first) continue;
        final edge = _monotonePath(
          xPositions,
          layer.topY,
          layer.topSlopes,
          first,
          last,
        );
        canvas.drawPath(edge, bloomPaint);
        canvas.drawPath(edge, edgePaint);
      }
    }
  }

  List<double> _plotOffsets(
    List<double> values,
    double baseline,
    double chartHeight,
    double maxValue,
  ) {
    return [
      for (final value in values) baseline - chartHeight * (value / maxValue),
    ];
  }

  /// Monotone cubic (Fritsch–Carlson) knot slopes. Every segment stays inside
  /// its own endpoints, so a stacked boundary never overshoots into the
  /// neighboring band the way an averaged control point does.
  List<double> _monotoneSlopes(List<double> xs, List<double> ys) {
    final count = xs.length;
    if (count < 2) return List<double>.filled(count, 0);
    final intervals = List<double>.filled(count - 1, 0);
    for (var index = 0; index < count - 1; index += 1) {
      final dx = xs[index + 1] - xs[index];
      intervals[index] = dx == 0 ? 0 : (ys[index + 1] - ys[index]) / dx;
    }
    final slopes = List<double>.filled(count, 0);
    slopes[0] = intervals.first;
    slopes[count - 1] = intervals.last;
    for (var index = 1; index < count - 1; index += 1) {
      final previous = intervals[index - 1];
      final next = intervals[index];
      slopes[index] = previous * next <= 0 ? 0 : (previous + next) / 2;
    }
    for (var index = 0; index < count - 1; index += 1) {
      final interval = intervals[index];
      if (interval == 0) {
        slopes[index] = 0;
        slopes[index + 1] = 0;
        continue;
      }
      final from = slopes[index] / interval;
      final to = slopes[index + 1] / interval;
      final magnitude = from * from + to * to;
      if (magnitude <= 9) continue;
      final scale = 3 / math.sqrt(magnitude);
      slopes[index] = scale * from * interval;
      slopes[index + 1] = scale * to * interval;
    }
    return slopes;
  }

  Path _monotonePath(
    List<double> xs,
    List<double> ys,
    List<double> slopes,
    int first,
    int last,
  ) {
    final path = Path()..moveTo(xs[first], ys[first]);
    _appendMonotone(path, xs, ys, slopes, first, last);
    return path;
  }

  /// Appends the cubic segments between two knots, in either direction, so the
  /// reversed bottom edge of an area retraces the same spline as the fill above
  /// it.
  void _appendMonotone(
    Path path,
    List<double> xs,
    List<double> ys,
    List<double> slopes,
    int from,
    int to,
  ) {
    final step = to >= from ? 1 : -1;
    for (var index = from; index != to; index += step) {
      final next = index + step;
      final dx = xs[next] - xs[index];
      if (dx == 0) {
        path.lineTo(xs[next], ys[next]);
        continue;
      }
      path.cubicTo(
        xs[index] + dx / 3,
        ys[index] + slopes[index] * dx / 3,
        xs[next] - dx / 3,
        ys[next] - slopes[next] * dx / 3,
        xs[next],
        ys[next],
      );
    }
  }

  /// The plotted stacking order: ascending totals, so the smallest series
  /// hugs the baseline and the largest closes the top of the stack.
  List<AgentUsageSeries> _stackedSeries() {
    return [...timeline.series]..sort((left, right) {
      final byTotal = timeline
          .totalFor(left.label)
          .compareTo(timeline.totalFor(right.label));
      return byTotal != 0 ? byTotal : left.label.compareTo(right.label);
    });
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
    final x = _hairlineCenter(xPositions[index]);
    canvas.drawLine(
      Offset(x, agentUsageChartTopPadding),
      Offset(x, baseline),
      Paint()
        ..color = colors.text.withValues(alpha: 0.35)
        ..strokeWidth = _hairline,
    );
    var cumulative = 0.0;
    for (final series in _stackedSeries()) {
      final value = timeline.snapshots[index].values[series.label] ?? 0.0;
      if (value <= 0) continue;
      cumulative += value;
      final center = Offset(
        x,
        baseline - chartHeight * (cumulative / maxValue),
      );
      canvas.drawCircle(
        center,
        _markerRadius + _markerHaloWidth,
        Paint()
          ..color = colors.surface
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        _markerRadius,
        Paint()
          ..color = agentUsageSeriesColor(
            colors,
            series.label,
            grouping: timeline.grouping,
            displayName: timeline.displayNameFor(series.label),
          )
          ..style = PaintingStyle.fill,
      );
    }
  }

  void _paintSingleStack(
    Canvas canvas,
    double x,
    double baseline,
    double chartHeight,
    double maxValue,
  ) {
    var cumulative = 0.0;
    for (final series in _stackedSeries()) {
      final value = timeline.snapshots.single.values[series.label] ?? 0;
      if (value <= 0) continue;
      final bottom = baseline - chartHeight * (cumulative / maxValue);
      cumulative += value;
      final top = baseline - chartHeight * (cumulative / maxValue);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(
          x - _barWidth / 2 + _barGap / 2,
          top,
          x + _barWidth / 2 - _barGap / 2,
          bottom,
        ),
        const Radius.circular(2),
      );
      final fill = agentUsageSeriesColor(
        colors,
        series.label,
        grouping: timeline.grouping,
        displayName: timeline.displayNameFor(series.label),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, top), Offset(0, bottom), [
            fill.withValues(alpha: 0.34),
            fill.withValues(alpha: 0.05),
          ])
          ..style = PaintingStyle.fill,
      );
      canvas.drawLine(
        Offset(rect.left + 2, top),
        Offset(rect.right - 2, top),
        Paint()
          ..color = fill.withValues(alpha: 0.95)
          ..strokeWidth = _edgeStrokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _paintValueLabels(
    Canvas canvas,
    double chartHeight,
    double baseline,
    double maxValue,
  ) {
    final gutterRight = agentUsageChartLeftPadding - _gutterGap;
    for (final fraction in _valueFractions) {
      final value = maxValue * fraction;
      final label = value <= 0 ? '0' : formatCompactAgentUsageNumber(value);
      final painter = _labelPainter(label)..layout(maxWidth: gutterRight);
      final left = math.max(0.0, gutterRight - painter.width);
      final top = math.max(
        0.0,
        baseline - chartHeight * fraction - painter.height / 2,
      );
      painter.paint(canvas, Offset(left, top));
      painter.dispose();
    }
  }

  void _paintXAxisLabels(
    Canvas canvas,
    Size size,
    List<double> xPositions,
    double y,
  ) {
    final count = xPositions.length;
    final rightEdge = size.width - agentUsageChartRightPadding;
    final painted = <Rect>[];
    for (final index in agentUsageAxisLabelCandidates(count)) {
      final painter = _labelPainter(
        formatAgentUsageTimeLabel(timeline.snapshots[index].time),
      )..layout(maxWidth: 88);
      // The two end ticks hug the plot edges; centering them would clip the
      // first and last date against the panel.
      final left = switch (index) {
        0 => agentUsageChartLeftPadding,
        _ when index == count - 1 => rightEdge - painter.width,
        _ => xPositions[index] - painter.width / 2,
      };
      final rect = Rect.fromLTWH(left, y, painter.width, painter.height);
      if (painted.any((existing) => existing.inflate(10).overlaps(rect))) {
        painter.dispose();
        continue;
      }
      painter.paint(canvas, rect.topLeft);
      painter.dispose();
      painted.add(rect);
    }
  }

  TextPainter _labelPainter(String label) {
    return TextPainter(
      text: TextSpan(text: label, style: labelStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
  }

  @override
  bool shouldRepaint(covariant AgentUsageWaveChartPainter oldDelegate) {
    return oldDelegate.timeline != timeline ||
        oldDelegate.colors != colors ||
        oldDelegate.labelStyle != labelStyle ||
        oldDelegate.hoveredSnapshotIndex != hoveredSnapshotIndex;
  }
}

/// One stacked band: its fill color and the plotted top/bottom boundaries
/// with their monotone slopes.
final class _StackedLayer {
  _StackedLayer({
    required List<double> values,
    required this.topY,
    required this.topSlopes,
    required this.bottomY,
    required this.bottomSlopes,
    required this.fill,
  }) : positiveRuns = _positiveRuns(values);

  final List<double> topY;
  final List<double> topSlopes;
  final List<double> bottomY;
  final List<double> bottomSlopes;
  final List<(int, int)> positiveRuns;
  final Color fill;

  static List<(int, int)> _positiveRuns(List<double> values) {
    final runs = <(int, int)>[];
    for (var start = 0; start < values.length; start += 1) {
      if (values[start] <= 0) continue;
      var end = start;
      while (end + 1 < values.length && values[end + 1] > 0) {
        end += 1;
      }
      runs.add((start, end));
      start = end;
    }
    return List<(int, int)>.unmodifiable(runs);
  }
}
