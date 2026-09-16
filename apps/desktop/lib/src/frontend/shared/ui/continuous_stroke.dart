import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Normalize oversize stadium radii before insetting. Insetting an
/// unnormalized radius makes short capsule ends diverge from straight sides.
RRect continuousStrokeRRect(
  Size size,
  BorderRadius borderRadius,
  double width,
) => borderRadius.toRRect(Offset.zero & size).scaleRadii().deflate(width / 2);

RRect continuousStrokeOuterRRect(Rect rect, BorderRadius borderRadius) =>
    borderRadius.toRRect(rect).scaleRadii();

/// Filled ring for a content-layer structural hairline. Glass chrome does not
/// use this draw; its edge is a specular highlight owned by the glass surface.
void paintContinuousStroke(
  Canvas canvas,
  Rect rect, {
  required BorderRadius borderRadius,
  required BorderSide side,
  Rect? gap,
}) {
  if (rect.isEmpty ||
      side.style == BorderStyle.none ||
      side.width <= 0 ||
      side.color.a == 0) {
    return;
  }
  final borderRect = continuousStrokeOuterRRect(rect, borderRadius);
  final outer = borderRect.inflate(side.strokeOutset);
  final inner = borderRect.deflate(side.strokeInset);
  final paint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.fill
    ..color = side.color;
  if (inner.width <= 0 || inner.height <= 0) {
    canvas.drawRRect(outer, paint);
    return;
  }
  if (gap == null || gap.isEmpty) {
    canvas.drawDRRect(outer, inner, paint);
    return;
  }
  canvas.drawPath(
    Path.combine(
      PathOperation.difference,
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRRect(outer)
        ..addRRect(inner),
      Path()..addRect(gap),
    ),
    paint,
  );
}

void paintContinuousHairlineStrip(Canvas canvas, Rect strip, Color color) {
  if (strip.isEmpty || color.a == 0) return;
  canvas.drawRect(
    strip,
    Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.fill
      ..color = color,
  );
}

/// Shared [ShapeDecoration] for a fill plus one structural hairline rim.
ShapeDecoration continuousHairlineDecoration({
  Color? color,
  Gradient? gradient,
  required BorderRadiusGeometry borderRadius,
  Color? stroke,
  double strokeWidth = 1,
  List<BoxShadow>? shadows,
}) {
  final side = stroke == null || strokeWidth <= 0
      ? BorderSide.none
      : BorderSide(color: stroke, width: strokeWidth);
  return ShapeDecoration(
    color: color,
    gradient: gradient,
    shadows: shadows,
    shape: ContinuousRoundedBorder(borderRadius: borderRadius, side: side),
  );
}

/// Closed hairline rasterizer for content-layer outlines.
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
    paintContinuousStroke(
      canvas,
      Offset.zero & size,
      borderRadius: borderRadius,
      side: BorderSide(color: color, width: width),
    );
  }

  @override
  bool shouldRepaint(ContinuousStrokePainter oldDelegate) =>
      borderRadius != oldDelegate.borderRadius ||
      color != oldDelegate.color ||
      width != oldDelegate.width;
}

/// One-sided 1 px separator as a filled strip, matching rim straight segments.
class ContinuousEdgeHairlinePainter extends CustomPainter {
  const ContinuousEdgeHairlinePainter({
    required this.color,
    required this.edge,
    this.width = 1,
  });

  final Color color;
  final AxisDirection edge;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || width <= 0) return;
    final strip = switch (edge) {
      AxisDirection.up => Rect.fromLTWH(0, 0, size.width, width),
      AxisDirection.down => Rect.fromLTWH(
        0,
        size.height - width,
        size.width,
        width,
      ),
      AxisDirection.left => Rect.fromLTWH(0, 0, width, size.height),
      AxisDirection.right => Rect.fromLTWH(
        size.width - width,
        0,
        width,
        size.height,
      ),
    };
    paintContinuousHairlineStrip(canvas, strip, color);
  }

  @override
  bool shouldRepaint(ContinuousEdgeHairlinePainter oldDelegate) =>
      color != oldDelegate.color ||
      edge != oldDelegate.edge ||
      width != oldDelegate.width;
}

/// Material shape that paints through [paintContinuousStroke].
class ContinuousRoundedBorder extends OutlinedBorder {
  const ContinuousRoundedBorder({
    super.side,
    this.borderRadius = BorderRadius.zero,
  });

