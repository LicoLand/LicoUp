import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';

/// The miniature window every settings layout preview draws: one corner
/// radius scale, one ground (the static mini galaxy in dark, the solid
/// cream in light), the three traffic-light dots, and one skeleton/
/// accent vocabulary, so every preview reads in the same visual language.
final class LicoPreviewWindow extends StatelessWidget {
  const LicoPreviewWindow({
    super.key,
    required this.colors,
    required this.child,
  });

  final LayoutPalette colors;
  final Widget child;

  /// The window chrome radius at preview scale.
  static const double radius = 10;

  /// A skeleton-line/bar in the shared preview token.
  static Widget bar(double width, Color color, {double height = 4}) =>
      Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      );

  /// The miniature pane/card fill — the shared clear-pane veil in dark,
  /// the cream surface in light.
  static Decoration pane(LayoutPalette colors, {double radius = 6}) =>
      continuousHairlineDecoration(
        color: colors.isDark ? LicoPaneGlass.paneGlassVeil : colors.surface,
        borderRadius: BorderRadius.circular(radius),
        stroke: colors.line.withAlpha(colors.isDark ? 110 : 140),
        strokeWidth: 0.5,
      );

  /// The miniature information card — black glass in dark, cream in light.
  static Decoration infoCard(LayoutPalette colors, {double radius = 6}) =>
      continuousHairlineDecoration(
        color: colors.isDark
            ? LicoPaneGlass.contentInnerCardFill
            : colors.surface,
        borderRadius: BorderRadius.circular(radius),
        stroke: colors.isDark
            ? LicoPaneGlass.contentInnerCardRim
            : colors.line.withAlpha(140),
        strokeWidth: 0.5,
      );

  /// The accent marker for the selected row/item.
  static Decoration selectedMarker(Color accent) => BoxDecoration(
    color: accent,
    borderRadius: BorderRadius.circular(1.5),
    boxShadow: [
      BoxShadow(color: accent.withValues(alpha: 0.45), blurRadius: 4),
    ],
  );

  /// The static miniature galaxy: a deep violet→near-black gradient with
  /// a few fixed star points — the same ground the live window paints.
  static Decoration ground(LayoutPalette colors) =>
      continuousHairlineDecoration(
        // The galaxy gradient carries the dark ground; the cream fill is
        // the light ground. ShapeDecoration rejects color+gradient together.
        color: colors.isDark ? null : colors.background,
        gradient: colors.isDark
            ? const RadialGradient(
                center: Alignment(0.1, -0.3),
                radius: 1.4,
                colors: [Color(0xFF1B1438), Color(0xFF07070A)],
              )
            : null,
        borderRadius: BorderRadius.circular(radius),
        stroke: colors.line,
        strokeWidth: 0.5,
      );

  /// The three traffic-light dots, top-leading.
  static Widget trafficLights({double dot = 6}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final color in const [
        Color(0xFFFF5F57),
        Color(0xFFFEBC2E),
        Color(0xFF28C840),
      ])
        Padding(
          padding: EdgeInsets.only(right: dot * 0.7),
          child: Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.85),
              shape: BoxShape.circle,
            ),
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 16 / 10,
    child: DecoratedBox(
      decoration: ground(colors),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    ),
  );
}
