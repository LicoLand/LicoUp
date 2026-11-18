import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_card_model.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_style.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_graph_layout.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// [points] joined by straight runs and circular corners of up to [radius].
///
/// A corner never takes more than half of either adjacent run, so two bends
/// close together still meet on the shared run.
Path collaborationRoutePath(
  List<Offset> points, {
  double radius = CollaborationGraphMetrics.cornerRadius,
}) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points.first.dx, points.first.dy);
  for (var i = 1; i < points.length - 1; i++) {
    final previous = points[i - 1];
    final corner = points[i];
    final next = points[i + 1];
    final inLength = (corner - previous).distance;
    final outLength = (next - corner).distance;
    final r = math.min(radius, math.min(inLength, outLength) / 2);
    if (r < 0.5) {
      path.lineTo(corner.dx, corner.dy);
      continue;
    }
    final entry = corner - (corner - previous) / inLength * r;
    final exit = corner + (next - corner) / outLength * r;
    path
      ..lineTo(entry.dx, entry.dy)
      ..conicTo(corner.dx, corner.dy, exit.dx, exit.dy, math.sqrt1_2);
  }
  path.lineTo(points.last.dx, points.last.dy);
  return path;
}

/// A route's path with the measurements its animations need, built once per
/// layout.
final class CollaborationRouteGeometry {
  CollaborationRouteGeometry(this.route)
    : path = collaborationRoutePath(route.points) {
    _metrics = path.computeMetrics().toList(growable: false);
    length = _metrics.fold(0.0, (sum, metric) => sum + metric.length);
  }

  final CollaborationEdgeRoute route;
  final Path path;
  late final List<ui.PathMetric> _metrics;
  late final double length;
  final Map<(double, double), Path> _dashes = {};

  String get key => route.key;

  /// Dashes of [dash] separated by [gap], shifted forward by [shift].
  Path dashed(double dash, double gap, {double shift = 0}) {
    if (shift == 0) {
      return _dashes.putIfAbsent((dash, gap), () => _dashed(dash, gap, 0));
    }
    return _dashed(dash, gap, shift);
  }

  Path _dashed(double dash, double gap, double shift) {
    final period = dash + gap;
    final out = Path();
    for (final metric in _metrics) {
      var start = shift % period - period;
      while (start < metric.length) {
        final from = math.max(0.0, start);
        final to = math.min(metric.length, start + dash);
        if (to > from) out.addPath(metric.extractPath(from, to), Offset.zero);
        start += period;
      }
    }
    return out;
  }

  /// The leading [fraction] of the route.
  Path leading(double fraction) {
    final out = Path();
    var remaining = length * fraction.clamp(0.0, 1.0);
    for (final metric in _metrics) {
      if (remaining <= 0) break;
      out.addPath(
        metric.extractPath(0, math.min(remaining, metric.length)),
        Offset.zero,
      );
      remaining -= metric.length;
    }
    return out;
  }

  /// The point [fraction] of the way along the route.
  Offset pointAt(double fraction) {
    var remaining = length * fraction.clamp(0.0, 1.0);
    for (final metric in _metrics) {
      if (remaining <= metric.length) {
        return metric.getTangentForOffset(remaining)?.position ??
            route.points.last;
      }
      remaining -= metric.length;
    }
    return route.points.last;
  }
}

/// Every route of the canvas, with the flow, hover, draw-in and dispatch
/// effects.
final class CollaborationEdgePainter extends CustomPainter {
  CollaborationEdgePainter({
    required this.routes,
    required this.styles,
    required this.colors,
    required this.showAdded,
    required this.hovered,
    required this.flow,
    required this.animate,
    required this.drawIn,
    required this.drawInKeys,
    required this.dispatch,
    required this.dispatchKeys,
  }) : _flowing = animate && styles.values.any((style) => style.active),
       super(
         repaint: Listenable.merge([
           hovered,
           if (animate && styles.values.any((style) => style.active)) flow,
           if (drawInKeys.isNotEmpty) drawIn,
           if (dispatchKeys.isNotEmpty) dispatch,
         ]),
       );

  final List<CollaborationRouteGeometry> routes;
  final Map<String, CollaborationEdgeStyle> styles;
  final LicoThemeColors colors;

  /// Whether added routes take the change color: a diff is on screen.
  final bool showAdded;

