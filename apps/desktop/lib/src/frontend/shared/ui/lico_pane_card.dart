import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_glass.dart';
import 'package:licoup/src/frontend/shared/ui/lico_glass_region.dart';

/// The shared pane-card glass recipe: the translucent fill (smoke gradient
/// and sheen in dark mode), the specular rim and the soft elevation every
/// window pane card renders — the Desktop panes and the Dashboard Plain
/// content card use it verbatim while geometry stays profile-owned.
abstract final class LicoPaneGlass {
  /// Translucent card fill over the window ground — thin enough that the
  /// ground reads through instead of stacking into a gray haze.
  static Color cardFill({required bool isDark}) =>
      Color.fromARGB(isDark ? 12 : 92, 255, 255, 255);

  /// The dark pane cards' specular rim: white 16% on the lit side fading to
  /// white 5%.
  static const Color paneRimHi = Color(0x29FFFFFF);
  static const Color paneRimLo = Color(0x0DFFFFFF);

  /// The dark nav-glass recipe: a light black veil (34%) — as clear as
  /// the ambient allows — with a faint specular rim. Never smoke or shadow:
  /// nav glass must not carry the foggy transfer.
  static const Color navGlassFill = Color(0x57000000);

  /// The nav glass rim: white 10% on the lit side fading to white 3%.
  static const Color navGlassRimHi = Color(0x1AFFFFFF);
  static const Color navGlassRimLo = Color(0x08FFFFFF);

  /// Information-bearing cards on clear glass: black transparent glass
  /// (~52%), visibly separated from the pane without a white wash; the
  /// shared card owner adds a 1 px white ~8% hairline.
  static const Color contentInnerCardFill = Color(0x85000000);

  /// The inner card's hairline: white ~8%.
  static const Color contentInnerCardRim = Color(0x14FFFFFF);

  /// The dark pane recipe (Desktop work area and chat sidebar): a light
  /// black veil (~30%) — clear glass, no smoke, no fog. Desktop panes
  /// register no smoke region, so the ambient stays crisp beneath them.
  static const Color paneGlassVeil = Color(0x4D000000);

  /// Hairline rim on a floating card, resolved from the palette line color.
  static Color cardBorder(Color line, {required bool isDark}) =>
      line.withAlpha(isDark ? 90 : 120);

  /// Soft elevation under a floating card.
  static List<BoxShadow> cardShadows({required bool isDark}) => [
    BoxShadow(
      color: Color.fromARGB(isDark ? 115 : 20, 0, 0, 0),
      blurRadius: isDark ? 30 : 16,
      offset: isDark ? const Offset(0, 10) : const Offset(0, 4),
    ),
  ];
}

/// One window pane card: the smoke-glass fill (a gradient in dark mode), the
/// specular rim, and the registration that lets an ambient-owning window
/// ground soften what shines through the glass. Shells place it with their
/// own geometry; the material never varies between profiles.
final class LicoPaneCard extends StatelessWidget {
  const LicoPaneCard({
    super.key,
    required this.borderRadius,
    required this.child,
    this.navGlass = false,
  });

  /// The card's corner radius — the shell picks a value concentric with the
  /// host window's corner.
  final BorderRadius borderRadius;
  final Widget child;

  /// Card-style dark recipe: clear nav glass — an 18% black veil, a faint
  /// rim, no smoke gradient and no shadow; the registered region skips the
  /// ambient's smoke transfer so the galaxy stays crisp behind the pane.
  final bool navGlass;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    Widget card = Container(
      decoration: continuousHairlineDecoration(
        // The light fill is thin glass over the palette ground; resolving
        // it to the opaque composite keeps the card's own soft shadow from
        // bleeding through the translucent fill and graying the interior.
        color: colors.isDark
            ? (navGlass
                  ? LicoPaneGlass.navGlassFill
                  : LicoPaneGlass.paneGlassVeil)
            : Color.alphaBlend(
                LicoPaneGlass.cardFill(isDark: false),
                colors.background,
              ),
        // Clear glass in dark: no smoke gradient and no shadow halo — the
        // galaxy stays crisp behind the pane.
        borderRadius: borderRadius,
        stroke: colors.isDark
            ? null
            : LicoPaneGlass.cardBorder(colors.line, isDark: false),
        strokeWidth: colors.isDark ? 0 : 0.5,
        shadows: colors.isDark
            ? const []
            : LicoPaneGlass.cardShadows(isDark: colors.isDark),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        // A transparent Material gives tile content its ink ancestor
        // without adding a fill; the inherited text style is kept so
        // installing the Material changes nothing about the pane's text.
        child: Material(
          type: MaterialType.transparency,
          textStyle: DefaultTextStyle.of(context).style,
          child: child,
        ),
      ),
    );
    if (colors.isDark) {
      card = GlassEdgeLight(
        borderRadius: borderRadius,
        rimWidth: 1,
        rimHi: navGlass ? LicoPaneGlass.navGlassRimHi : LicoPaneGlass.paneRimHi,
        rimLo: navGlass ? LicoPaneGlass.navGlassRimLo : LicoPaneGlass.paneRimLo,
        child: card,
      );
    }
    return LicoGlassRegion(
      borderRadius: borderRadius,
      // No dark pane joins the smoke transfer — nav glass and the Desktop
      // panes are both clear glass over the ambient.
      softens: !colors.isDark,
      child: card,
    );
  }
}
