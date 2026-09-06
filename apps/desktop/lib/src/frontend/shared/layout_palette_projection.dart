import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Projects the resolved appearance palette onto the layout-neutral
/// [LayoutPalette].
///
/// This is the only place the two role sets are mapped. Layout profiles cannot
/// import the theme (`verify-layout-boundaries` rejects any
/// `frontend/shared/ui/` import from the layout tree), so the projection has to
/// live in the shared renderer layer that already knows both.
///
/// Keeping it in one function matters: every construction site that enumerated
/// the roles by hand was a place where a newly added role could be silently
/// dropped, and test fixtures had drifted from production for exactly that
/// reason.
LayoutPalette layoutPaletteFromColors(LicoThemeColors colors) {
  return LayoutPalette(
    background: colors.background,
    surface: colors.surface,
    surfaceLow: colors.surfaceLow,
    surfaceRaised: colors.surfaceRaised,
    surfaceSunken: colors.surfaceSunken,
    line: colors.line,
    lineStrong: colors.lineStrong,
    text: colors.text,
    textSecondary: colors.textSecondary,
    textMuted: colors.textMuted,
    textDisabled: colors.textDisabled,
    primary: colors.primary,
    primaryStrong: colors.primaryStrong,
    brandSurface: colors.brandSurface,
    brandBorder: colors.brandBorder,
    textOnPrimary: colors.textOnPrimary,
    accent: colors.accent,
    accentStrong: colors.accentStrong,
    accentSurface: colors.accentSurface,
    accentBorder: colors.accentBorder,
    textOnAccent: colors.textOnAccent,
    success: colors.success,
    warning: colors.warning,
    error: colors.error,
    hoverOverlay: colors.hoverOverlay,
    pressedOverlay: colors.pressedOverlay,
    selectedSurface: colors.selectedSurface,
    brandGlow: colors.brandGlow,
    accentGlow: colors.accentGlow,
  );
}
