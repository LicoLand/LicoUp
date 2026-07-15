import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/appearance/appearance_preset_config.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_buttons.dart';

class LicoThemeColors extends ThemeExtension<LicoThemeColors> {
  const LicoThemeColors({
    required this.background,
    required this.surface,
    required this.surfaceLow,
    required this.surfaceHigh,
    required this.surfaceHighest,
    required this.line,
    required this.text,
    required this.textMuted,
    required this.primary,
    required this.primaryStrong,
    required this.primaryFixed,
    required this.textOnPrimary,
    required this.info,
    required this.infoMuted,
    required this.success,
    required this.warning,
    required this.error,
  });

  final Color background;
  final Color surface;
  final Color surfaceLow;
  final Color surfaceHigh;
  final Color surfaceHighest;
  final Color line;
  final Color text;
  final Color textMuted;
  final Color primary;
  final Color primaryStrong;
  final Color primaryFixed;
  final Color textOnPrimary;
  final Color info;
  final Color infoMuted;
  final Color success;
  final Color warning;
  final Color error;

  bool get isDark {
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark;
  }

  @override
  LicoThemeColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceLow,
    Color? surfaceHigh,
    Color? surfaceHighest,
    Color? line,
    Color? text,
    Color? textMuted,
    Color? primary,
    Color? primaryStrong,
    Color? primaryFixed,
    Color? textOnPrimary,
    Color? info,
    Color? infoMuted,
    Color? success,
    Color? warning,
    Color? error,
  }) {
    return LicoThemeColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceLow: surfaceLow ?? this.surfaceLow,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      surfaceHighest: surfaceHighest ?? this.surfaceHighest,
      line: line ?? this.line,
      text: text ?? this.text,
      textMuted: textMuted ?? this.textMuted,
      primary: primary ?? this.primary,
      primaryStrong: primaryStrong ?? this.primaryStrong,
      primaryFixed: primaryFixed ?? this.primaryFixed,
      textOnPrimary: textOnPrimary ?? this.textOnPrimary,
      info: info ?? this.info,
      infoMuted: infoMuted ?? this.infoMuted,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
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
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      surfaceHighest: Color.lerp(surfaceHighest, other.surfaceHighest, t)!,
      line: Color.lerp(line, other.line, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      primaryStrong: Color.lerp(primaryStrong, other.primaryStrong, t)!,
      primaryFixed: Color.lerp(primaryFixed, other.primaryFixed, t)!,
      textOnPrimary: Color.lerp(textOnPrimary, other.textOnPrimary, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoMuted: Color.lerp(infoMuted, other.infoMuted, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
    );
  }
}

extension LicoThemeContext on BuildContext {
  LicoThemeColors get licoColors {
    return Theme.of(this).extension<LicoThemeColors>() ??
        licoColorsFor(AppearancePresetIds.licoCrystal);
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
    background: colorFromAppearanceToken(tokens, 'bg-base', '#f8fafc'),
    surface: colorFromAppearanceToken(tokens, 'bg-surface', '#ffffff'),
    surfaceLow: colorFromAppearanceToken(tokens, 'bg-subtle', '#f1f5f9'),
    surfaceHigh: colorFromAppearanceToken(tokens, 'brand-subtle', '#dbeafe'),
    surfaceHighest: colorFromAppearanceToken(tokens, 'brand-muted', '#bfdbfe'),
    line: colorFromAppearanceToken(tokens, 'border-subtle', '#cbd5e1'),
    text: colorFromAppearanceToken(tokens, 'text-primary', '#0f172a'),
    textMuted: colorFromAppearanceToken(tokens, 'text-muted', '#475569'),
    primary: colorFromAppearanceToken(tokens, 'brand', '#2563eb'),
    primaryStrong: colorFromAppearanceToken(tokens, 'brand-strong', '#1d4ed8'),
    primaryFixed: colorFromAppearanceToken(tokens, 'brand-subtle', '#dbeafe'),
    textOnPrimary: colorFromAppearanceToken(tokens, 'text-on-brand', '#ffffff'),
    info: colorFromAppearanceToken(tokens, 'info', '#0e7490'),
    infoMuted: colorFromAppearanceToken(tokens, 'info-surface', '#cffafe'),
    success: colorFromAppearanceToken(tokens, 'success', '#15803d'),
    warning: colorFromAppearanceToken(tokens, 'warning', '#b45309'),
    error: colorFromAppearanceToken(tokens, 'danger', '#b91c1c'),
  );
}

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
