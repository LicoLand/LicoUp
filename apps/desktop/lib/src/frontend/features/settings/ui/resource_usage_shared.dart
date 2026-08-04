import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

String formatRssBytes(int bytes) {
  if (bytes <= 0) {
    return '0';
  }
  final megaBytes = bytes / (1024 * 1024);
  if (megaBytes < 1024) {
    return megaBytes.toStringAsFixed(0);
  }
  return (megaBytes / 1024).toStringAsFixed(1);
}

String formatRateKbPerSec(double kbPerSec) {
  if (kbPerSec < 0.05) {
    return '0';
  }
  if (kbPerSec < 1024) {
    return kbPerSec.toStringAsFixed(0);
  }
  return (kbPerSec / 1024).toStringAsFixed(1);
}

String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kiloBytes = bytes / 1024;
  if (kiloBytes < 1024) {
    return '${kiloBytes.toStringAsFixed(0)} KB';
  }
  final megaBytes = kiloBytes / 1024;
  if (megaBytes < 1024) {
    return '${megaBytes.toStringAsFixed(1)} MB';
  }
  return '${(megaBytes / 1024).toStringAsFixed(2)} GB';
}

/// A compact time-series line: grid baseline, filled area, and a stroked
/// curve spanning the full available width.
final class ResourceUsageSparklinePainter extends CustomPainter {
  const ResourceUsageSparklinePainter({
    required this.values,
    required this.color,
    required this.colors,
  });

  final List<double> values;
  final Color color;
  final LicoThemeColors colors;

  static const double _padding = 2;
  static const double _topInset = 6;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    final baseline = size.height - _padding;
    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      Paint()
        ..color = colors.line.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );
    if (values.length < 2) {
      return;
    }
    final maxValue = math.max(1.0, values.reduce(math.max));
    final chartHeight = math.max(1.0, baseline - _topInset);
    final xStep = (size.width - 2 * _padding) / (values.length - 1);
    final points = [
      for (var index = 0; index < values.length; index += 1)
        Offset(
          _padding + xStep * index,
          baseline - chartHeight * (values[index] / maxValue),
        ),
    ];
    final areaPath = Path()..moveTo(points.first.dx, baseline);
    for (final point in points) {
      areaPath.lineTo(point.dx, point.dy);
    }
    areaPath.lineTo(points.last.dx, baseline);
    areaPath.close();
    canvas.drawPath(
      areaPath,
      Paint()
        ..color = color.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill,
    );
    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index += 1) {
      final previous = points[index - 1];
      final current = points[index];
      final controlX = (previous.dx + current.dx) / 2;
      linePath.cubicTo(
        controlX,
        previous.dy,
        controlX,
        current.dy,
        current.dx,
        current.dy,
      );
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = color.withValues(alpha: 0.92)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(
      points.last,
      2.6,
      Paint()
        ..color = colors.surface
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      points.last,
      2,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant ResourceUsageSparklinePainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.color != color ||
        oldDelegate.colors != colors;
  }
}
