import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/appearance/appearance_preset_config.dart';

/// Semantic colors resolved from an appearance preset.
///
/// Kept independently from themed widget implementations so controls can
/// consume color tokens without importing the theme builder that consumes
/// those controls.
///
/// Role model (see `docs/functionality/DESIGN-SYSTEM.md`):
///
/// * Neutral depth is `background` → `surface` → `surfaceLow` → `surfaceRaised`,
///   with `surfaceSunken` below the window for inset wells. These are the only
///   elevation roles; brand tints must never stand in for a neutral step.
/// * Brand (lemon) is a fill-and-mark role. `primary` is never a text color.
///   Interactive text is always `accent` or `accentStrong`.
/// * `*Strong` is always the more emphatic variant *for the active mode*, so
///   the same component code reads correctly in light and dark.
/// * State is expressed through `hoverOverlay`, `pressedOverlay`, and
///   `selectedSurface` rather than locally invented white/black alpha values.
class LicoThemeColors extends ThemeExtension<LicoThemeColors> {
  const LicoThemeColors({
    required this.background,
    required this.surface,
    required this.surfaceLow,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.line,
    required this.lineStrong,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textDisabled,
    required this.primary,
    required this.primaryStrong,
    required this.brandSurface,
    required this.brandBorder,
    required this.textOnPrimary,
    required this.accent,
    required this.accentStrong,
    required this.accentSurface,
    required this.accentBorder,
    required this.textOnAccent,
    required this.success,
    required this.warning,
    required this.error,
    required this.hoverOverlay,
    required this.pressedOverlay,
    required this.selectedSurface,
    required this.brandGlow,
    required this.accentGlow,
  });

  /// Window and scaffold base. The lowest neutral layer.
  final Color background;

  /// Primary content card layer, one visible step above [background].
  final Color surface;

  /// Row, hover, and quiet-fill layer above [surface].
  final Color surfaceLow;

  /// Popover, menu, and floating-panel layer. The highest neutral step.
  final Color surfaceRaised;

  /// Inset wells: code blocks, terminals, and recessed fields.
  final Color surfaceSunken;

  /// Default hairline separator.
  final Color line;

  /// Emphasized rim: resize handles, focused containers, table dividers.
  final Color lineStrong;

  /// Primary reading color.
  final Color text;

  /// Supporting copy that must still read as content, not metadata.
  final Color textSecondary;

  /// Metadata, timestamps, captions.
  final Color textMuted;

  /// Non-interactive text. Deliberately below the 4.5:1 body threshold.
  final Color textDisabled;

  /// Brand lemon. Fill and mark only — never apply to text or 1px strokes.
  final Color primary;

  /// Mode-appropriate emphatic brand for hover fills and 2px indicators.
  /// Guaranteed at least 3:1 against [surface] for non-text graphics.
  final Color primaryStrong;

  /// Brand-tinted surface for badges, avatars, and own-message bubbles.
  final Color brandSurface;

  /// Mandatory hairline for brand fills, whose own contrast against
  /// [surface] can fall below 3:1 in light mode.
  final Color brandBorder;

  /// Ink placed on [primary]. At least 4.5:1 against it.
  final Color textOnPrimary;

  /// Soda blue. The interaction color: focus rings, links, cursor, selection.
  /// At least 4.5:1 against [surface] so it is safe as text.
  final Color accent;

  /// Mode-appropriate emphatic accent for hover and pressed interactive text.
  final Color accentStrong;

  /// Accent-tinted informational surface.
  final Color accentSurface;

  /// Accent rim.
  final Color accentBorder;

  /// Ink placed on [accent].
  final Color textOnAccent;

  final Color success;
  final Color warning;
  final Color error;

  /// Pointer-hover wash. Composited over the underlying surface.
  final Color hoverOverlay;

  /// Pressed / active wash. Composited over the underlying surface.
  final Color pressedOverlay;

  /// Persistent selected-row fill. Distinct from a transient hover.
  final Color selectedSurface;