  final BorderRadiusGeometry borderRadius;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.strokeInset);

  @override
  ContinuousRoundedBorder scale(double t) {
    return ContinuousRoundedBorder(
      side: side.scale(t),
      borderRadius: borderRadius * t,
    );
  }

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is ContinuousRoundedBorder) {
      return ContinuousRoundedBorder(
        side: BorderSide.lerp(a.side, side, t),
        borderRadius: BorderRadiusGeometry.lerp(
          a.borderRadius,
          borderRadius,
          t,
        )!,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is ContinuousRoundedBorder) {
      return ContinuousRoundedBorder(
        side: BorderSide.lerp(side, b.side, t),
        borderRadius: BorderRadiusGeometry.lerp(
          borderRadius,
          b.borderRadius,
          t,
        )!,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  ContinuousRoundedBorder copyWith({
    BorderSide? side,
    BorderRadiusGeometry? borderRadius,
  }) {
    return ContinuousRoundedBorder(
      side: side ?? this.side,
      borderRadius: borderRadius ?? this.borderRadius,
    );
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRRect(
      continuousStrokeOuterRRect(
        rect,
        borderRadius.resolve(textDirection),
      ).deflate(side.strokeInset),
    );
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRRect(
      continuousStrokeOuterRRect(rect, borderRadius.resolve(textDirection)),
    );
  }

  @override
  void paintInterior(
    Canvas canvas,
    Rect rect,
    Paint paint, {
    TextDirection? textDirection,
  }) {
    final outer = continuousStrokeOuterRRect(
      rect,
      borderRadius.resolve(textDirection),
    );
    if (side.style == BorderStyle.solid && side.width > 0 && side.color.a > 0) {
      final inner = outer.deflate(side.strokeInset);
      if (inner.width > 0 && inner.height > 0) {
        canvas.drawRRect(inner, paint);
        return;
      }
    }
    canvas.drawRRect(outer, paint);
  }

  @override
  bool get preferPaintInterior => true;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    paintContinuousStroke(
      canvas,
      rect,
      borderRadius: borderRadius.resolve(textDirection),
      side: side,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ContinuousRoundedBorder &&
        other.side == side &&
        other.borderRadius == borderRadius;
  }

  @override
  int get hashCode => Object.hash(side, borderRadius);

  @override
  String toString() {
    return '${objectRuntimeType(this, 'ContinuousRoundedBorder')}'
        '($side, $borderRadius)';
  }
}

/// Input outline that keeps the floating-label gap but uses the hairline ring.
class ContinuousOutlineInputBorder extends OutlineInputBorder {
  const ContinuousOutlineInputBorder({
    super.borderSide = const BorderSide(),
    super.borderRadius = const BorderRadius.all(Radius.circular(4)),
    super.gapPadding = 4.0,
  });

  @override
  ContinuousOutlineInputBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) {
    return ContinuousOutlineInputBorder(
      borderSide: borderSide ?? this.borderSide,
      borderRadius: borderRadius ?? this.borderRadius,
      gapPadding: gapPadding ?? this.gapPadding,
    );
  }

  @override
  ContinuousOutlineInputBorder scale(double t) {
    return ContinuousOutlineInputBorder(
      borderSide: borderSide.scale(t),
      borderRadius: borderRadius * t,
      gapPadding: gapPadding * t,
    );
  }

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is ContinuousOutlineInputBorder) {
      return ContinuousOutlineInputBorder(
        borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
        gapPadding: a.gapPadding + (gapPadding - a.gapPadding) * t,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is ContinuousOutlineInputBorder) return b.lerpFrom(this, t);
    return super.lerpTo(b, t);
  }

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    Rect? gap;
    if (gapStart != null && gapExtent > 0 && gapPercentage > 0) {
      final extent = (gapExtent + gapPadding * 2) * gapPercentage;
      final start = switch (textDirection ?? TextDirection.ltr) {
        TextDirection.rtl => gapStart + gapPadding - extent,
        TextDirection.ltr => gapStart - gapPadding,
      };
      gap = Rect.fromLTWH(
        rect.left + start.clamp(0.0, rect.width),
        rect.top - borderSide.width,
        extent,
        borderSide.width * 2,
      );
    }
    paintContinuousStroke(
      canvas,
      rect,
      borderRadius: borderRadius,
      side: borderSide,
      gap: gap,
    );
  }
}

/// Color-only control chrome. Concrete capsule components specialize this
/// base while retaining ownership of their interaction logic. Control-layer
/// glass does not use this hairline surface.
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
    final content = DecoratedBox(
      decoration: continuousHairlineDecoration(
        color: fill,
        borderRadius: borderRadius,
        stroke: stroke,
        strokeWidth: strokeWidth,
      ),
      child: Material(type: MaterialType.transparency, child: child),
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
