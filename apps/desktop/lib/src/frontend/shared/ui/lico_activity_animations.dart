import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// A bounded activity indicator that sweeps along the top edge of an existing
/// rounded surface.
///
/// The child keeps ownership of its fill and idle border. This widget paints
/// only transient execution feedback: an indeterminate brand pulse traveling
/// left to right along the top hairline while [enabled], and a static accent
/// line when reduced motion is enabled.
class LicoTopEdgePulse extends StatefulWidget {
  const LicoTopEdgePulse({
    super.key,
    required this.enabled,
    required this.borderRadius,
    required this.color,
    required this.child,
    this.strokeWidth = 1.8,
    this.duration = LicoMotion.loopLong,
  });

  final bool enabled;
  final BorderRadius borderRadius;
  final Color color;
  final Widget child;
  final double strokeWidth;
  final Duration duration;

  @override
  State<LicoTopEdgePulse> createState() => _LicoTopEdgePulseState();
}

class _LicoTopEdgePulseState extends State<LicoTopEdgePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant LicoTopEdgePulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.duration != widget.duration) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (!widget.enabled || reduceMotion) {
      _controller
        ..stop()
        ..value = 0;
      return;
    }
    if (!_controller.isAnimating) {
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
    if (!widget.enabled) return widget.child;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Stack(
      children: [
        widget.child,
        // The pulse only ever paints the top hairline, so confine the ticking
        // canvas to that strip: a full-size CustomPaint would invalidate the
        // whole surface's layer on every animation frame. The repaint boundary
        // keeps the strip's repaint out of the child's layer too.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: widget.strokeWidth,
          child: RepaintBoundary(
            child: IgnorePointer(
              child: CustomPaint(
                key: const Key('lico-top-edge-pulse-paint'),
                painter: _LicoTopEdgePulsePainter(
                  progress: _controller,
                  borderRadius: widget.borderRadius,
                  color: widget.color,
                  strokeWidth: widget.strokeWidth,
                  reduceMotion: reduceMotion,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LicoTopEdgePulsePainter extends CustomPainter {
  _LicoTopEdgePulsePainter({
    required this.progress,
    required this.borderRadius,
    required this.color,
    required this.strokeWidth,
    required this.reduceMotion,
  }) : super(repaint: reduceMotion ? null : progress);

  final Animation<double> progress;
  final BorderRadius borderRadius;
  final Color color;
  final double strokeWidth;
  final bool reduceMotion;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final strip = Rect.fromLTWH(0, 0, size.width, strokeWidth);
    canvas.save();
    // Confine the line to the surface silhouette so it dies out around the
    // top corner arcs instead of overhanging them. The canvas is only the
    // top strip now; the top corner arcs of an RRect do not depend on its
    // height (once the height clears twice the corner radius), so clipping
    // with a rect tall enough reproduces the full-surface silhouette exactly.
    final topRadius = borderRadius.topLeft.y > borderRadius.topRight.y
        ? borderRadius.topLeft.y
        : borderRadius.topRight.y;
    final clipHeight = size.height < topRadius * 2
        ? topRadius * 2
        : size.height;
    canvas.clipRRect(
      borderRadius.toRRect(Offset.zero & Size(size.width, clipHeight)),
    );
    if (reduceMotion) {
      canvas.drawRect(strip, Paint()..color = color.withValues(alpha: 0.72));
      canvas.restore();
      return;
    }

    canvas.drawRect(strip, Paint()..color = color.withValues(alpha: 0.16));
    // A soft comet band: the bright core leads, both ends fade to transparent
    // so the sweep reads as a pulse, never as progress.
    final bandWidth = size.width * 0.42;
    final travel = size.width + bandWidth * 2;
    final head = -bandWidth + travel * progress.value;
    final band = Rect.fromLTWH(head - bandWidth, 0, bandWidth, strokeWidth);
    final shader = LinearGradient(
      colors: [
        color.withValues(alpha: 0),
        color.withValues(alpha: 0.5),
        color,
        color.withValues(alpha: 0),
      ],
      stops: const [0.0, 0.45, 0.8, 1.0],
    ).createShader(band);
    canvas.drawRect(band, Paint()..shader = shader);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LicoTopEdgePulsePainter oldDelegate) {
    return oldDelegate.borderRadius != borderRadius ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.reduceMotion != reduceMotion;
  }
}

/// Continuous refresh-style spinner for in-flight agent conversations.
class LicoSpinningRefreshIcon extends StatefulWidget {
  const LicoSpinningRefreshIcon({
    super.key,
    this.size = 14,
    this.color,
    this.strokeWidth = 1.6,
  });

  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  State<LicoSpinningRefreshIcon> createState() =>
      _LicoSpinningRefreshIconState();
}

class _LicoSpinningRefreshIconState extends State<LicoSpinningRefreshIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: LicoMotion.loopShort,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disable = MediaQuery.disableAnimationsOf(context);
    if (disable) {
      _controller.stop();
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
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
    final color =
        widget.color ??
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72);
    // The rotation loops forever; its own repaint boundary keeps the
    // repeating repaint from invalidating the surrounding row's layer.
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: RotationTransition(
          turns: _controller,
          child: CustomPaint(
            painter: _LicoUpSpinnerPainter(
              color: color,
              strokeWidth: widget.strokeWidth,
            ),
          ),
        ),
      ),
    );
  }
}

class _LicoUpSpinnerPainter extends CustomPainter {
  const _LicoUpSpinnerPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = licoSpinnerArcRect(size, strokeWidth);
    final track = Paint()
      ..color = color.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final sweep = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 6.28318530718, false, track);
    canvas.drawArc(rect, -1.2, 1.8, false, sweep);
  }

  @override
  bool shouldRepaint(covariant _LicoUpSpinnerPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}

@visibleForTesting
Rect licoSpinnerArcRect(Size size, double strokeWidth) {
  final diameter = (size.shortestSide - strokeWidth).clamp(
    0.0,
    double.infinity,
  );
  return Rect.fromCenter(
    center: size.center(Offset.zero),
    width: diameter,
    height: diameter,
  );
}

/// Left-to-right pulse across loading copy. Wraps any text subtree.
class LicoShimmerMask extends StatefulWidget {
  const LicoShimmerMask({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  State<LicoShimmerMask> createState() => _LicoShimmerMaskState();
}

class _LicoShimmerMaskState extends State<LicoShimmerMask>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: LicoMotion.loopLong,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant LicoShimmerMask oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    final disable = MediaQuery.disableAnimationsOf(context) || !widget.enabled;
    if (disable) {
      _controller.stop();
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
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
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            final shift = (t * 2.4) - 0.7;
            return LinearGradient(
              begin: Alignment(-1.2 + shift, 0),
              end: Alignment(0.8 + shift, 0),
              colors: const [
                Color(0x61FFFFFF),
                Color(0xFFFFFFFF),
                Color(0xFFFFFFFF),
                Color(0x61FFFFFF),
              ],
              stops: const [0.0, 0.35, 0.65, 1.0],
            ).createShader(
              Rect.fromLTWH(
                bounds.left + bounds.width * shift,
                bounds.top,
                bounds.width,
                bounds.height,
              ),
            );
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Left-to-right shimmer used for the currently executing step or process title.
class LicoShimmerText extends StatelessWidget {
  const LicoShimmerText({
    super.key,
    required this.text,
    required this.style,
    this.enabled = true,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
  });

  final String text;
  final TextStyle style;
  final bool enabled;
  final int maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    return LicoShimmerMask(
      enabled: enabled,
      child: Text(text, maxLines: maxLines, overflow: overflow, style: style),
    );
  }
}