  /// Translucent lemon for luminous brand moments: the halo behind an active
  /// destination indicator, a send-ready control, a live activity pulse.
  ///
  /// Glow is not decoration. A vivid accent on a clean dark ground reads as
  /// energetic partly because it appears to emit light, and removing the glow
  /// layer is one of the reasons the previous palette read as flat and dusty.
  final Color brandGlow;

  /// Translucent accent for luminous interaction moments: focus halos and
  /// selection emphasis.
  final Color accentGlow;

  bool get isDark {
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark;
  }

  @override
  LicoThemeColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceLow,
    Color? surfaceRaised,
    Color? surfaceSunken,
    Color? line,
    Color? lineStrong,
    Color? text,
    Color? textSecondary,
    Color? textMuted,
    Color? textDisabled,
    Color? primary,
    Color? primaryStrong,
    Color? brandSurface,
    Color? brandBorder,
    Color? textOnPrimary,
    Color? accent,
    Color? accentStrong,
    Color? accentSurface,
    Color? accentBorder,
    Color? textOnAccent,
    Color? success,
    Color? warning,
    Color? error,
    Color? hoverOverlay,
    Color? pressedOverlay,
    Color? selectedSurface,
    Color? brandGlow,
    Color? accentGlow,
  }) {
    return LicoThemeColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceLow: surfaceLow ?? this.surfaceLow,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      line: line ?? this.line,
      lineStrong: lineStrong ?? this.lineStrong,
      text: text ?? this.text,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      textDisabled: textDisabled ?? this.textDisabled,
      primary: primary ?? this.primary,
      primaryStrong: primaryStrong ?? this.primaryStrong,
      brandSurface: brandSurface ?? this.brandSurface,
      brandBorder: brandBorder ?? this.brandBorder,
      textOnPrimary: textOnPrimary ?? this.textOnPrimary,
      accent: accent ?? this.accent,
      accentStrong: accentStrong ?? this.accentStrong,
      accentSurface: accentSurface ?? this.accentSurface,
      accentBorder: accentBorder ?? this.accentBorder,
      textOnAccent: textOnAccent ?? this.textOnAccent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      hoverOverlay: hoverOverlay ?? this.hoverOverlay,
      pressedOverlay: pressedOverlay ?? this.pressedOverlay,
      selectedSurface: selectedSurface ?? this.selectedSurface,
      brandGlow: brandGlow ?? this.brandGlow,
      accentGlow: accentGlow ?? this.accentGlow,
    );
  }

  @override
  LicoThemeColors lerp(ThemeExtension<LicoThemeColors>? other, double t) {
    if (other is! LicoThemeColors) {
      return this;
    }
    return LicoThemeColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceLow: Color.lerp(surfaceLow, other.surfaceLow, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceSunken: Color.lerp(surfaceSunken, other.surfaceSunken, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineStrong: Color.lerp(lineStrong, other.lineStrong, t)!,
      text: Color.lerp(text, other.text, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      primaryStrong: Color.lerp(primaryStrong, other.primaryStrong, t)!,
      brandSurface: Color.lerp(brandSurface, other.brandSurface, t)!,
      brandBorder: Color.lerp(brandBorder, other.brandBorder, t)!,
      textOnPrimary: Color.lerp(textOnPrimary, other.textOnPrimary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentStrong: Color.lerp(accentStrong, other.accentStrong, t)!,
      accentSurface: Color.lerp(accentSurface, other.accentSurface, t)!,
      accentBorder: Color.lerp(accentBorder, other.accentBorder, t)!,
      textOnAccent: Color.lerp(textOnAccent, other.textOnAccent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      hoverOverlay: Color.lerp(hoverOverlay, other.hoverOverlay, t)!,
      pressedOverlay: Color.lerp(pressedOverlay, other.pressedOverlay, t)!,
      selectedSurface: Color.lerp(selectedSurface, other.selectedSurface, t)!,
      brandGlow: Color.lerp(brandGlow, other.brandGlow, t)!,
      accentGlow: Color.lerp(accentGlow, other.accentGlow, t)!,
    );
  }
}

extension LicoThemeContext on BuildContext {
  LicoThemeColors get licoColors {
    return Theme.of(this).extension<LicoThemeColors>() ??
        licoColorsFor(AppearancePresetIds.licoSoda);
  }
}

LicoThemeColors licoColorsFor(
  String presetId, {
  List<AppearancePresetConfig> presets = builtInAppearancePresetConfigs,
  Brightness platformBrightness = Brightness.light,
}) {
  final resolved = resolveAppearancePresetConfig(
    presetId,
    presets,
    platformBrightness,
  );
  final tokens = resolved.tokens;
  return LicoThemeColors(
    background: colorFromAppearanceToken(tokens, 'bg-base', '#f4f4f6'),
    surface: colorFromAppearanceToken(tokens, 'bg-surface', '#ffffff'),
    surfaceLow: colorFromAppearanceToken(tokens, 'bg-subtle', '#eeeef1'),
    surfaceRaised: colorFromAppearanceToken(tokens, 'bg-raised', '#ffffff'),
    surfaceSunken: colorFromAppearanceToken(tokens, 'bg-inset', '#e7e7ea'),
    line: colorFromAppearanceToken(tokens, 'border-subtle', '#dbdce0'),
    lineStrong: colorFromAppearanceToken(tokens, 'border-strong', '#b0b0b6'),
    text: colorFromAppearanceToken(tokens, 'text-primary', '#1a1a20'),
    textSecondary: colorFromAppearanceToken(
      tokens,
      'text-secondary',
      '#4f4f55',
    ),
    textMuted: colorFromAppearanceToken(tokens, 'text-muted', '#68696f'),
    textDisabled: colorFromAppearanceToken(tokens, 'text-disabled', '#9d9ea3'),
    primary: colorFromAppearanceToken(tokens, 'brand', '#d9e320'),
    primaryStrong: colorFromAppearanceToken(tokens, 'brand-strong', '#878e1f'),
    brandSurface: colorFromAppearanceToken(tokens, 'brand-subtle', '#f5f8c5'),
    brandBorder: colorFromAppearanceToken(tokens, 'brand-border', '#bfc744'),
    textOnPrimary: colorFromAppearanceToken(tokens, 'text-on-brand', '#1b1d00'),
    accent: colorFromAppearanceToken(tokens, 'accent', '#007d8a'),
    accentStrong: colorFromAppearanceToken(tokens, 'accent-strong', '#0d5f68'),
    accentSurface: colorFromAppearanceToken(
      tokens,
      'accent-surface',
      '#deeef0',
    ),
    accentBorder: colorFromAppearanceToken(tokens, 'accent-border', '#67c8d6'),
    textOnAccent: colorFromAppearanceToken(
      tokens,
      'text-on-accent',
      '#ffffff',
    ),
    success: colorFromAppearanceToken(tokens, 'success', '#158351'),
    warning: colorFromAppearanceToken(tokens, 'warning', '#9c660c'),
    error: colorFromAppearanceToken(tokens, 'danger', '#ce1828'),
    hoverOverlay: colorFromAppearanceToken(
      tokens,
      'hover-overlay',
      '#101519',
    ).withValues(alpha: resolved.mode == AppearancePresetMode.dark ? 0.06 : 0.05),
    pressedOverlay: colorFromAppearanceToken(
      tokens,
      'pressed-overlay',
      '#101519',
    ).withValues(alpha: resolved.mode == AppearancePresetMode.dark ? 0.10 : 0.09),
    selectedSurface: colorFromAppearanceToken(
      tokens,
      'selected-surface',
      '#eeeef1',
    ),
    brandGlow: colorFromAppearanceToken(
      tokens,
      'brand-glow',
      'rgba(217, 227, 32, 0.30)',
    ),
    accentGlow: colorFromAppearanceToken(
      tokens,
      'accent-glow',
      'rgba(0, 125, 138, 0.22)',
    ),
  );
}