  /// The hovered display node; its routes highlight and the rest dim.
  final ValueListenable<String?> hovered;

  /// 0..1 per dash period: active routes flow while [animate] holds.
  final Animation<double> flow;
  final bool animate;

  /// Draws [drawInKeys] in from their source after a plan change.
  final Animation<double> drawIn;
  final Set<String> drawInKeys;

  /// Sends one dot along each of [dispatchKeys] when work is handed off.
  final Animation<double> dispatch;
  final Set<String> dispatchKeys;
  final bool _flowing;

  static const double _activeDash = 7;
  static const double _activeGap = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final focus = hovered.value;
    final ink = CollaborationInk(colors);
    // Emphasized routes paint last so they cross over the quiet ones.
    for (final emphasized in const [false, true]) {
      for (final geometry in routes) {
        final route = geometry.route;
        final style =
            styles[geometry.key] ?? CollaborationEdgeStyle(kind: route.kind);
        final highlighted =
            focus != null && (route.from == focus || route.to == focus);
        if ((highlighted || style.active) != emphasized) continue;
        _paintRoute(canvas, geometry, style, ink, focus, highlighted);
      }
    }
    final t = dispatch.value;
    if (dispatchKeys.isEmpty || t <= 0 || t >= 1) return;
    final dot = Paint()..color = ink.brand;
    for (final geometry in routes) {
      if (!dispatchKeys.contains(geometry.key)) continue;
      canvas.drawCircle(geometry.pointAt(t), 3.4, dot);
    }
  }

  void _paintRoute(
    Canvas canvas,
    CollaborationRouteGeometry geometry,
    CollaborationEdgeStyle style,
    CollaborationInk ink,
    String? focus,
    bool highlighted,
  ) {
    final callback = style.kind == CollaborationRouteKind.callback;
    final drawing = drawInKeys.contains(geometry.key) && drawIn.value < 1;
    var color = callback ? colors.accent : colors.lineStrong;
    var width = 1.6;
    var opacity = callback ? 0.75 : 1.0;
    (double, double)? dash = callback ? (4, 5) : null;
    var moving = false;
    if (style.active) {
      color = callback ? colors.accent : ink.brand;
      width = 1.8;
      opacity = 1;
      dash = (_activeDash, _activeGap);
      moving = _flowing;
    }
    if (style.added && (showAdded || drawing)) color = colors.warning;
    if (style.ghost) {
      dash ??= (5, 5);
      opacity *= 0.5;
    }
    if (focus != null) {
      opacity = highlighted ? 1 : 0.2;
      if (highlighted) color = ink.brand;
    }

    final Path path;
    if (drawing) {
      path = geometry.leading(Curves.easeOut.transform(drawIn.value));
    } else if (dash == null) {
      path = geometry.path;
    } else {
      path = geometry.dashed(
        dash.$1,
        dash.$2,
        shift: moving ? flow.value * (_activeDash + _activeGap) : 0,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: color.a * opacity),
    );
  }

  @override
  bool shouldRepaint(CollaborationEdgePainter old) =>
      !identical(old.routes, routes) ||
      !identical(old.styles, styles) ||
      old.colors != colors ||
      old.showAdded != showAdded ||
      old.hovered != hovered ||
      old.flow != flow ||
      old.animate != animate ||
      old.drawIn != drawIn ||
      !setEquals(old.drawInKeys, drawInKeys) ||
      old.dispatch != dispatch ||
      !setEquals(old.dispatchKeys, dispatchKeys);
}

/// The canvas dot grid in viewport space, moving with the view so it reads
/// as the surface the cards sit on.
final class CollaborationGridPainter extends CustomPainter {
  CollaborationGridPainter({required this.transform, required this.color})
    : super(repaint: transform);

  final ValueListenable<Matrix4> transform;
  final Color color;

  static const double spacing = 22;

  @override
  void paint(Canvas canvas, Size size) {
    final matrix = transform.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    var step = spacing * scale;
    // Below this pitch the grid turns into a texture; drop every other dot.
    while (step < 14) {
      step *= 2;
    }
    final originX = (translation.x + spacing / 2 * scale) % step;
    final originY = (translation.y + spacing / 2 * scale) % step;
    final points = <Offset>[
      for (var x = originX; x < size.width; x += step)
        for (var y = originY; y < size.height; y += step) Offset(x, y),
    ];
    canvas.drawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(CollaborationGridPainter old) =>
      old.transform != transform || old.color != color;
}

/// The brand sweep across the canvas when a new plan revision applies.
final class CollaborationSweepPainter extends CustomPainter {
  CollaborationSweepPainter({required this.progress, required this.colors})
    : super(repaint: progress);

