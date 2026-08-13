import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Semantic intent of a surface, separate from its elevation.
///
/// Tone answers "what kind of thing is this", elevation answers "how far
/// forward is it". Keeping them independent stops features from expressing
/// importance by inventing a brighter fill.
enum LicoSurfaceTone {
  /// Ordinary content.
  neutral,

  /// Recessed content: code, terminal output, raw payloads.
  sunken,

  /// Brand-owned content: the user's own message, an active brand badge.
  brand,

  /// Informational content tied to the interaction color.
  accent,

  /// Success, warning, and failure notices.
  success,
  warning,
  danger,
}

/// A themed container: one surface fill, one hairline rim, one shadow tier.
///
/// This replaces per-feature `Container(decoration: BoxDecoration(...))` blocks
/// that each re-derived their own fill and border alpha. Because tone and
/// elevation are enums, a reviewer can see the intent without decoding hex.
final class LicoSurface extends StatelessWidget {
  const LicoSurface({
    super.key,
    required this.child,
    this.tone = LicoSurfaceTone.neutral,
    this.elevation = LicoElevation.card,
    this.radius = LicoRadius.card,
    this.padding,
    this.bordered = true,
    this.hovered = false,
    this.selected = false,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final LicoSurfaceTone tone;
  final LicoElevation elevation;
  final double radius;
  final EdgeInsetsGeometry? padding;

  /// Whether to draw the hairline rim. A brand tone always draws its rim
  /// regardless of this flag, because a brand fill can fall below 3:1 against
  /// a light surface and would otherwise have no visible edge.
  final bool bordered;

  final bool hovered;
  final bool selected;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final borderRadius = BorderRadius.circular(radius);

    return AnimatedContainer(
      duration: context.motion(LicoMotion.micro),
      curve: LicoMotion.standard,
      padding: padding,
      clipBehavior: clipBehavior == Clip.none ? Clip.none : clipBehavior,
      decoration: BoxDecoration(
        color: _fill(colors),
        borderRadius: borderRadius,
        border: _border(colors),
        boxShadow: elevation.shadows(colors),
      ),
      child: child,
    );
  }

  Color _fill(LicoThemeColors colors) {
    if (selected) {
      return colors.selectedSurface;
    }
    final base = switch (tone) {
      LicoSurfaceTone.neutral => elevation.surface(colors),
      LicoSurfaceTone.sunken => colors.surfaceSunken,
      LicoSurfaceTone.brand => colors.brandSurface,
      LicoSurfaceTone.accent => colors.accentSurface,
      // Semantic notices use a low-alpha wash of their signal color rather
      // than a dedicated surface token, so a preset only has to declare the
      // signal color itself.
      LicoSurfaceTone.success => Color.alphaBlend(
        colors.success.withValues(alpha: colors.isDark ? 0.12 : 0.10),
        elevation.surface(colors),
      ),
      LicoSurfaceTone.warning => Color.alphaBlend(
        colors.warning.withValues(alpha: colors.isDark ? 0.12 : 0.10),
        elevation.surface(colors),
      ),
      LicoSurfaceTone.danger => Color.alphaBlend(
        colors.error.withValues(alpha: colors.isDark ? 0.12 : 0.10),
        elevation.surface(colors),
      ),
    };
    if (hovered) {
      return Color.alphaBlend(colors.hoverOverlay, base);
    }
    return base;
  }

  Border? _border(LicoThemeColors colors) {
    if (tone == LicoSurfaceTone.brand) {
      return Border.all(color: colors.brandBorder, width: 1);
    }
    if (!bordered) {
      return null;
    }
    final color = switch (tone) {
      LicoSurfaceTone.accent => colors.accentBorder,
      LicoSurfaceTone.success => colors.success.withValues(alpha: 0.42),
      LicoSurfaceTone.warning => colors.warning.withValues(alpha: 0.42),
      LicoSurfaceTone.danger => colors.error.withValues(alpha: 0.42),
      LicoSurfaceTone.neutral ||
      LicoSurfaceTone.sunken ||
      LicoSurfaceTone.brand => colors.line,
    };
    return Border.all(color: color, width: 1);
  }
}
