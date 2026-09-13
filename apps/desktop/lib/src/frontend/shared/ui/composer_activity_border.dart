import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/appearance/appearance_visuals.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// Execution feedback is paint only; input, cancellation and dispatch retain
/// their existing owners. Idle and active rims use the same inset geometry.
class ComposerActivityBorder extends StatefulWidget {
  const ComposerActivityBorder({
    super.key,
    required this.active,
    required this.borderRadius,
    required this.color,
    required this.child,
  });

  final bool active;
  final BorderRadius borderRadius;
  final Color color;
  final Widget child;

  @override
  State<ComposerActivityBorder> createState() => _ComposerActivityBorderState();
}

class _ComposerActivityBorderState extends State<ComposerActivityBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(ComposerActivityBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncMotion();
  }

  void _syncMotion() {
    if (!widget.active || !context.allowsAmbientMotion) {
      _controller.stop();
      return;
    }
    final duration = context.motion(LicoMotion.loopLong);
    if (!_controller.isAnimating || _controller.duration != duration) {
      _controller
        ..duration = duration
        ..repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      widget.child,
      if (widget.active)
        Positioned.fill(
          child: RepaintBoundary(
            child: IgnorePointer(
              child: CustomPaint(
                key: const Key('composer-activity-border-paint'),
                painter: ComposerActivityBorderPainter(
                  progress: _controller,
                  effect: context.appearanceVisuals.composerActivityEffect,
                  animate: context.allowsAmbientMotion,
                  borderRadius: widget.borderRadius,
                  color: widget.color,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// The pulse sweeps a soft highlight around one continuous perimeter. Its
/// geometry is cached between animation frames and rebuilt only after resize.
class ComposerActivityBorderPainter extends CustomPainter {
  ComposerActivityBorderPainter({
    required this.progress,
    required this.effect,
    required this.animate,
    required this.borderRadius,
    required this.color,
  }) : super(repaint: animate ? progress : null);

  final Animation<double> progress;
  final ComposerActivityEffect effect;
  final bool animate;
  final BorderRadius borderRadius;
  final Color color;
  Size? _cachedSize;
  Path? _path;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const width = 1.0;
    final phase = animate ? progress.value : 0.5;
    if (!animate || effect == ComposerActivityEffect.breathing) {
      final alpha = animate
          ? 0.42 + 0.58 * (1 - math.cos(phase * math.pi * 2)) / 2
          : 0.82;
      ContinuousStrokePainter(
        borderRadius: borderRadius,
        color: color.withValues(alpha: alpha),
        width: width,
      ).paint(canvas, size);
      return;
    }
    if (_cachedSize != size) {
      _cachedSize = size;
      _path = Path()
        ..addRRect(continuousStrokeRRect(size, borderRadius, width));
    }
    final rect = Offset.zero & size;
    canvas.drawPath(
      _path!,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..isAntiAlias = true
        ..shader = SweepGradient(
          transform: GradientRotation(phase * math.pi * 2),
          colors: [
            color.withValues(alpha: 0.24),
            color.withValues(alpha: 0.24),
            color.withValues(alpha: 0.62),
            color,
            color.withValues(alpha: 0.24),
          ],
          stops: const [0, 0.64, 0.80, 0.91, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(ComposerActivityBorderPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.effect != effect ||
      oldDelegate.animate != animate ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.color != color;
}
