import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/appearance/appearance_preset_config.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_buttons.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme_colors.dart';

export 'package:flutter_client/src/frontend/shared/ui/theme_colors.dart';

ThemeData buildLicoTheme({
  String presetId = AppearancePresetIds.licoCrystal,
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

  // Apply brand colors globally, then override with intentional type scale.
  // Scale ratio: ~1.25 between steps (11 → 12 → 13 → 14 → 16 → 20 → 24 → 28)
  final textTheme = base.textTheme
      .apply(bodyColor: colors.text, displayColor: colors.text)
      .copyWith(
        headlineLarge: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: colors.text,
          height: 1.2,
          letterSpacing: -0.4,
        ),
        headlineMedium: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: colors.text,
          height: 1.25,
          letterSpacing: -0.3,
        ),
        headlineSmall: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: colors.text,
          height: 1.3,
          letterSpacing: -0.2,
        ),
        titleLarge: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: colors.text,
          height: 1.3,
          letterSpacing: -0.15,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: colors.text,
          height: 1.35,
        ),
        titleSmall: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: colors.text,
          height: 1.4,
        ),
        bodyLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: colors.text,
          height: 1.4,
        ),
        bodyMedium: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: colors.text,
          height: 1.4,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: colors.textMuted,
          height: 1.35,
        ),
        labelLarge: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: colors.text,
          height: 1.3,
          letterSpacing: 0.1,
        ),
        labelMedium: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: colors.text,
          height: 1.3,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: colors.textMuted,
          height: 1.3,
          letterSpacing: 0.2,
        ),
      );

  return base.copyWith(
    scaffoldBackgroundColor: colors.background,
    textTheme: textTheme,
    colorScheme: colors.isDark
        ? ColorScheme.dark(
            surface: colors.surface,
            primary: colors.primary,
            onPrimary: colors.textOnPrimary,
            secondary: colors.primaryStrong,
            onSecondary: colors.textOnPrimary,
            error: colors.error,
            onError: const Color(0xFF111827),
            onSurface: colors.text,
            surfaceContainerHighest: colors.surfaceHighest,
          )
        : ColorScheme.light(
            surface: colors.surface,
            primary: colors.primary,
            onPrimary: colors.textOnPrimary,
            secondary: colors.primaryStrong,
            onSecondary: colors.textOnPrimary,
            error: colors.error,
            onError: Colors.white,
            onSurface: colors.text,
            surfaceContainerHighest: colors.surfaceHighest,
          ),
    extensions: [colors],
    iconTheme: IconThemeData(color: colors.textMuted, size: 20),
    dividerTheme: DividerThemeData(
      color: colors.line.withAlpha(60),
      thickness: 1,
      space: 1,
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: colors.text,
        letterSpacing: -0.08,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(colors.isDark ? 32 : 40),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withAlpha(colors.isDark ? 56 : 80),
          width: 0.5,
        ),
      ),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: Colors.transparent,
      contentTextStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: colors.text,
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.line.withAlpha(80)),
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
        if (states.contains(WidgetState.selected)) {
          return colors.text.withAlpha(245);
        }
        return colors.textMuted;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colors.info.withAlpha(90);
        }
        return colors.surfaceLow;
      }),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.white.withAlpha(colors.isDark ? 16 : 20),
      selectedColor: Colors.white.withAlpha(colors.isDark ? 32 : 36),
      side: BorderSide(
        color: Colors.white.withAlpha(colors.isDark ? 48 : 70),
        width: 0.5,
      ),
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: colors.text,
        letterSpacing: -0.04,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withAlpha(colors.isDark ? 14 : 18),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: colors.textMuted,
      ),
      hintStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: colors.textMuted.withAlpha(140),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: Colors.white.withAlpha(colors.isDark ? 42 : 64),
          width: 0.5,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: Colors.white.withAlpha(colors.isDark ? 42 : 64),
          width: 0.5,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colors.info.withAlpha(170), width: 1),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: Colors.white.withAlpha(colors.isDark ? 24 : 36),
          width: 0.5,
        ),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: colors.text,
      ),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
      titleTextStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: colors.text,
      ),
      subtitleTextStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: colors.textMuted,
      ),
      iconColor: colors.textMuted,
    ),
  );
}
