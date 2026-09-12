import 'package:flutter/material.dart';

/// One path owns all four sides and corner arcs. The stroke is inset so clips
/// never shave off a half stroke at the capsule's straight/curved joins.
class ContinuousStrokePainter extends CustomPainter {
  const ContinuousStrokePainter({
    required this.borderRadius,
    required this.color,
    this.width = 1,
  });

  final BorderRadius borderRadius;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || width <= 0 || color.a == 0) return;
    final rect = borderRadius.toRRect(Offset.zero & size).scaleRadii();
    canvas.drawRRect(
      rect.deflate(width / 2),
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(ContinuousStrokePainter oldDelegate) =>
      borderRadius != oldDelegate.borderRadius ||
      color != oldDelegate.color ||
      width != oldDelegate.width;
}

/// Color-only control chrome. Concrete search, capsule and glass components
/// specialize this base while retaining ownership of their interaction logic.
abstract class BaseControlSurface extends StatelessWidget {
  const BaseControlSurface({
    super.key,
    required this.child,
    required this.fill,
    required this.stroke,
    required this.borderRadius,
    this.strokeWidth = 1,
    this.clipBehavior = Clip.none,
  });

  final Widget child;
  final Color fill;
  final Color stroke;
  final BorderRadius borderRadius;
  final double strokeWidth;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final content = CustomPaint(
      foregroundPainter: ContinuousStrokePainter(
        borderRadius: borderRadius,
        color: stroke,
        width: strokeWidth,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: fill, borderRadius: borderRadius),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
    return clipBehavior == Clip.none
        ? content
        : ClipRRect(
            borderRadius: borderRadius,
            clipBehavior: clipBehavior,
            child: content,
          );
  }
}
