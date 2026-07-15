import 'package:flutter/material.dart';

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
      duration: const Duration(milliseconds: 900),
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
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RotationTransition(
        turns: _controller,
        child: CustomPaint(
          painter: _LicoArcSpinnerPainter(
            color: color,
            strokeWidth: widget.strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _LicoArcSpinnerPainter extends CustomPainter {
  const _LicoArcSpinnerPainter({
    required this.color,
    required this.strokeWidth,
  });

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
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
  bool shouldRepaint(covariant _LicoArcSpinnerPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}

/// Left-to-right shimmer used for the currently executing step or process title.
class LicoShimmerText extends StatefulWidget {
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
  State<LicoShimmerText> createState() => _LicoShimmerTextState();
}

class _LicoShimmerTextState extends State<LicoShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant LicoShimmerText oldWidget) {
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
    final base = widget.style.color ?? DefaultTextStyle.of(context).style.color;
    if (base == null) {
      return Text(
        widget.text,
        style: widget.style,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
      );
    }
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      return Text(
        widget.text,
        style: widget.style,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
      );
    }
    final highlight = Color.lerp(base, Colors.white, 0.55) ?? base;
    final dim = base.withValues(alpha: 0.38);
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
              colors: [dim, base, highlight, base, dim],
              stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: Text(
        widget.text,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
        style: widget.style.copyWith(color: Colors.white),
      ),
    );
  }
}
