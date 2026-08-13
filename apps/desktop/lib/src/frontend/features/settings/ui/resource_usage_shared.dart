import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// One named slice of the memory ring. Values are absolute byte counts; the
/// painter scales them against [MemoryUsageRingPainter.totalBytes].
final class MemoryUsageRingSegment {
  const MemoryUsageRingSegment({
    required this.id,
    required this.label,
    required this.bytes,
    required this.color,
  });

  final String id;
  final String label;
  final int bytes;
  final Color color;
}

String formatRssBytes(int bytes) {
  if (bytes <= 0) {
    return '0';
  }
  final megaBytes = bytes / (1024 * 1024);
  if (megaBytes < 10) {
    return megaBytes.toStringAsFixed(1);
  }
  if (megaBytes < 1024) {
    return megaBytes.toStringAsFixed(0);
  }
  return (megaBytes / 1024).toStringAsFixed(1);
}

/// Formats a capacity figure for the ring center and legend (MB / GB).
String formatMemoryCapacity(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  final megaBytes = bytes / (1024 * 1024);
  if (megaBytes < 1024) {
    if (megaBytes < 10) {
      return '${megaBytes.toStringAsFixed(1)} MB';
    }
    return '${megaBytes.toStringAsFixed(0)} MB';
  }
  final gigaBytes = megaBytes / 1024;
  if (gigaBytes < 10) {
    return '${gigaBytes.toStringAsFixed(1)} GB';
  }
  return '${gigaBytes.toStringAsFixed(0)} GB';
}

/// Stable segment palette for LicoUp plus running agents.
List<Color> memoryUsageSegmentPalette(LicoThemeColors colors) {
  return [
    colors.accent,
    colors.success,
    colors.warning,
    colors.accentStrong,
    colors.primaryStrong,
    colors.error,
  ];
}

/// Full-circle ring whose arc length is machine capacity. Filled segments are
/// LicoUp and each running agent; the remainder of the track stays dim.
final class MemoryUsageRingPainter extends CustomPainter {
  const MemoryUsageRingPainter({
    required this.segments,
    required this.totalBytes,
    required this.colors,
    this.strokeWidth = 18,
  });

  final List<MemoryUsageRingSegment> segments;
  final int totalBytes;
  final LicoThemeColors colors;
  final double strokeWidth;

  static const double _startAngle = -math.pi / 2;
  static const double _fullCircle = math.pi * 2;
  static const double _gapRadians = 0.018;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || totalBytes <= 0) {
      return;
    }
    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (side - strokeWidth) / 2;
    if (radius <= 0) {
      return;
    }
    final trackPaint = Paint()
      ..color = colors.line.withValues(alpha: colors.isDark ? 0.55 : 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;
    canvas.drawCircle(center, radius, trackPaint);

    final positive = [
      for (final segment in segments)
        if (segment.bytes > 0) segment,
    ];
    if (positive.isEmpty) {
      return;
    }
    final usedBytes = positive.fold<int>(0, (sum, s) => sum + s.bytes);
    final scaleBytes = math.max(totalBytes, usedBytes);
    var angle = _startAngle;
    final rect = Rect.fromCircle(center: center, radius: radius);
    for (final segment in positive) {
      final sweep = _fullCircle * (segment.bytes / scaleBytes);
      final drawable = math.max(0.0, sweep - _gapRadians);
      if (drawable <= 0) {
        angle += sweep;
        continue;
      }
      canvas.drawArc(
        rect,
        angle,
        drawable,
        false,
        Paint()
          ..color = segment.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.butt,
      );
      angle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant MemoryUsageRingPainter oldDelegate) {
    if (oldDelegate.totalBytes != totalBytes ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.colors != colors ||
        oldDelegate.segments.length != segments.length) {
      return true;
    }
    for (var index = 0; index < segments.length; index += 1) {
      final current = segments[index];
      final previous = oldDelegate.segments[index];
      if (current.id != previous.id ||
          current.bytes != previous.bytes ||
          current.color != previous.color ||
          current.label != previous.label) {
        return true;
      }
    }
    return false;
  }
}