  final Animation<double> progress;
  final LicoThemeColors colors;

  static const double band = 130;

  @override
  void paint(Canvas canvas, Size size) {
    final value = progress.value;
    if (value <= 0 || value >= 1) return;
    final t = Curves.easeInOut.transform(value);
    final left = -band + (size.width * 1.1 + band) * t;
    final rect = Rect.fromLTWH(left, 0, band, size.height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-1, -0.18),
          end: const Alignment(1, 0.18),
          colors: [
            colors.brandGlow.withValues(alpha: 0),
            colors.brandGlow,
            colors.accentGlow,
            colors.accentGlow.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(CollaborationSweepPainter old) =>
      old.progress != progress || old.colors != colors;
}

/// How the minimap tints one card.
enum CollaborationMinimapTone { idle, active, waiting, done, failed }

/// Maps the world into a minimap of [size], letterboxed and centered.
final class CollaborationMinimapGeometry {
  CollaborationMinimapGeometry(this.world, this.size)
    : scale = world.isEmpty
          ? 1
          : math.min(size.width / world.width, size.height / world.height) {
    origin = Offset(
      (size.width - world.width * scale) / 2,
      (size.height - world.height * scale) / 2,
    );
  }

  final Size world;
  final Size size;
  final double scale;
  late final Offset origin;

  Rect toMap(Rect worldRect) => Rect.fromLTWH(
    origin.dx + worldRect.left * scale,
    origin.dy + worldRect.top * scale,
    worldRect.width * scale,
    worldRect.height * scale,
  );

  Offset toWorld(Offset local) => (local - origin) / scale;
}

final class CollaborationMinimapPainter extends CustomPainter {
  CollaborationMinimapPainter({
    required this.cards,
    required this.world,
    required this.transform,
    required this.viewport,
    required this.colors,
  }) : super(repaint: transform);

  final List<(Rect, CollaborationMinimapTone)> cards;
  final Size world;
  final ValueListenable<Matrix4> transform;

  /// The canvas size the transform maps the world into.
  final Size viewport;
  final LicoThemeColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = CollaborationMinimapGeometry(world, size);
    for (final (rect, tone) in cards) {
      final mapped = geometry.toMap(rect);
      final isDark = colors.isDark;
      final color = switch (tone) {
        CollaborationMinimapTone.idle =>
          isDark
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.black.withValues(alpha: 0.14),
        CollaborationMinimapTone.done =>
          isDark
              ? Colors.white.withValues(alpha: 0.30)
              : Colors.black.withValues(alpha: 0.25),
        CollaborationMinimapTone.active => colors.accent.withValues(alpha: 0.7),
        CollaborationMinimapTone.waiting => colors.primary.withValues(
          alpha: 0.8,
        ),
        CollaborationMinimapTone.failed => colors.error.withValues(alpha: 0.7),
      };
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            mapped.left,
            mapped.top,
            math.max(2.5, mapped.width),
            math.max(2.5, mapped.height),
          ),
          const Radius.circular(2),
        ),
        Paint()..color = color,
      );
    }
    if (viewport.isEmpty) return;
    final inverse = Matrix4.tryInvert(transform.value);
    if (inverse == null) return;
    final visible = geometry.toMap(
      MatrixUtils.transformRect(inverse, Offset.zero & viewport),
    );
    final view = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        visible.left,
        visible.top,
        math.max(6, visible.width),
        math.max(6, visible.height),
      ),
      const Radius.circular(2),
    );
    final isDark = colors.isDark;
    canvas
      ..drawRRect(
        view,
        Paint()
          ..color = isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.black.withValues(alpha: 0.03),
      )
      ..drawRRect(
        view,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = isDark
              ? Colors.white.withValues(alpha: 0.55)
              : Colors.black.withValues(alpha: 0.45),
      );
  }

  @override
  bool shouldRepaint(CollaborationMinimapPainter old) =>
      !identical(old.cards, cards) ||
      old.world != world ||
      old.transform != transform ||
      old.viewport != viewport ||
      old.colors != colors;
}
