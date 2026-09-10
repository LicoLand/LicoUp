import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Static specular edge light for clear-glass surfaces: a thin rim of one
/// alpha around the full frame, plus a soft sheen band decaying downward
/// from the top edge. Unlike `MessagingBubbleEdgeGlow` this is always lit
/// and paints crisp geometry only — no mask-filter bloom — so structural
/// shell cards carry zero per-frame blur cost.
class GlassEdgeLight extends StatelessWidget {
  const GlassEdgeLight({
    super.key,
    required this.borderRadius,
    required this.child,
    this.sheenExtent = MessagingDesktopMetrics.glassEdgeSheenExtent,
    this.rimWidth = MessagingDesktopMetrics.glassEdgeRimWidth,
  });

  final Widget child;
  final BorderRadius borderRadius;

  /// Height of the top sheen band. Small capsules pass a tighter extent so
  /// the band stays a glint instead of washing the whole surface.
  final double sheenExtent;

  /// Crisp rim stroke width.
  final double rimWidth;

  @override
  Widget build(BuildContext context) {
    final isDark = context.licoColors.isDark;
    return CustomPaint(
      foregroundPainter: GlassEdgeLightPainter(
        borderRadius: borderRadius,
        rimColor: MessagingDesktopMetrics.glassEdgeRimColor(isDark: isDark),
        sheenGradient: MessagingDesktopMetrics.glassEdgeSheenGradient(
          isDark: isDark,
        ),
        sheenExtent: sheenExtent,
        rimWidth: rimWidth,
      ),
      child: child,
    );
  }
}

/// Paints the glass edge light: first the sheen band clipped to the rounded
/// rect, then the crisp rim stroke on top.
class GlassEdgeLightPainter extends CustomPainter {
  const GlassEdgeLightPainter({
    required this.borderRadius,
    required this.rimColor,
    required this.sheenGradient,
    required this.sheenExtent,
    required this.rimWidth,
  });

  final BorderRadius borderRadius;
  final Color rimColor;
  final Gradient sheenGradient;
  final double sheenExtent;
  final double rimWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);
    if (sheenExtent > 0 && size.height > 0) {
      final sheenRect = Rect.fromLTWH(
        0,
        0,
        size.width,
        sheenExtent.clamp(0, size.height),
      );
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRect(
        sheenRect,
        Paint()..shader = sheenGradient.createShader(sheenRect),
      );
      canvas.restore();
    }
    if (rimWidth > 0) {
      final rim = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rimWidth
        ..color = rimColor;
      canvas.drawRRect(rrect.deflate(rimWidth / 2), rim);
    }
  }

  @override
  bool shouldRepaint(GlassEdgeLightPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.rimColor != rimColor ||
      oldDelegate.sheenGradient != sheenGradient ||
      oldDelegate.sheenExtent != sheenExtent ||
      oldDelegate.rimWidth != rimWidth;
}
