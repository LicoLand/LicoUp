import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/shared/ui/apple_buttons.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

export 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

ThemeData buildLicoTheme({
  String presetId = AppearancePresetIds.licoSoda,
  List<AppearancePresetConfig> presets = builtInAppearancePresetConfigs,
  Brightness platformBrightness = Brightness.dark,
}) {
  final colors = licoColorsFor(
    presetId,
    presets: presets,
    platformBrightness: platformBrightness,
  );
  final base = colors.isDark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);

  // The type scale is owned by LicoTypography so the roles, tracking, and
  // tabular-figure decisions live in one place instead of being restated here.
  final textTheme = LicoTypography.textTheme(
    text: colors.text,
    textSecondary: colors.textSecondary,
    textMuted: colors.textMuted,
  );

  return base.copyWith(
    scaffoldBackgroundColor: colors.background,
    textTheme: textTheme,
    // Every ColorScheme role is set explicitly.
    //
    // Using `copyWith` on a Material baseline left twelve roles at Material's
    // own 2014 palette, and Flutter widgets that reach for them rendered in
    // colours from a different product: `secondaryContainer` resolved to teal
    // #03dac6 and `primaryContainer`/`surfaceTint` to purple #bb86fc, which is
    // why a refresh control appeared as a mint circle with a pink glyph.
    // An incomplete ColorScheme is a colour leak, so this map is exhaustive
    // and `theme_test.dart` asserts that no role falls outside the palette.
    colorScheme: ColorScheme(
      brightness: colors.isDark ? Brightness.dark : Brightness.light,
      primary: colors.primary,
      onPrimary: colors.textOnPrimary,
      primaryContainer: colors.brandSurface,
      onPrimaryContainer: colors.text,
      primaryFixed: colors.brandSurface,
      primaryFixedDim: colors.brandBorder,
      onPrimaryFixed: colors.text,
      onPrimaryFixedVariant: colors.textSecondary,
      // Secondary carries the interaction colour, not a second brand shade, so
      // Material components that reach for `secondary` land on the accent.
      secondary: colors.accent,
      onSecondary: colors.textOnAccent,
      secondaryContainer: colors.accentSurface,
      onSecondaryContainer: colors.text,
      secondaryFixed: colors.accentSurface,
      secondaryFixedDim: colors.accentBorder,
      onSecondaryFixed: colors.text,
      onSecondaryFixedVariant: colors.textSecondary,
      // There is no third brand hue. Tertiary mirrors the accent rather than
      // inventing one.
      tertiary: colors.accentStrong,
      onTertiary: colors.textOnAccent,
      tertiaryContainer: colors.accentSurface,
      onTertiaryContainer: colors.text,
      tertiaryFixed: colors.accentSurface,
      tertiaryFixedDim: colors.accentBorder,
      onTertiaryFixed: colors.text,
      onTertiaryFixedVariant: colors.textSecondary,
      error: colors.error,
      onError: colors.isDark ? colors.background : Colors.white,
      errorContainer: colors.surfaceLow,
      onErrorContainer: colors.text,
      surface: colors.surface,
      onSurface: colors.text,
      onSurfaceVariant: colors.textSecondary,
      surfaceDim: colors.background,
      surfaceBright: colors.surfaceRaised,
      surfaceContainerLowest: colors.surfaceSunken,
      surfaceContainerLow: colors.background,
      surfaceContainer: colors.surface,
      surfaceContainerHigh: colors.surfaceLow,
      surfaceContainerHighest: colors.surfaceRaised,
      inverseSurface: colors.text,
      onInverseSurface: colors.background,
      inversePrimary: colors.primaryStrong,
      outline: colors.line,
      outlineVariant: colors.lineStrong,
      // Material tints elevated surfaces with `surfaceTint`. The neutral ramp
      // already expresses elevation, so tinting must be a no-op rather than a
      // brand wash creeping onto every raised surface.
      surfaceTint: Colors.transparent,
      shadow: Colors.black,
      scrim: Colors.black,
    ),
    extensions: [colors],
    iconTheme: IconThemeData(color: colors.textMuted, size: 20),
    dividerTheme: DividerThemeData(color: colors.line, thickness: 1, space: 1),
    // The text selection colors are part of the interaction language: a
    // selection is an interactive state, so it uses the accent rather than
    // the brand.
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: colors.accent,
      selectionColor: colors.accent.withValues(alpha: 0.28),
      selectionHandleColor: colors.accent,
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: textTheme.bodySmall?.copyWith(color: colors.text),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        border: Border.all(color: colors.line, width: 1),
      ),
      waitDuration: LicoMotion.tooltipWait,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: Colors.transparent,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: colors.text,
        fontWeight: FontWeight.w500,
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LicoRadius.card),
        side: BorderSide(color: colors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: AppleControlButtons.glassFilled(colors),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: AppleControlButtons.glassOutlined(colors),
    ),
    textButtonTheme: TextButtonThemeData(
      style: AppleControlButtons.glassText(colors),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.textDisabled;
        }
        if (states.contains(WidgetState.selected)) {
          return colors.textOnPrimary;
        }
        return colors.textMuted;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.surfaceLow;
        }
        if (states.contains(WidgetState.selected)) {
          return colors.primary;
        }
        return colors.surfaceLow;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colors.brandBorder;
        }
        return colors.line;
      }),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.surfaceLow,
      selectedColor: colors.selectedSurface,
      side: BorderSide(color: colors.line, width: 1),
      labelStyle: textTheme.labelMedium?.copyWith(color: colors.textSecondary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LicoRadius.chip),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      labelStyle: textTheme.bodyMedium?.copyWith(
        color: colors.textMuted,
        fontWeight: FontWeight.w500,
      ),
      hintStyle: textTheme.bodyMedium?.copyWith(color: colors.textDisabled),
      border: _inputBorder(colors.line),
      enabledBorder: _inputBorder(colors.line),
      // Focus is an interaction, so the ring is the accent and it is two
      // pixels wide: a one-pixel color change is not a reliable focus signal.
      focusedBorder: _inputBorder(colors.accent, width: 2),
      disabledBorder: _inputBorder(colors.line.withValues(alpha: 0.5)),
      errorBorder: _inputBorder(colors.error),
      focusedErrorBorder: _inputBorder(colors.error, width: 2),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: textTheme.bodyMedium?.copyWith(
        color: colors.text,
        fontWeight: FontWeight.w500,
      ),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
      titleTextStyle: textTheme.bodyMedium?.copyWith(
        color: colors.text,
        fontWeight: FontWeight.w500,
      ),
      subtitleTextStyle: textTheme.bodySmall,
      iconColor: colors.textMuted,
      selectedTileColor: colors.selectedSurface,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) {
          return colors.textMuted.withValues(alpha: 0.62);
        }
        return colors.textMuted.withValues(alpha: 0.38);
      }),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
  );
}

OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(LicoRadius.chip),
    borderSide: BorderSide(color: color, width: width),
  );
}
