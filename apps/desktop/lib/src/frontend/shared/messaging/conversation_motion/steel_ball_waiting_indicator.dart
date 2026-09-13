import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Three identical hard spheres in an ideal horizontal guide with rigid ends.
///
/// Subtracting each sphere's diameter offset turns hard-sphere collisions into
/// freely crossing points. Sorting those points is exactly the equal-mass
/// velocity-exchange solution. With one moving point there are only three
/// cases, so sampling is constant-time and independent of frame steps. Wall
/// impulses reverse momentum; elastic sphere contacts exchange it. No damping,
/// spring drive, accumulated integration error or artificial restart is used.
class ElasticSteelBallSystem {
  const ElasticSteelBallSystem({required this.radius, required this.width})
    : assert(radius > 0),
      assert(width > radius * 6);

  final double radius;
  final double width;

  /// Velocities are derivatives with respect to a complete [phase] cycle.
  SteelBallSnapshot sample(double phase) {
    final free = width - radius * 6;
    final cycle = phase % 1;
    final forward = cycle < 0.5;
    final point = (forward ? cycle : 1 - cycle) * free * 2;
    final velocity = (forward ? 1 : -1) * free * 2;
    final a = free * 0.35;
    final b = free * 0.65;
    if (point < a || (point == a && !forward)) {
      return SteelBallSnapshot(
        first: radius + point,
        second: radius * 3 + a,
        third: radius * 5 + b,
        firstVelocity: velocity,
        secondVelocity: 0,
        thirdVelocity: 0,
      );
    }
    if (point < b || (point == b && !forward)) {
      return SteelBallSnapshot(
        first: radius + a,
        second: radius * 3 + point,
        third: radius * 5 + b,
        firstVelocity: 0,
        secondVelocity: velocity,
        thirdVelocity: 0,
      );
    }
    return SteelBallSnapshot(
      first: radius + a,
      second: radius * 3 + b,
      third: radius * 5 + point,
      firstVelocity: 0,
      secondVelocity: 0,
      thirdVelocity: velocity,
    );
  }
}

@immutable
class SteelBallSnapshot {
  const SteelBallSnapshot({
    required this.first,
    required this.second,
    required this.third,
    required this.firstVelocity,
    required this.secondVelocity,
    required this.thirdVelocity,
  });

  final double first;
  final double second;
  final double third;
  final double firstVelocity;
  final double secondVelocity;
  final double thirdVelocity;
}

/// Activity is owned by the caller; the indicator has no message or run state.
class SteelBallWaitingIndicator extends StatefulWidget {
  const SteelBallWaitingIndicator({
    super.key,
    required this.active,
    this.size = 28,
  }) : assert(size > 0);

  final bool active;
  final double size;

  @override
  State<SteelBallWaitingIndicator> createState() =>
      _SteelBallWaitingIndicatorState();
}

class _SteelBallWaitingIndicatorState extends State<SteelBallWaitingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SteelBallWaitingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final duration = context.motion(LicoMotion.loopLong);
    if (!widget.active ||
        duration == Duration.zero ||
        !context.allowsAmbientMotion) {
      _controller.stop();
      return;
    }
    if (!_controller.isAnimating || _controller.duration != duration) {
      _controller.duration = duration;
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    final colors = context.licoColors;
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: SteelBallWaitingPainter(
            phase: _controller,
            silver: colors.accentStrong,
            shadow: colors.surfaceSunken,
            rail: colors.lineStrong,
            reducedMotion: context.motion(LicoMotion.loopLong) == Duration.zero,
          ),
          size: Size(widget.size * 1.85, widget.size),
        ),
      ),
    );
  }
}

class SteelBallWaitingPainter extends CustomPainter {
  SteelBallWaitingPainter({
    required this.phase,
    required this.silver,
    required this.shadow,
    required this.rail,
    this.reducedMotion = false,
  }) : super(repaint: phase);

  final Animation<double> phase;
  final Color silver;
  final Color shadow;
  final Color rail;
  final bool reducedMotion;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final radius = math.min(size.height * 0.14, size.width / 8);
    final inset = radius * 0.6;
    final width = size.width - inset * 2;
    final system = ElasticSteelBallSystem(radius: radius, width: width);
    final state = system.sample(phase.value);
    final y = size.height * 0.48;
    final railPaint = Paint()
      ..color = rail.withValues(alpha: 0.45)
      ..strokeWidth = 0.7;
    // Visible end stops supply the external reaction that reverses momentum.
    if (!reducedMotion) {
      canvas.drawLine(
        Offset(inset - 0.7, y - radius),
        Offset(inset - 0.7, y + radius),
        railPaint,
      );
      canvas.drawLine(
        Offset(size.width - inset + 0.7, y - radius),
        Offset(size.width - inset + 0.7, y + radius),
        railPaint,
      );
    }
    final centers = reducedMotion
        ? [width * 0.24, width * 0.5, width * 0.76]
        : [state.first, state.second, state.third];
    for (final x in centers) {
      final center = Offset(inset + x, y);
      canvas.drawOval(
        Rect.fromCenter(
          center: center + Offset(0, radius * 1.65),
          width: radius * 1.65,
          height: radius * 0.36,
        ),
        Paint()..color = shadow.withValues(alpha: 0.48),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(
            center + Offset(-radius * 0.34, -radius * 0.38),
            radius * 1.55,
            [
              Color.lerp(silver, Colors.white, 0.85)!,
              silver,
              Color.lerp(silver, shadow, 0.78)!,
              silver.withValues(alpha: 0.9),
            ],
            [0, 0.27, 0.69, 1],
          ),
      );
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 0.35),
        3.65,
        1.45,
        false,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.55
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(SteelBallWaitingPainter oldDelegate) =>
      phase != oldDelegate.phase ||
      silver != oldDelegate.silver ||
      shadow != oldDelegate.shadow ||
      rail != oldDelegate.rail ||
      reducedMotion != oldDelegate.reducedMotion;
}
